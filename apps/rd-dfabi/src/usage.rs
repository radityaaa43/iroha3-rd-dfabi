//! `POST /usage {token, since}`: how much of a token this gateway's party sent out since `since` (the bank rule's daily limit).
//!
//! Design. Usage = the decode journal joined with Torii's public tx-status route. The sidecar appends one record for every
//! tx body it decodes on the tx route that is an outflow of the signer: a transfer, the seller's delivery leg of a DvP, or the
//! buyer's consent (its payment leg, read from the registered intent). The rego decides allow/deny; the journal only records
//! what was decoded, so a denied or never-submitted tx is in it too. The join is what separates those: on `/usage` every
//! non-final record is looked up at the party's own Torii (`GET /v1/pipeline/transactions/status?hash=`, `--torii-url`):
//!   Applied                    counted, final
//!   Rejected | Expired         not counted, final
//!   Queued | Approved | ...    counted (it can still apply), asked again next time
//!   not found                  not counted (never submitted, e.g. denied); final once older than NOT_FOUND_GRACE_MS
//! The tx being authorized right now is journaled by `/decode` before the rego asks `/usage`, but Torii has not seen it yet, so
//! it is "not found" and not double counted with the rego's own `request` amount.
//!
//! `complete` is false (the rego then denies) on any doubt: the journal started after `since` (a fresh pod, or the first day),
//! a record was dropped because the journal was full, `since` is older than the retention, a status lookup failed or
//! the lookups ran out of time, a journal write failed, or the sum does not fit 20 digits. Not covered: two txs authorized in
//! the same instant both see the same usage (the rego header says so), and a flood of validly signed junk can fill the
//! journal (MAX_RECS), which turns `complete` false until `since` passes the drop: fail closed.
//!
//! Persistence: `journal.jsonl` under `--state-dir`, append-only, one fsync per new record. The first line is the start time.
//! A torn last line (crash mid-append) is ignored on load; any other bad line is an error. A pod restart loses the file, so
//! the new journal starts after `since` and `complete` stays false until the next window.

use std::{
    collections::{BTreeMap, BTreeSet},
    fs::{self, File, OpenOptions},
    io::{self, Read, Write},
    net::{TcpStream, ToSocketAddrs},
    path::Path,
    time::{Duration, Instant},
};

use serde::{Deserialize, Serialize};

use crate::intents::write_atomic;

