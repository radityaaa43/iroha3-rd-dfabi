//! The gateway's DvP intent store: what `POST /gw/intent` registers and the consent rule looks up.
//!
//! Flow. Lensa pre-registers the rendered DvP box at the BUYER's gateway (`POST /gw/intent`, OPA allows it first, Envoy then
//! routes it here). The entry is keyed by `DvpIsi::intent_hash` (computed by the decoder with upstream's own
//! `DvpIsi::intent_hash`, iroha_data_model isi/settlement.rs:624) and lives for a TTL. When the buyer's `CanExecuteSettlement`
//! grant arrives, the rego asks `POST /intent/lookup`; that call is the consume (see below).
//!
//! Single use = consume on lookup. Envoy sends an allowed tx straight to Torii, so the sidecar never sees an "it passed"
//! signal, and a rego `allow` is a boolean that cannot be undone or followed by a conditional second call (the final verdict
//! needs both the BI and the bank bundle). So the lookup itself is the atomic check-and-flip: under one lock, an active
//! entry is returned as `active` once, the entry is marked consumed and the file is rewritten (temp file + fsync + rename +
//! dir fsync) BEFORE the answer leaves. Two concurrent consents for one intent cannot both see `active`; a failed write
//! gives HTTP 500 and the entry stays active (the rego denies on a non-200). Cost: a consent that BI allows but another rule
//! denies has burned its intent; the buyer registers again (a re-registration of a consumed or expired intent is allowed).
//! Residual: `lookup` consumes for whoever asks. The rego may send `authority`; then an entry is consumed only for its buyer
//! (an optional field, absent in the current rego, so any signed consent naming the hash can burn it).
//!
//! State is a single file `intents.json` under `--state-dir` (an emptyDir). A container restart keeps it; a POD restart loses
//! every pending intent, which fails closed: a consent for an unknown intent is denied and the buyer registers again.
//! Entries that stopped being usable stay RETAIN_MS in the file because the journal reads the consent's payment leg from them.

use std::{
    collections::BTreeMap,
    fs::{self, File},
    io::{self, Write},
    path::{Path, PathBuf},
    time::{SystemTime, UNIX_EPOCH},
};

use serde::{Deserialize, Serialize};

use crate::txview::Dvp;

pub const DEFAULT_TTL_MS: u64 = 600_000;
pub const DEFAULT_CAP: usize = 1024;
/// A consumed or expired entry stays this long (the consent tx is journaled from its payment leg, whichever bundle asks first).
const RETAIN_MS: u64 = 3_600_000;
const FILE: &str = "intents.json";

pub fn now_ms() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |d| d.as_millis() as u64)
}

/// Replace `dir/name` atomically: temp file in the same dir, fsync it, rename over, fsync the dir.
pub fn write_atomic(dir: &Path, name: &str, bytes: &[u8]) -> io::Result<()> {
    let tmp = dir.join(format!(".{name}.tmp"));
    let mut f = File::create(&tmp)?;
    f.write_all(bytes)?;
    f.sync_all()?;
    drop(f);
    fs::rename(&tmp, dir.join(name))?;
    File::open(dir)?.sync_all()
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Entry {
    pub intent_hash: String,
    /// payment.from of the registered DvP: the account whose consent may consume it.
    pub buyer: String,
    /// Unix ms.
    pub expires_at: u64,
    pub consumed_at: Option<u64>,
    pub instruction: Dvp,
}

impl Entry {
    fn status(&self, now: u64) -> &'static str {
        if self.consumed_at.is_some() {
            "consumed"
        } else if now >= self.expires_at {
            "expired"
        } else {
            "active"
        }
    }
    fn done_at(&self) -> u64 {
        self.consumed_at.unwrap_or(self.expires_at)
    }
}

/// `POST /intent/lookup` answer. Only `status` is present for an unknown hash.
#[derive(Debug, Serialize, Deserialize, PartialEq)]
pub struct Lookup {
    /// active | expired | consumed | unknown
    pub status: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub buyer: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub intent_hash: Option<String>,
    /// Unix ms.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub expires_at: Option<u64>,
}

#[derive(Debug)]
pub enum RegErr {
    /// The cap on active entries is reached: refuse, fail closed.
    Full,
    Io(io::Error),
}

pub struct IntentStore {
    dir: PathBuf,
    ttl_ms: u64,
    cap: usize,
    entries: BTreeMap<String, Entry>,
}