const FILE: &str = "journal.jsonl";
pub const MAX_RECS: usize = 100_000;
/// Records older than this are dropped when the file is compacted (the window is at most a day).
const RETAIN_MS: u64 = 48 * 3_600_000;
pub const NOT_FOUND_GRACE_MS: u64 = 60_000;
/// The rego's http.send gives `/usage` 2 s; stop asking Torii before that.
const USAGE_BUDGET: Duration = Duration::from_millis(1500);
const COMPACT_EVERY: usize = 10_000;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Final {
    Applied,
    Dead,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum State {
    Pending,
    Done(Final),
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(tag = "t", rename_all = "snake_case")]
enum Line {
    Start { at: u64 },
    Gap { at: u64 },
    Rec { tx: String, asset: String, amount: String, ts: u64 },
    Fin { tx: String, state: Final },
}

#[derive(Clone, Debug)]
struct Rec {
    asset: String,
    amount: u128,
    ts: u64,
    state: State,
}

pub struct Journal {
    dir: std::path::PathBuf,
    file: File,
    started_at: u64,
    gap_at: Option<u64>,
    recs: BTreeMap<String, Rec>,
    appended: usize,
}

impl Journal {
    pub fn open(dir: &Path, now: u64) -> io::Result<Self> {
        fs::create_dir_all(dir)?;
        let path = dir.join(FILE);
        let mut j = match fs::read_to_string(&path) {
            Ok(text) => Self::replay(dir, &text)?,
            Err(e) if e.kind() == io::ErrorKind::NotFound => {
                write_atomic(dir, FILE, format!("{}\n", serde_json::to_string(&Line::Start { at: now }).unwrap()).as_bytes())?;
                Self { dir: dir.to_path_buf(), file: OpenOptions::new().append(true).open(&path)?, started_at: now, gap_at: None, recs: BTreeMap::new(), appended: 0 }
            }
            Err(e) => return Err(e),
        };
        j.compact(now)?;
        Ok(j)
    }

    fn replay(dir: &Path, text: &str) -> io::Result<Self> {
        let bad = |m: String| io::Error::new(io::ErrorKind::InvalidData, format!("{FILE}: {m}"));
        let lines: Vec<&str> = text.lines().collect();
        let mut started_at = None;
        let mut gap_at = None;
        let mut recs: BTreeMap<String, Rec> = BTreeMap::new();
        for (i, raw) in lines.iter().enumerate() {
            let line = match serde_json::from_str::<Line>(raw) {
                Ok(l) => l,
                // a crash mid-append leaves a partial last line without its newline
                Err(_) if i + 1 == lines.len() && !text.ends_with('\n') => break,
                Err(e) => return Err(bad(format!("line {}: {e}", i + 1))),
            };
            match line {
                Line::Start { at } => {
                    if started_at.replace(at).is_some() {
                        return Err(bad("second start line".into()));
                    }
                }
                Line::Gap { at } => gap_at = Some(gap_at.map_or(at, |g: u64| g.max(at))),
                Line::Rec { tx, asset, amount, ts } => {
                    let amount = amount.parse().map_err(|_| bad(format!("line {}: amount", i + 1)))?;
                    recs.entry(tx).or_insert(Rec { asset, amount, ts, state: State::Pending });
                }
                Line::Fin { tx, state } => {
                    if let Some(r) = recs.get_mut(&tx) {
                        r.state = State::Done(state);
                    }
                }
            }
        }
        let started_at = started_at.ok_or_else(|| bad("no start line".into()))?;
        let file = OpenOptions::new().append(true).open(dir.join(FILE))?;
        // a torn line is dropped by the compaction that open() runs next
        Ok(Self { dir: dir.to_path_buf(), file, started_at, gap_at, recs, appended: lines.len() })
    }

    fn append(&mut self, line: &Line) -> io::Result<()> {
        let mut s = serde_json::to_string(line).expect("line serialises");
        s.push('\n');
        self.file.write_all(s.as_bytes())?;
        self.file.sync_data()?;
        self.appended += 1;
        Ok(())
    }

    /// Rewrite the file (atomically) without records past the retention and without a torn tail.
    fn compact(&mut self, now: u64) -> io::Result<()> {
        let keep: BTreeMap<String, Rec> = self.recs.iter().filter(|(_, r)| r.ts + RETAIN_MS > now).map(|(k, v)| (k.clone(), v.clone())).collect();
        let mut out = String::new();
        let mut push = |l: Line| {
            out.push_str(&serde_json::to_string(&l).unwrap());
            out.push('\n');
        };
        push(Line::Start { at: self.started_at });
        if let Some(at) = self.gap_at {
            push(Line::Gap { at });
        }
        for (tx, r) in &keep {
            push(Line::Rec { tx: tx.clone(), asset: r.asset.clone(), amount: r.amount.to_string(), ts: r.ts });
            if let State::Done(f) = r.state {
                push(Line::Fin { tx: tx.clone(), state: f });
            }
        }
        write_atomic(&self.dir, FILE, out.as_bytes())?;
        self.file = OpenOptions::new().append(true).open(self.dir.join(FILE))?;
        self.recs = keep;
        self.appended = 0;
        Ok(())
    }

    /// Journal one decoded outflow. Seen before (the BI and the bank bundle both decode, clients retry): no-op.
    pub fn record(&mut self, tx: &str, asset: &str, amount: u128, now: u64) -> io::Result<()> {
        if self.recs.contains_key(tx) {
            return Ok(());
        }
        if self.appended >= COMPACT_EVERY {
            self.compact(now)?;
        }
        if self.recs.len() >= MAX_RECS {
            // dropped, and the window that contains this instant is no longer complete
            if self.gap_at.is_none_or(|g| g < now) {
                self.append(&Line::Gap { at: now })?;
                self.gap_at = Some(now);
            }
            return Ok(());
        }
        self.append(&Line::Rec { tx: tx.into(), asset: asset.into(), amount: amount.to_string(), ts: now })?;
        self.recs.insert(tx.into(), Rec { asset: asset.into(), amount, ts: now, state: State::Pending });
        Ok(())
    }

    fn settle(&mut self, tx: &str, f: Final) -> io::Result<()> {
        if self.recs.get(tx).is_some_and(|r| r.state == State::Pending) {
            self.append(&Line::Fin { tx: tx.into(), state: f })?;
            self.recs.get_mut(tx).expect("present").state = State::Done(f);
        }
        Ok(())
    }

    fn covers(&self, since: u64, now: u64) -> bool {
        self.started_at <= since && self.gap_at.is_none_or(|g| g < since) && since.saturating_add(RETAIN_MS) > now
    }

    fn pending(&self, asset: &str, since: u64) -> Vec<(String, u64)> {
        self.recs.iter().filter(|(_, r)| r.asset == asset && r.ts >= since && r.state == State::Pending).map(|(k, r)| (k.clone(), r.ts)).collect()
    }

    #[cfg(test)]
    pub fn len(&self) -> usize {
        self.recs.len()
    }
}

/// What Torii says about one tx.
#[derive(Debug, PartialEq, Eq)]
pub enum Tx {
    Applied,
    /// Rejected or Expired.
    Dead,
    /// Known to Torii and not finished (Queued, Approved, Committed, ...).
    InFlight,
    NotFound,
}

pub type StatusFn = Box<dyn Fn(&str) -> Result<Tx, String> + Send + Sync>;

#[derive(Debug, Serialize, Deserialize, PartialEq)]
pub struct UsageOut {
    /// Whole units, decimal.
    pub amount: String,
    pub complete: bool,
}

/// The usage of `asset` since `since` (unix ms). `journal` is locked only for the short reads and writes, never across a
/// Torii call.
pub fn usage(journal: &std::sync::Mutex<Journal>, status: &StatusFn, asset: &str, since: u64, now: u64) -> UsageOut {
    let (mut complete, pending) = {
        let j = journal.lock().unwrap();
        (j.covers(since, now), j.pending(asset, since))
    };
    let t0 = Instant::now();
    let mut inflight = BTreeSet::new();
    let mut fin = Vec::new();
    for (tx, ts) in pending {
        if t0.elapsed() > USAGE_BUDGET {
            complete = false;
            break;
        }
        match status(&tx) {
            Ok(Tx::Applied) => fin.push((tx, Final::Applied)),
            Ok(Tx::Dead) => fin.push((tx, Final::Dead)),
            Ok(Tx::InFlight) => {
                inflight.insert(tx);
            }
            Ok(Tx::NotFound) => {
                if now.saturating_sub(ts) > NOT_FOUND_GRACE_MS {
                    fin.push((tx, Final::Dead));
                }
            }
            Err(_) => complete = false,
        }
    }
    let mut j = journal.lock().unwrap();
    for (tx, f) in fin {
        if j.settle(&tx, f).is_err() {
            complete = false;
        }
    }
    let sum = j
        .recs
        .iter()
        .filter(|(tx, r)| r.asset == asset && r.ts >= since && (r.state == State::Done(Final::Applied) || (r.state == State::Pending && inflight.contains(*tx))))
        .fold(0u128, |a, (_, r)| a.saturating_add(r.amount));
    if sum > 99_999_999_999_999_999_999 {
        complete = false;
    }
    UsageOut { amount: sum.to_string(), complete }
}

/// `YYYY-MM-DDTHH:MM:SSZ` (UTC, what the rego sends) -> unix ms. Nothing else is accepted.
pub fn parse_since(s: &str) -> Option<u64> {
    let b = s.as_bytes();
    if b.len() != 20 || b[4] != b'-' || b[7] != b'-' || b[10] != b'T' || b[13] != b':' || b[16] != b':' || b[19] != b'Z' {
        return None;
    }
    let n = |r: std::ops::Range<usize>| -> Option<i64> { s.get(r).filter(|t| t.bytes().all(|c| c.is_ascii_digit()))?.parse().ok() };
    let (y, m, d, hh, mm, ss) = (n(0..4)?, n(5..7)?, n(8..10)?, n(11..13)?, n(14..16)?, n(17..19)?);
    if !(1..=12).contains(&m) || !(1..=31).contains(&d) || hh > 23 || mm > 59 || ss > 59 {
        return None;
    }
    // days from civil (Howard Hinnant)
    let y = if m <= 2 { y - 1 } else { y };
    let era = y.div_euclid(400);
    let yoe = y - era * 400;
    let doy = (153 * (if m > 2 { m - 3 } else { m + 9 }) + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    let days = era * 146_097 + doe - 719_468;
    u64::try_from(((days * 24 + hh) * 60 + mm) * 60 + ss).ok().map(|s| s * 1000)
}

// --- Torii client: std only, plain http, one GET per call.

/// `base` is `http://host:port` (no path, no TLS: the party's Torii inside the cluster).
pub fn torii_status(base: &str) -> Result<StatusFn, String> {
    let addr = base.strip_prefix("http://").ok_or("--torii-url must start with http://")?.trim_end_matches('/').to_string();
    if addr.is_empty() || addr.contains('/') || addr.contains('@') {
        return Err("--torii-url must be http://host:port".into());
    }
    Ok(Box::new(move |hash: &str| {
        if hash.len() != 64 || !hash.bytes().all(|c| c.is_ascii_hexdigit()) {
            return Err("not a tx hash".into());
        }
        let (code, body) = http_get(&addr, &format!("/v1/pipeline/transactions/status?hash={hash}"))?;
        match code {
            404 => Ok(Tx::NotFound),
            200 => {
                let v: serde_json::Value = serde_json::from_slice(&body).map_err(|e| format!("status body: {e}"))?;
                match v.pointer("/status/kind").and_then(|k| k.as_str()) {
                    Some("Applied") => Ok(Tx::Applied),
                    Some("Rejected" | "Expired") => Ok(Tx::Dead),
                    Some(_) => Ok(Tx::InFlight),
                    None => Err("status body has no status.kind".into()),
                }
            }
            c => Err(format!("torii answered {c}")),
        }
    }))
}

fn http_get(addr: &str, path: &str) -> Result<(u16, Vec<u8>), String> {
    let t = Duration::from_secs(1);
    let sa = addr.to_socket_addrs().map_err(|e| format!("resolve {addr}: {e}"))?.next().ok_or("no address")?;
    let mut s = TcpStream::connect_timeout(&sa, t).map_err(|e| format!("connect: {e}"))?;
    s.set_read_timeout(Some(t)).and_then(|_| s.set_write_timeout(Some(t))).map_err(|e| e.to_string())?;
    // one write: the request must not reach the peer in pieces
    let req = format!("GET {path} HTTP/1.1\r\nHost: {addr}\r\nAccept: application/json\r\nConnection: close\r\n\r\n");
    s.write_all(req.as_bytes()).map_err(|e| format!("send: {e}"))?;
    let mut raw = Vec::new();
    s.take(1 << 20).read_to_end(&mut raw).map_err(|e| format!("read: {e}"))?;
    let split = raw.windows(4).position(|w| w == b"\r\n\r\n").ok_or("no response head")?;
    let head = String::from_utf8_lossy(&raw[..split]).to_ascii_lowercase();
    let code = head.split(' ').nth(1).and_then(|c| c.parse().ok()).ok_or("bad status line")?;
    let body = &raw[split + 4..];
    if head.contains("transfer-encoding: chunked") {
        return Ok((code, dechunk(body).ok_or("bad chunked body")?));
    }
    Ok((code, body.to_vec()))
}

fn dechunk(mut b: &[u8]) -> Option<Vec<u8>> {
    let mut out = Vec::new();
    loop {
        let eol = b.windows(2).position(|w| w == b"\r\n")?;
        let n = usize::from_str_radix(std::str::from_utf8(&b[..eol]).ok()?.split(';').next()?.trim(), 16).ok()?;
        b = &b[eol + 2..];
        if n == 0 {
            return Some(out);
        }
        out.extend_from_slice(b.get(..n)?);
        b = b.get(n + 2..)?;
    }
}

#[cfg(test)]
mod tests {
    use std::{collections::HashMap, net::TcpListener, sync::Mutex};

    use super::*;
    use crate::intents::tests::tmpdir;

    const T0: u64 = 1_800_000_000_000;
    const DAY: u64 = 86_400_000;

    fn open(dir: &Path, now: u64) -> Mutex<Journal> {
        Mutex::new(Journal::open(dir, now).unwrap())
    }
    /// A Torii that answers from a table; unlisted hashes are not found.
    fn torii(table: &[(&str, Result<Tx, &str>)]) -> StatusFn {
        let t: HashMap<String, Result<Tx, String>> = table
            .iter()
            .map(|(k, v)| (k.to_string(), match v { Ok(Tx::Applied) => Ok(Tx::Applied), Ok(Tx::Dead) => Ok(Tx::Dead), Ok(Tx::InFlight) => Ok(Tx::InFlight), Ok(Tx::NotFound) => Ok(Tx::NotFound), Err(e) => Err(e.to_string()) }))
            .collect();
        Box::new(move |h| match t.get(h) {
            Some(Ok(Tx::Applied)) => Ok(Tx::Applied),
            Some(Ok(Tx::Dead)) => Ok(Tx::Dead),
            Some(Ok(Tx::InFlight)) => Ok(Tx::InFlight),
            Some(Err(e)) => Err(e.clone()),
            _ => Ok(Tx::NotFound),
        })
    }

    #[test]
    fn counts_applied_and_in_flight_only_and_flags_a_complete_journal() {
        let dir = tmpdir("usage");
        let j = open(&dir, T0);
        let since = T0 + 10;
        {
            let mut g = j.lock().unwrap();
            for (tx, a, amt) in [("a", "RD", 100u128), ("b", "RD", 20), ("c", "RD", 3), ("d", "RD", 4000), ("e", "RD", 5), ("f", "DFABI", 7)] {
                g.record(tx, a, amt, since + 1).unwrap();
            }
            g.record("a", "RD", 999, since + 2).unwrap(); // same tx again: ignored
        }
        // a applied, b rejected, c queued, d never submitted (denied), e queued too, f is another token
        let st = torii(&[("a", Ok(Tx::Applied)), ("b", Ok(Tx::Dead)), ("c", Ok(Tx::InFlight)), ("e", Ok(Tx::InFlight)), ("f", Ok(Tx::Applied))]);
        let now = since + 5000;
        assert_eq!(usage(&j, &st, "RD", since, now), UsageOut { amount: "108".into(), complete: true });
        assert_eq!(usage(&j, &st, "DFABI", since, now), UsageOut { amount: "7".into(), complete: true });
        // d is not found: inside the grace it is still asked about, then it is final and out for good
        {
            let g = j.lock().unwrap();
            assert_eq!(g.pending("RD", since).iter().map(|p| p.0.as_str()).collect::<Vec<_>>(), ["c", "d", "e"]);
        }
        let later = since + NOT_FOUND_GRACE_MS + 10;
        assert_eq!(usage(&j, &st, "RD", since, later).amount, "108");
        assert_eq!(j.lock().unwrap().pending("RD", since).iter().map(|p| p.0.as_str()).collect::<Vec<_>>(), ["c", "e"]);
        // c applies later: it stays counted, now final
        let st2 = torii(&[("a", Ok(Tx::Applied)), ("c", Ok(Tx::Applied)), ("e", Ok(Tx::Dead))]);
        assert_eq!(usage(&j, &st2, "RD", since, later), UsageOut { amount: "103".into(), complete: true });
        // finals are cached: a Torii that is down no longer matters for them
        let down = torii(&[]);
        assert_eq!(usage(&j, &down, "RD", since, later), UsageOut { amount: "103".into(), complete: true });
        // a record before `since` is outside the window
        j.lock().unwrap().record("old", "RD", 1, since - 1).unwrap();
        let st3 = torii(&[("old", Ok(Tx::Applied))]);
        assert_eq!(usage(&j, &st3, "RD", since, later).amount, "103");
    }

    #[test]
    fn complete_is_false_when_the_journal_started_after_since_or_torii_is_in_doubt() {
        let dir = tmpdir("doubt");
        let j = open(&dir, T0);
        j.lock().unwrap().record("a", "RD", 10, T0 + 5).unwrap();
        let ok = torii(&[("a", Ok(Tx::Applied))]);
        // journal started at T0: a window that began at T0 is covered, one that began a ms earlier is not
        assert!(usage(&j, &ok, "RD", T0, T0 + 10).complete);
        assert_eq!(usage(&j, &ok, "RD", T0 - 1, T0 + 10), UsageOut { amount: "10".into(), complete: false });
        // a status lookup that fails is doubt, not zero
        let j2 = open(&tmpdir("doubt2"), T0);
        j2.lock().unwrap().record("a", "RD", 10, T0 + 5).unwrap();
        let broken = torii(&[("a", Err("connection refused"))]);
        assert!(!usage(&j2, &broken, "RD", T0, T0 + 10).complete);
        // since older than the retention cannot be answered
        assert!(!usage(&j, &ok, "RD", T0, T0 + 3 * DAY).complete);
        // no records: zero and complete
        assert_eq!(usage(&open(&tmpdir("empty"), T0), &ok, "RD", T0, T0 + 1), UsageOut { amount: "0".into(), complete: true });
    }

    #[test]
    fn restart_keeps_records_finals_and_start_time_but_a_new_dir_starts_incomplete() {
        let dir = tmpdir("jrestart");
        let since = T0 + 100;
        {
            let j = open(&dir, T0);
            let mut g = j.lock().unwrap();
            g.record("a", "RD", 10, since + 1).unwrap();
            g.record("b", "RD", 20, since + 2).unwrap();
            drop(g);
            let st = torii(&[("a", Ok(Tx::Applied)), ("b", Ok(Tx::InFlight))]);
            assert_eq!(usage(&j, &st, "RD", since, since + 3).amount, "30");
        }
        // container restart: same dir, later clock. a is final from the file, b is asked again.
        let j = open(&dir, T0 + 5000);
        assert_eq!(j.lock().unwrap().started_at, T0, "the start is not reset by a restart");
        let st = torii(&[("b", Ok(Tx::Applied))]);
        assert_eq!(usage(&j, &st, "RD", since, since + 6000), UsageOut { amount: "30".into(), complete: true });
        // pod restart: empty dir, the journal begins after `since`
        let fresh = open(&tmpdir("jpod"), since + 6000);
        assert_eq!(usage(&fresh, &st, "RD", since, since + 6001), UsageOut { amount: "0".into(), complete: false });
    }

    #[test]
    fn torn_last_line_is_ignored_but_a_bad_middle_line_is_an_error() {
        let dir = tmpdir("torn");
        {
            let j = open(&dir, T0);
            j.lock().unwrap().record("a", "RD", 10, T0 + 1).unwrap();
        }
        let p = dir.join(FILE);
        let mut f = OpenOptions::new().append(true).open(&p).unwrap();
        f.write_all(br#"{"t":"rec","tx":"b","ass"#).unwrap();
        drop(f);
        let j = Journal::open(&dir, T0 + 2).unwrap();
        assert_eq!(j.len(), 1);
        assert!(!fs::read_to_string(&p).unwrap().contains(r#""tx":"b""#), "compaction dropped the torn tail");
        let mut text = fs::read_to_string(&p).unwrap();
        text.push_str("garbage\n");
        text.push_str(&format!("{}\n", serde_json::to_string(&Line::Fin { tx: "a".into(), state: Final::Dead }).unwrap()));
        fs::write(&p, text).unwrap();
        assert!(Journal::open(&dir, T0 + 3).is_err());
        fs::write(&p, "").unwrap();
        assert!(Journal::open(&dir, T0 + 3).is_err(), "no start line");
    }

    #[test]
    fn a_full_journal_drops_the_record_and_marks_the_window_incomplete() {
        let dir = tmpdir("full");
        let mut j = Journal::open(&dir, T0).unwrap();
        for i in 0..MAX_RECS {
            j.recs.insert(format!("{i}"), Rec { asset: "X".into(), amount: 1, ts: T0 + 1, state: State::Done(Final::Dead) });
        }
        j.record("late", "RD", 5, T0 + 50).unwrap();
        assert!(!j.recs.contains_key("late"));
        let j = Mutex::new(j);
        let ok = torii(&[]);
        assert!(!usage(&j, &ok, "RD", T0 + 40, T0 + 60).complete, "window containing the drop");
        assert!(usage(&j, &ok, "RD", T0 + 51, T0 + 60).complete, "a later window is clean again");
        // the gap survives a restart
        drop(j);
        // (MAX_RECS fake records were never written, only the gap line)
        let j = open(&dir, T0 + 100);
        assert!(!usage(&j, &ok, "RD", T0 + 40, T0 + 110).complete);
    }

    #[test]
    fn compaction_drops_old_records_and_keeps_the_start() {
        let dir = tmpdir("compact");
        {
            let j = open(&dir, T0);
            let mut g = j.lock().unwrap();
            g.record("old", "RD", 1, T0 + 1).unwrap();
            g.record("new", "RD", 2, T0 + 2 * DAY + 1).unwrap();
        }
        let j = Journal::open(&dir, T0 + 2 * DAY + 5).unwrap();
        assert_eq!((j.len(), j.started_at), (1, T0));
    }

    #[test]
    fn since_parser_takes_only_utc_z() {
        assert_eq!(parse_since("1970-01-01T00:00:00Z"), Some(0));
        assert_eq!(parse_since("2026-11-04T17:00:00Z"), Some(1_793_811_600_000));
        assert_eq!(parse_since("2000-03-01T00:00:00Z"), Some(951_868_800_000));
        assert_eq!(parse_since("2024-02-29T23:59:59Z"), Some(1_709_251_199_000));
        for bad in ["", "2026-11-04", "2026-11-04T17:00:00", "2026-11-04T17:00:00+07:00", "2026-13-04T17:00:00Z", "2026-11-04T25:00:00Z", "2026-11-04 17:00:00Z", "2026-11-0aT17:00:00Z", "1969-12-31T23:59:59Z"] {
            assert_eq!(parse_since(bad), None, "{bad}");
        }
    }

    /// The real client against a fake Torii on a loopback socket.
    #[test]
    fn torii_client_maps_status_bodies_and_fails_on_anything_else() {
        let serve = |responses: Vec<(&'static str, String)>| {
            let l = TcpListener::bind(("localhost", 0)).unwrap();
            let addr = l.local_addr().unwrap();
            std::thread::spawn(move || {
                for (head, body) in responses {
                    let (mut c, _) = l.accept().unwrap();
                    let mut req = Vec::new();
                    let mut buf = [0u8; 2048];
                    while !req.windows(4).any(|w| w == b"\r\n\r\n") {
                        let n = c.read(&mut buf).unwrap();
                        req.extend_from_slice(&buf[..n]);
                    }
                    let req = String::from_utf8_lossy(&req).into_owned();
                    assert!(req.starts_with("GET /v1/pipeline/transactions/status?hash="), "{req}");
                    assert!(req.to_ascii_lowercase().contains("accept: application/json"));
                    write!(c, "HTTP/1.1 {head}\r\nConnection: close\r\n\r\n{body}").unwrap();
                }
            });
            torii_status(&format!("http://{addr}")).unwrap()
        };
        let h = "ab".repeat(32);
        let kind = |k: &str| format!(r#"{{"hash":"{h}","status":{{"kind":"{k}","block_height":3}},"scope":"local","resolved_from":"state"}}"#);
        let st = serve(vec![
            ("200 OK\r\nContent-Type: application/json", kind("Applied")),
            ("200 OK", kind("Rejected")),
            ("200 OK", kind("Expired")),
            ("200 OK", kind("Queued")),
            ("200 OK", kind("Committed")),
            ("404 Not Found", format!(r#"{{"hash":"{h}","scope":"local"}}"#)),
            ("503 Service Unavailable", "x".into()),
            ("200 OK", "not json".into()),
            ("200 OK", r#"{"status":{}}"#.into()),
            ("200 OK\r\nTransfer-Encoding: chunked", format!("{:x}\r\n{}\r\n0\r\n\r\n", kind("Applied").len(), kind("Applied"))),
        ]);
        let got: Vec<_> = (0..10).map(|_| st(&h)).collect();
        assert_eq!(got[..6], [Ok(Tx::Applied), Ok(Tx::Dead), Ok(Tx::Dead), Ok(Tx::InFlight), Ok(Tx::InFlight), Ok(Tx::NotFound)]);
        assert!(got[6].is_err() && got[7].is_err() && got[8].is_err());
        assert_eq!(got[9], Ok(Tx::Applied));
        // a hash that is not 64 hex never reaches the socket
        assert!(st("../x").is_err());
        // nothing listening: an error, not a zero
        let dead = TcpListener::bind(("localhost", 0)).unwrap();
        let url = format!("http://{}", dead.local_addr().unwrap());
        drop(dead);
        assert!(torii_status(&url).unwrap()(&h).is_err());
        for bad in ["https://x:1", "x:1", "http://", "http://x:1/path", "http://u@x:1"] {
            assert!(torii_status(bad).is_err(), "{bad}");
        }
    }
}