impl IntentStore {
    /// Load `dir/intents.json` if there is one. A file that does not parse is an error, never an empty store.
    pub fn open(dir: &Path, ttl_ms: u64, cap: usize) -> io::Result<Self> {
        fs::create_dir_all(dir)?;
        let entries = match fs::read(dir.join(FILE)) {
            Ok(b) => serde_json::from_slice::<Vec<Entry>>(&b)
                .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, format!("{FILE}: {e}")))?
                .into_iter()
                .map(|e| (e.intent_hash.clone(), e))
                .collect(),
            Err(e) if e.kind() == io::ErrorKind::NotFound => BTreeMap::new(),
            Err(e) => return Err(e),
        };
        Ok(Self { dir: dir.to_path_buf(), ttl_ms, cap, entries })
    }

    fn commit(&mut self, next: BTreeMap<String, Entry>) -> io::Result<()> {
        let list: Vec<&Entry> = next.values().collect();
        write_atomic(&self.dir, FILE, &serde_json::to_vec(&list).expect("entries serialise"))?;
        self.entries = next;
        Ok(())
    }

    /// Register the DvP (its `intent_hash` is the decoder's). An active entry for the same hash is returned unchanged (no TTL
    /// extension, no write); a consumed or expired one is replaced by a fresh active entry.
    pub fn register(&mut self, d: &Dvp, now: u64) -> Result<Entry, RegErr> {
        let mut next = self.entries.clone();
        next.retain(|_, e| now < e.done_at().saturating_add(RETAIN_MS));
        if let Some(e) = next.get(&d.intent_hash) {
            if e.status(now) == "active" {
                return Ok(e.clone());
            }
        }
        next.remove(&d.intent_hash);
        if next.values().filter(|e| e.status(now) == "active").count() >= self.cap {
            return Err(RegErr::Full);
        }
        // Retained dead entries are bounded too: oldest first once the file would pass 4x the cap.
        while next.len() >= self.cap.saturating_mul(4) {
            let Some(k) = next.values().filter(|e| e.status(now) != "active").min_by_key(|e| e.done_at()).map(|e| e.intent_hash.clone()) else {
                return Err(RegErr::Full);
            };
            next.remove(&k);
        }
        let e = Entry {
            intent_hash: d.intent_hash.clone(),
            buyer: d.payment.from.clone(),
            expires_at: now.saturating_add(self.ttl_ms),
            consumed_at: None,
            instruction: d.clone(),
        };
        next.insert(e.intent_hash.clone(), e.clone());
        self.commit(next).map_err(RegErr::Io)?;
        Ok(e)
    }

    /// The consent rule's question. An `active` answer is given once: the entry is durably consumed first. With `authority`
    /// set, only the buyer consumes it; anyone else gets the entry as it is (the rego then denies on the buyer mismatch).
    pub fn lookup(&mut self, hash: &str, authority: Option<&str>, now: u64) -> io::Result<Lookup> {
        let Some(e) = self.entries.get(hash) else {
            return Ok(Lookup { status: "unknown".into(), buyer: None, intent_hash: None, expires_at: None });
        };
        let status = e.status(now);
        let out = Lookup { status: status.into(), buyer: Some(e.buyer.clone()), intent_hash: Some(e.intent_hash.clone()), expires_at: Some(e.expires_at) };
        if status == "active" && authority.is_none_or(|a| a == e.buyer) {
            let mut next = self.entries.clone();
            next.get_mut(hash).expect("present").consumed_at = Some(now);
            self.commit(next)?;
        }
        Ok(out)
    }

    /// The entry in any state (the journal reads a consent's payment leg here).
    pub fn peek(&self, hash: &str) -> Option<&Entry> {
        self.entries.get(hash)
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use crate::txview::Leg;

    pub fn tmpdir(tag: &str) -> PathBuf {
        use std::sync::atomic::{AtomicU32, Ordering};
        static N: AtomicU32 = AtomicU32::new(0);
        let d = std::env::temp_dir().join(format!("rd-dfabi-{tag}-{}-{}", std::process::id(), N.fetch_add(1, Ordering::SeqCst)));
        let _ = fs::remove_dir_all(&d);
        fs::create_dir_all(&d).unwrap();
        d
    }

    pub fn leg(def: &str, q: &str, from: &str, to: &str) -> Leg {
        Leg { asset_definition: def.into(), quantity: q.into(), scale: 0, from: from.into(), to: to.into() }
    }

    pub fn dvp(h: &str) -> Dvp {
        Dvp {
            settlement_id: "s1".into(),
            delivery: leg("DFABIDEF", "5", "SELLER", "BUYER"),
            payment: leg("RDDEF", "500", "BUYER", "SELLER"),
            order: "delivery_then_payment".into(),
            atomicity: "all_or_nothing".into(),
            intent_hash: h.into(),
        }
    }

    const T0: u64 = 1_000_000;

    #[test]
    fn register_then_lookup_is_active_once_then_consumed() {
        let dir = tmpdir("once");
        let mut s = IntentStore::open(&dir, 600_000, 8).unwrap();
        let e = s.register(&dvp("h1"), T0).unwrap();
        assert_eq!((e.buyer.as_str(), e.expires_at), ("BUYER", T0 + 600_000));
        let l = s.lookup("h1", None, T0 + 1).unwrap();
        assert_eq!((l.status.as_str(), l.buyer.as_deref(), l.intent_hash.as_deref(), l.expires_at), ("active", Some("BUYER"), Some("h1"), Some(T0 + 600_000)));
        assert_eq!(s.lookup("h1", None, T0 + 2).unwrap().status, "consumed");
        assert_eq!(s.lookup("h1", None, T0 + 3).unwrap().status, "consumed");
        let u = s.lookup("nope", None, T0).unwrap();
        assert_eq!((u.status.as_str(), u.buyer, u.intent_hash, u.expires_at), ("unknown", None, None, None));
        // the wire shape the rego reads: unknown carries only the status
        assert_eq!(serde_json::to_string(&s.lookup("nope", None, T0).unwrap()).unwrap(), r#"{"status":"unknown"}"#);
    }

    #[test]
    fn ttl_expiry_boundary_and_reregistration() {
        let dir = tmpdir("ttl");
        let mut s = IntentStore::open(&dir, 1000, 8).unwrap();
        s.register(&dvp("h1"), T0).unwrap();
        // still active the ms before the deadline; the deadline itself is expired
        assert_eq!(s.lookup("h1", Some("OTHER"), T0 + 999).unwrap().status, "active");
        assert_eq!(s.lookup("h1", None, T0 + 1000).unwrap().status, "expired");
        // an expired entry is never consumed (and stays expired)
        assert_eq!(s.lookup("h1", None, T0 + 1000).unwrap().status, "expired");
        // registering the same intent again gives a fresh active entry
        let e = s.register(&dvp("h1"), T0 + 5000).unwrap();
        assert_eq!(e.expires_at, T0 + 6000);
        assert_eq!(s.lookup("h1", None, T0 + 5001).unwrap().status, "active");
        assert_eq!(s.lookup("h1", None, T0 + 5002).unwrap().status, "consumed");
        // a consumed intent can be registered again (the buyer retries after a denied consent)
        s.register(&dvp("h1"), T0 + 5003).unwrap();
        assert_eq!(s.lookup("h1", None, T0 + 5004).unwrap().status, "active");
    }

    #[test]
    fn registering_an_active_intent_again_changes_nothing() {
        let dir = tmpdir("idem");
        let mut s = IntentStore::open(&dir, 1000, 8).unwrap();
        let a = s.register(&dvp("h1"), T0).unwrap();
        let b = s.register(&dvp("h1"), T0 + 900).unwrap();
        assert_eq!((a.expires_at, b.expires_at), (T0 + 1000, T0 + 1000));
    }

    #[test]
    fn authority_other_than_the_buyer_does_not_consume() {
        let dir = tmpdir("auth");
        let mut s = IntentStore::open(&dir, 1000, 8).unwrap();
        s.register(&dvp("h1"), T0).unwrap();
        let l = s.lookup("h1", Some("MALLORY"), T0 + 1).unwrap();
        assert_eq!((l.status.as_str(), l.buyer.as_deref()), ("active", Some("BUYER")));
        assert_eq!(s.lookup("h1", Some("BUYER"), T0 + 2).unwrap().status, "active");
        assert_eq!(s.lookup("h1", Some("BUYER"), T0 + 3).unwrap().status, "consumed");
    }

    #[test]
    fn cap_counts_active_entries_and_refuses_the_next() {
        let dir = tmpdir("cap");
        let mut s = IntentStore::open(&dir, 1000, 3).unwrap();
        for i in 0..3 {
            s.register(&dvp(&format!("h{i}")), T0).unwrap();
        }
        assert!(matches!(s.register(&dvp("h3"), T0 + 1), Err(RegErr::Full)));
        // a consumed entry frees a slot; so does expiry
        assert_eq!(s.lookup("h0", None, T0 + 2).unwrap().status, "active");
        s.register(&dvp("h3"), T0 + 3).unwrap();
        assert!(matches!(s.register(&dvp("h4"), T0 + 4), Err(RegErr::Full)));
        s.register(&dvp("h4"), T0 + 1000).unwrap();
        // the refused registration left nothing behind
        assert_eq!(s.lookup("h4", None, T0 + 1000).unwrap().status, "active");
    }

    #[test]
    fn dead_entries_are_dropped_after_retention_and_bounded() {
        let dir = tmpdir("retain");
        let mut s = IntentStore::open(&dir, 1000, 2).unwrap();
        s.register(&dvp("h1"), T0).unwrap();
        s.lookup("h1", None, T0 + 1).unwrap();
        assert!(s.peek("h1").is_some_and(|e| e.consumed_at.is_some()));
        // still there inside the retention window, gone after the next registration past it
        s.register(&dvp("h2"), T0 + RETAIN_MS).unwrap();
        assert!(s.peek("h1").is_some());
        s.register(&dvp("h3"), T0 + RETAIN_MS + 2).unwrap();
        assert!(s.peek("h1").is_none());
        // 4x cap: churn through expired entries never grows the file past 8 entries
        for i in 0..40u64 {
            s.register(&dvp(&format!("c{i}")), T0 + 10_000_000 + i * 2000).unwrap();
        }
        assert!(s.entries.len() <= 8, "{}", s.entries.len());
    }

    #[test]
    fn restart_reloads_pending_and_consumed_state() {
        let dir = tmpdir("restart");
        {
            let mut s = IntentStore::open(&dir, 600_000, 8).unwrap();
            s.register(&dvp("h1"), T0).unwrap();
            s.register(&dvp("h2"), T0).unwrap();
            assert_eq!(s.lookup("h2", None, T0 + 1).unwrap().status, "active");
        }
        let mut s = IntentStore::open(&dir, 600_000, 8).unwrap();
        assert_eq!(s.lookup("h2", None, T0 + 2).unwrap().status, "consumed");
        assert_eq!(s.lookup("h1", None, T0 + 2).unwrap().status, "active");
        assert_eq!(s.lookup("h1", None, T0 + 3).unwrap().status, "consumed");
        // a pod restart is an empty state dir: nothing is known, and unknown is not active
        let fresh = tmpdir("restart-pod");
        assert_eq!(IntentStore::open(&fresh, 600_000, 8).unwrap().lookup("h1", None, T0).unwrap().status, "unknown");
    }

    #[test]
    fn a_corrupt_file_is_an_error_not_an_empty_store() {
        let dir = tmpdir("corrupt");
        fs::write(dir.join(FILE), b"{not json").unwrap();
        assert!(IntentStore::open(&dir, 1000, 8).is_err());
    }

    #[test]
    fn write_is_atomic_no_temp_left_and_old_file_survives_a_failed_commit() {
        let dir = tmpdir("atomic");
        let mut s = IntentStore::open(&dir, 1000, 8).unwrap();
        s.register(&dvp("h1"), T0).unwrap();
        let names: Vec<String> = fs::read_dir(&dir).unwrap().map(|e| e.unwrap().file_name().into_string().unwrap()).collect();
        assert_eq!(names, vec![FILE.to_string()], "no temp file after a commit");
        let before = fs::read(dir.join(FILE)).unwrap();
        // make the commit fail: a directory squats on the temp file name, so File::create errors before anything is replaced
        fs::create_dir(dir.join(format!(".{FILE}.tmp"))).unwrap();
        assert!(matches!(s.register(&dvp("h2"), T0 + 1), Err(RegErr::Io(_))));
        assert!(s.peek("h2").is_none(), "memory did not advance past the disk");
        assert!(s.lookup("h1", None, T0 + 2).is_err(), "a lookup that cannot persist its consume is an error, not an answer");
        assert_eq!(s.peek("h1").unwrap().consumed_at, None, "and the entry stays active");
        assert_eq!(fs::read(dir.join(FILE)).unwrap(), before, "old file untouched");
        fs::remove_dir(dir.join(format!(".{FILE}.tmp"))).unwrap();
        assert_eq!(s.lookup("h1", None, T0 + 3).unwrap().status, "active");
    }

    #[test]
    fn concurrent_lookups_see_active_exactly_once() {
        let dir = tmpdir("race");
        let mut s = IntentStore::open(&dir, 600_000, 8).unwrap();
        s.register(&dvp("h1"), T0).unwrap();
        let s = std::sync::Arc::new(std::sync::Mutex::new(s));
        let hits: Vec<_> = (0..16)
            .map(|_| {
                let s = s.clone();
                std::thread::spawn(move || s.lock().unwrap().lookup("h1", None, T0 + 1).unwrap().status)
            })
            .collect::<Vec<_>>()
            .into_iter()
            .map(|h| h.join().unwrap())
            .collect();
        assert_eq!(hits.iter().filter(|s| *s == "active").count(), 1);
        assert_eq!(hits.iter().filter(|s| *s == "consumed").count(), 15);
    }
}
