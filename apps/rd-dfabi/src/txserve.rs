//! `decode-tx serve`: the smallest HTTP/1.1 server for the OPA gateway's sidecar, POST only, JSON out. Routes:
//!   /decode            tx body -> TxView (and the decode is journaled for /usage, usage.rs)
//!   /intent/decode     rendered DvP box -> {"ok":true,"instruction":<dvp>}
//!   /intent/register   same input; stores the intent (intents.rs). `/gw/intent` is the same route: Envoy forwards the allowed
//!                      client request here under either path
//!   /intent/lookup     {"intent_hash","authority"?} -> {status,buyer,intent_hash,expires_at}; an active intent is consumed
//!   /usage             {"token","since"} -> {"amount","complete"}. `/gw/usage` is the same route
//! Tx and box inputs come in two forms: the raw body with its Content-Type, or the OPA `http.send` shape (`Content-Type:
//! application/json`, body `{"b64": <body, base64>, "ct": <its Content-Type>}`; other keys such as `path`/`id` are ignored).
//! The OPA gateway calls it on loopback, next to the policy engine. Errors are always `{"ok":false,"error":{code,message}}`
//! with a non-2xx status (codes in txview.rs plus bad_request, not_dvp, store_full, journal, unknown_token, bad_since).
//! std only: one thread per connection, `Connection: close`, no chunked bodies, no keep-alive.
//! ponytail: thread per connection, fine for a loopback sidecar; put a pool in front if one gateway ever sees thousands/s.

use std::{
    collections::BTreeMap,
    io::{Read, Write},
    net::{TcpListener, TcpStream},
    sync::{Arc, Mutex},
    time::Duration,
};

use base64::Engine;
use serde::Deserialize;

use crate::{
    intents::{IntentStore, RegErr},
    txview::{DecodeErr, Format, Instr, TxView, content_format},
    usage::{Journal, StatusFn, usage},
};

/// Torii's tx body limit in the design (1 MiB); a bigger body is refused before it is decoded.
pub const MAX_BODY: usize = 1 << 20;
const MAX_HEAD: usize = 16 << 10;
const IO_TIMEOUT: Duration = Duration::from_secs(5);

pub type DecodeFn = fn(&[u8], Format) -> Result<TxView, DecodeErr>;

/// Rendered DvP box -> the dvp instruction (any other instruction is returned as it is; the route refuses it).
pub type IntentFn = fn(&[u8], Format) -> Result<Instr, DecodeErr>;

/// Everything the routes share. The locks are taken in the order intents, journal and never held across a Torii call.
pub struct Ctx {
    pub decode: DecodeFn,
    pub intent_decode: IntentFn,
    pub intents: Mutex<IntentStore>,
    pub journal: Mutex<Journal>,
    /// token name -> asset definition id (`--asset RD=<id>`): the only assets that are journaled or reported by /usage.
    pub assets: BTreeMap<String, String>,
    /// Torii's public tx-status route.
    pub status: StatusFn,
    /// Unix ms.
    pub now: Box<dyn Fn() -> u64 + Send + Sync>,
}

pub fn serve(listener: TcpListener, ctx: Arc<Ctx>) -> std::io::Result<()> {
    for conn in listener.incoming() {
        let Ok(stream) = conn else { continue };
        let ctx = ctx.clone();
        std::thread::spawn(move || {
            let _ = handle(stream, &ctx);
        });
    }
    Ok(())
}

fn respond(s: &mut TcpStream, status: u16, reason: &str, body: &str) -> std::io::Result<()> {
    write!(
        s,
        "HTTP/1.1 {status} {reason}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
        body.len()
    )?;
    s.flush()
}

fn fail(s: &mut TcpStream, status: u16, reason: &str, code: &str, msg: &str) -> std::io::Result<()> {
    respond(s, status, reason, &serde_json::to_string(&DecodeErr::new(code, msg)).unwrap())
}

fn handle(mut s: TcpStream, ctx: &Ctx) -> std::io::Result<()> {
    s.set_read_timeout(Some(IO_TIMEOUT))?;
    s.set_write_timeout(Some(IO_TIMEOUT))?;
    // Head: read until the blank line. Anything read past it is the start of the body.
    let mut buf = Vec::new();
    let mut chunk = [0u8; 4096];
    let head_end = loop {
        if let Some(i) = buf.windows(4).position(|w| w == b"\r\n\r\n") {
            break i;
        }
        if buf.len() > MAX_HEAD {
            return fail(&mut s, 431, "Request Header Fields Too Large", "decode_failed", "request head too large");
        }
        let n = s.read(&mut chunk)?;
        if n == 0 {
            return Ok(());
        }
        buf.extend_from_slice(&chunk[..n]);
    };
    let head = String::from_utf8_lossy(&buf[..head_end]).into_owned();
    let mut lines = head.split("\r\n");
    let mut rl = lines.next().unwrap_or("").split(' ');
    let (method, path) = (rl.next().unwrap_or(""), rl.next().unwrap_or(""));
    let mut content_types = Vec::new();
    let mut length: Option<usize> = None;
    let mut chunked = false;
    for l in lines {
        let Some((k, v)) = l.split_once(':') else { continue };
        match k.trim().to_ascii_lowercase().as_str() {
            "content-type" => content_types.push(v.trim().to_string()),
            "content-length" => length = v.trim().parse().ok(),
            "transfer-encoding" => chunked = true,
            _ => {}
        }
    }
    if !matches!(path, "/decode" | "/intent/decode" | "/intent/register" | "/gw/intent" | "/intent/lookup" | "/usage" | "/gw/usage") {
        return fail(&mut s, 404, "Not Found", "decode_failed", "unknown route");
    }
    if method != "POST" {
        return fail(&mut s, 405, "Method Not Allowed", "decode_failed", "only POST");
    }
    if chunked {
        return fail(&mut s, 411, "Length Required", "decode_failed", "chunked bodies are not accepted; send Content-Length");
    }
    let Some(len) = length else {
        return fail(&mut s, 411, "Length Required", "decode_failed", "Content-Length required");
    };
    if len > MAX_BODY {
        return fail(&mut s, 413, "Payload Too Large", "too_large", "body exceeds 1 MiB");
    }
    let mut body = buf[head_end + 4..].to_vec();
    if body.len() > len {
        return fail(&mut s, 400, "Bad Request", "decode_failed", "bytes after the declared body");
    }
    while body.len() < len {
        let n = s.read(&mut chunk)?;
        if n == 0 {
            return fail(&mut s, 400, "Bad Request", "decode_failed", "body shorter than Content-Length");
        }
        body.extend_from_slice(&chunk[..n]);
    }
    // Torii: Content-Type must appear exactly once.
    let ct = if content_types.len() == 1 { Some(content_types[0].as_str()) } else { None };
    let result = match path {
        "/decode" => do_decode(ctx, ct, body),
        "/intent/decode" => do_intent_decode(ctx, ct, body).map(|d| serde_json::json!({"ok": true, "instruction": Instr::Dvp(d)}).to_string()),
        "/intent/register" | "/gw/intent" => do_register(ctx, ct, body),
        "/intent/lookup" => do_lookup(ctx, ct, &body),
        _ => do_usage(ctx, ct, &body),
    };
    match result {
        Ok(out) => respond(&mut s, 200, "OK", &out),
        Err(e) => {
            let (status, reason) = match e.error.code.as_str() {
                "bad_content_type" => (415, "Unsupported Media Type"),
                "bad_request" => (400, "Bad Request"),
                "store_full" => (503, "Service Unavailable"),
                "io" | "journal" => (500, "Internal Server Error"),
                _ => (422, "Unprocessable Entity"),
            };
            respond(&mut s, status, reason, &serde_json::to_string(&e).unwrap())
        }
    }
}

type Out = Result<String, DecodeErr>;

fn do_decode(ctx: &Ctx, ct: Option<&str>, body: Vec<u8>) -> Out {
    let (body, ct) = unwrap_envelope(ct, body)?;
    let v = content_format(ct.as_deref()).and_then(|f| (ctx.decode)(&body, f))?;
    // A decode that is an outflow is journaled before the answer leaves; a journal that cannot write must not let it through.
    if let Some((asset, amount)) = outflow(ctx, &v) {
        let now = (ctx.now)();
        ctx.journal.lock().unwrap().record(&v.tx_hash, &asset, amount, now).map_err(|e| DecodeErr::new("journal", format!("journal write: {e}")))?;
    }
    Ok(serde_json::to_string(&v).unwrap())
}

/// The rendered DvP box (`iroha -o ... settlement dvp`, `["<base64>"]`) as a Dvp view; anything else is `not_dvp`.
fn do_intent_decode(ctx: &Ctx, ct: Option<&str>, body: Vec<u8>) -> Result<crate::txview::Dvp, DecodeErr> {
    let (body, ct) = unwrap_envelope(ct, body)?;
    match content_format(ct.as_deref()).and_then(|f| (ctx.intent_decode)(&body, f))? {
        Instr::Dvp(d) => Ok(d),
        _ => Err(DecodeErr::new("not_dvp", "the body is not exactly one DvP settlement instruction")),
    }
}

fn do_register(ctx: &Ctx, ct: Option<&str>, body: Vec<u8>) -> Out {
    let d = do_intent_decode(ctx, ct, body)?;
    let now = (ctx.now)();
    match ctx.intents.lock().unwrap().register(&d, now) {
        Ok(e) => Ok(serde_json::json!({"ok": true, "status": "active", "intent_hash": e.intent_hash, "buyer": e.buyer, "expires_at": e.expires_at}).to_string()),
        Err(RegErr::Full) => Err(DecodeErr::new("store_full", "too many active intents")),
        Err(RegErr::Io(e)) => Err(DecodeErr::new("io", format!("intent store write: {e}"))),
    }
}

#[derive(Deserialize)]
struct LookupReq {
    intent_hash: String,
    /// The signer of the consent. Optional; when present only the buyer consumes the intent.
    authority: Option<String>,
}

#[derive(Deserialize)]
struct UsageReq {
    token: String,
    since: String,
}

/// A JSON request body (lookup, usage): `application/json`, exactly the keys we read (others ignored).
fn json_req<T: serde::de::DeserializeOwned>(ct: Option<&str>, body: &[u8]) -> Result<T, DecodeErr> {
    if !matches!(content_format(ct), Ok(Format::Json)) {
        return Err(DecodeErr::new("bad_content_type", "Content-Type must be application/json"));
    }
    serde_json::from_slice(body).map_err(|e| DecodeErr::new("bad_request", format!("request body: {e}")))
}

fn do_lookup(ctx: &Ctx, ct: Option<&str>, body: &[u8]) -> Out {
    let q: LookupReq = json_req(ct, body)?;
    let now = (ctx.now)();
    let out = ctx.intents.lock().unwrap().lookup(&q.intent_hash, q.authority.as_deref(), now).map_err(|e| DecodeErr::new("io", format!("intent store write: {e}")))?;
    Ok(serde_json::to_string(&out).unwrap())
}

fn do_usage(ctx: &Ctx, ct: Option<&str>, body: &[u8]) -> Out {
    let q: UsageReq = json_req(ct, body)?;
    let asset = ctx.assets.get(&q.token).ok_or_else(|| DecodeErr::new("unknown_token", "token is not configured"))?;
    let since = crate::usage::parse_since(&q.since).ok_or_else(|| DecodeErr::new("bad_since", "since must be YYYY-MM-DDTHH:MM:SSZ"))?;
    Ok(serde_json::to_string(&usage(&ctx.journal, &ctx.status, asset, since, (ctx.now)())).unwrap())
}

/// What this decoded tx sends out of its signer, in whole units of a configured asset: a transfer, the seller's delivery leg
/// of a DvP, or the buyer's consent for a registered intent (the payment leg). The rego's per-day outflows are the same three
/// (mint and burn are not counted). Only a signed, norito, one-instruction tx counts; Torii's status is the real filter.
fn outflow(ctx: &Ctx, v: &TxView) -> Option<(String, u128)> {
    if v.encoding != "norito" || !v.signature_ok || v.executable != "instructions" {
        return None;
    }
    let [i] = v.instructions.as_slice() else { return None };
    let leg = |asset: &str, quantity: &str, scale: u32, from: &str| {
        let counted = scale == 0 && from == v.authority && ctx.assets.values().any(|a| a == asset) && !quantity.is_empty() && quantity.bytes().all(|c| c.is_ascii_digit());
        counted.then(|| quantity.parse::<u128>().ok().filter(|q| *q > 0).map(|q| (asset.to_string(), q))).flatten()
    };
    match i {
        Instr::Transfer(m) => leg(&m.asset_definition, &m.quantity, m.scale, m.from.as_deref()?),
        Instr::Dvp(d) => leg(&d.delivery.asset_definition, &d.delivery.quantity, d.delivery.scale, &d.delivery.from),
        Instr::Grant(g) if g.permission.as_deref() == Some("CanExecuteSettlement") => {
            let c = g.consent.as_ref()?;
            let intents = ctx.intents.lock().unwrap();
            let e = intents.peek(&c.intent_hash)?;
            let p = &e.instruction.payment;
            leg(&p.asset_definition, &p.quantity, p.scale, &p.from).filter(|_| e.buyer == v.authority)
        }
        _ => None,
    }
}

/// The b64 envelope is recognised only on an `application/json` request whose body is an object with a `b64` key. A raw Torii
/// JSON tx is `{"version","content"}` only, so the two cannot be mixed up. Anything else is the tx body as sent.
fn unwrap_envelope(ct: Option<&str>, body: Vec<u8>) -> Result<(Vec<u8>, Option<String>), DecodeErr> {
    if matches!(content_format(ct), Ok(Format::Json)) {
        if let Ok(serde_json::Value::Object(o)) = serde_json::from_slice(&body) {
            if let Some(b64) = o.get("b64") {
                let bad = |m: String| DecodeErr::new("decode_failed", m);
                let raw = b64.as_str().ok_or_else(|| bad("`b64` must be a string".into()))?;
                let inner = base64::engine::general_purpose::STANDARD.decode(raw).map_err(|e| bad(format!("`b64` is not base64: {e}")))?;
                return Ok((inner, o.get("ct").and_then(|v| v.as_str()).map(str::to_string)));
            }
        }
    }
    Ok((body, ct.map(str::to_string)))
}

/// A context over fake decoders, for this file's tests and the feature tests in decode.rs. Assets RD and DFABI, Torii knows nothing.
#[cfg(test)]
pub(crate) fn test_ctx(decode: DecodeFn, intent_decode: IntentFn, dir: &std::path::Path, now: u64) -> Ctx {
    use crate::{intents::now_ms, usage::Tx};
    Ctx {
        decode,
        intent_decode,
        intents: Mutex::new(IntentStore::open(dir, 600_000, 1024).unwrap()),
        journal: Mutex::new(Journal::open(dir, now).unwrap()),
        assets: [("RD".to_string(), "RDDEF".to_string()), ("DFABI".to_string(), "DFABIDEF".to_string())].into(),
        status: Box::new(|_| Ok(Tx::NotFound)),
        now: Box::new(now_ms),
    }
}

#[cfg(test)]
mod tests {
    use std::{
        net::SocketAddr,
        sync::atomic::{AtomicU64, Ordering},
    };

    use super::*;
    use crate::{
        intents::tests::{dvp, leg, tmpdir},
        txview::{Consent, Grant, Movement},
        usage::Tx,
    };

    const T0: u64 = 1_793_811_600_000; // 2026-11-04T17:00:00Z

    fn view(hash: &str, authority: &str, instructions: Vec<Instr>) -> TxView {
        TxView {
            ok: true,
            encoding: "norito".into(),
            tx_hash: hash.into(),
            signature_ok: true,
            authority: authority.into(),
            chain_id: "c".into(),
            creation_time_ms: 1,
            time_to_live_ms: Some(2),
            nonce: None,
            admission_intent: "ordinary".into(),
            fee_payer: "authority".into(),
            executable: "instructions".into(),
            has_attachments: false,
            has_multisig: false,
            instructions,
        }
    }

    /// The fake decoder: `good` is a plain tx, a JSON TxView is itself, anything else is not canonical.
    fn fake(body: &[u8], f: Format) -> Result<TxView, DecodeErr> {
        if body == b"good" {
            let mut v = view("00", "A", vec![]);
            v.encoding = format!("{f:?}").to_lowercase();
            Ok(v)
        } else {
            serde_json::from_slice(body).map_err(|_| DecodeErr::new("non_canonical", "trailing"))
        }
    }

    /// The fake box decoder: the body is a JSON list holding the instruction; it must be JSON like the real one.
    fn fake_box(body: &[u8], f: Format) -> Result<Instr, DecodeErr> {
        if f != Format::Json {
            return Err(DecodeErr::new("bad_content_type", "json only"));
        }
        let mut l: Vec<Instr> = serde_json::from_slice(body).map_err(|e| DecodeErr::new("decode_failed", e.to_string()))?;
        if l.len() != 1 {
            return Err(DecodeErr::new("decode_failed", "exactly one"));
        }
        Ok(l.remove(0))
    }

    struct Srv {
        addr: SocketAddr,
        ctx: Arc<Ctx>,
        clock: Arc<AtomicU64>,
    }

    fn srv_in(dir: &std::path::Path, edit: impl FnOnce(&mut Ctx)) -> Srv {
        let clock = Arc::new(AtomicU64::new(T0));
        let mut ctx = test_ctx(fake, fake_box, dir, T0);
        let c = clock.clone();
        ctx.now = Box::new(move || c.load(Ordering::SeqCst));
        edit(&mut ctx);
        let ctx = Arc::new(ctx);
        let l = TcpListener::bind(("localhost", 0)).unwrap();
        let addr = l.local_addr().unwrap();
        let c = ctx.clone();
        std::thread::spawn(move || serve(l, c));
        Srv { addr, ctx, clock }
    }

    fn srv() -> Srv {
        srv_in(&tmpdir("srv"), |_| {})
    }

    impl Srv {
        fn raw(&self, raw: &[u8]) -> (u16, String) {
            let mut c = TcpStream::connect(self.addr).unwrap();
            c.write_all(raw).unwrap();
            let mut out = String::new();
            c.read_to_string(&mut out).unwrap();
            (out[9..12].parse().unwrap(), out.split_once("\r\n\r\n").unwrap().1.to_string())
        }
        fn post(&self, path: &str, ct: &str, body: &[u8]) -> (u16, String) {
            self.raw(&post(path, ct, body))
        }
        fn json(&self, path: &str, body: serde_json::Value) -> (u16, serde_json::Value) {
            let (s, b) = self.post(path, "application/json", body.to_string().as_bytes());
            (s, serde_json::from_str(&b).unwrap_or_else(|e| panic!("{e}: {b}")))
        }
        fn at(&self, ms: u64) {
            self.clock.store(ms, Ordering::SeqCst);
        }
    }

    fn post(path: &str, ct: &str, body: &[u8]) -> Vec<u8> {
        let mut r = format!("POST {path} HTTP/1.1\r\nHost: x\r\nContent-Type: {ct}\r\nContent-Length: {}\r\n\r\n", body.len()).into_bytes();
        r.extend_from_slice(body);
        r
    }

    fn call(raw: &[u8]) -> (u16, String) {
        srv().raw(raw)
    }

    fn box_body(h: &str) -> Vec<u8> {
        serde_json::to_vec(&vec![Instr::Dvp(dvp(h))]).unwrap()
    }

    fn transfer(asset: &str, q: &str, from: &str) -> Instr {
        Instr::Transfer(Movement { asset_definition: asset.into(), quantity: q.into(), scale: 0, from: Some(from.into()), to: Some("X".into()), scope: "dataspace:1".into(), dataspace: Some(1) })
    }

    fn consent(h: &str) -> Instr {
        Instr::Grant(Grant {
            grant_kind: "permission".into(),
            permission: Some("CanExecuteSettlement".into()),
            payload: None,
            to: "SELLER".into(),
            consent: Some(Consent { debited_asset: "RDDEF#BUYER#dataspace:1".into(), debited_scope: Some("dataspace:1".into()), debited_dataspace: Some(1), intent_hash: h.into(), settlement_id: "s1".into() }),
        })
    }

    fn decode_tx(s: &Srv, v: &TxView) -> (u16, String) {
        s.post("/decode", "application/json", &serde_json::to_vec(&serde_json::json!({"b64": base64::engine::general_purpose::STANDARD.encode(serde_json::to_vec(v).unwrap()), "ct": "application/x-norito"})).unwrap())
    }

    // --- /decode

    #[test]
    fn decodes_and_maps_errors_to_status() {
        let (s, b) = call(&post("/decode", "application/x-norito", b"good"));
        assert_eq!((s, b.contains(r#""encoding":"norito""#)), (200, true));
        let (s, b) = call(&post("/decode", "application/x-norito", b"goodX"));
        assert_eq!(s, 422);
        assert!(b.contains(r#""ok":false"#) && b.contains("non_canonical"));
        assert_eq!(call(&post("/decode", "text/plain", b"good")).0, 415);
    }

    #[test]
    fn b64_envelope_is_unwrapped_and_its_ct_is_used() {
        let env = |ct: &str| format!(r#"{{"b64":"Z29vZA==","ct":"{ct}","path":"/p","id":"1"}}"#);
        let (s, b) = call(&post("/decode", "application/json", env("application/x-norito").as_bytes()));
        assert_eq!((s, b.contains(r#""encoding":"norito""#)), (200, true));
        // "Z29vZFg=" is "goodX": the decoder's error comes back non-2xx
        let (s, b) = call(&post("/decode", "application/json", br#"{"b64":"Z29vZFg=","ct":"application/x-norito"}"#));
        assert!(s == 422 && b.contains("non_canonical"), "{s} {b}");
        assert_eq!(call(&post("/decode", "application/json", env("text/plain").as_bytes())).0, 415);
        assert_eq!(call(&post("/decode", "application/json", br#"{"b64":"Z29vZA=="}"#)).0, 415);
        assert_eq!(call(&post("/decode", "application/json", br#"{"b64":"%%","ct":"application/x-norito"}"#)).0, 422);
        assert_eq!(call(&post("/decode", "application/json", br#"{"b64":5,"ct":"application/x-norito"}"#)).0, 422);
        // the envelope is only read on application/json: on x-norito the same bytes are just a (bad) tx body
        assert_eq!(call(&post("/decode", "application/x-norito", env("application/x-norito").as_bytes())).0, 422);
    }

    #[test]
    fn refuses_other_routes_chunked_and_oversize() {
        assert_eq!(call(b"GET /decode HTTP/1.1\r\n\r\n").0, 405);
        assert_eq!(call(b"GET /usage HTTP/1.1\r\n\r\n").0, 405);
        assert_eq!(call(b"POST /other HTTP/1.1\r\n\r\n").0, 404);
        // the gateway-facing aliases are only the two client routes, never the internal ones
        for p in ["/gw/decode", "/gw/intent/lookup", "/gw/intent/decode", "/intent", "/decode/"] {
            assert_eq!(call(format!("POST {p} HTTP/1.1\r\n\r\n").as_bytes()).0, 404, "{p}");
        }
        assert_eq!(call(b"POST /decode HTTP/1.1\r\nTransfer-Encoding: chunked\r\nContent-Type: application/json\r\n\r\n").0, 411);
        let big = format!("POST /decode HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: {}\r\n\r\n", MAX_BODY + 1);
        assert_eq!(call(big.as_bytes()).0, 413);
        // two Content-Type headers: Torii refuses, so do we
        let two = b"POST /decode HTTP/1.1\r\nContent-Type: application/json\r\nContent-Type: application/json\r\nContent-Length: 4\r\n\r\ngood";
        assert_eq!(call(two).0, 415);
    }

    // --- /intent/decode

    #[test]
    fn intent_decode_returns_the_dvp_and_refuses_anything_else() {
        let s = srv();
        let (st, b) = s.post("/intent/decode", "application/json", &box_body("h1"));
        assert_eq!(st, 200, "{b}");
        let v: serde_json::Value = serde_json::from_str(&b).unwrap();
        assert_eq!((v["ok"] == true, v["instruction"]["kind"] == "dvp", v["instruction"]["intent_hash"] == "h1"), (true, true, true));
        assert_eq!(v["instruction"]["payment"]["from"], "BUYER");
        // the OPA http.send shape
        let env = serde_json::json!({"b64": base64::engine::general_purpose::STANDARD.encode(box_body("h1")), "ct": "application/json", "path": "/gw/intent"});
        let (st, b) = s.post("/intent/decode", "application/json", env.to_string().as_bytes());
        assert!(st == 200 && b.contains(r#""intent_hash":"h1""#), "{st} {b}");
        // not a dvp, not decodable, wrong media type: non-2xx, and nothing is stored by a decode
        let (st, b) = s.post("/intent/decode", "application/json", &serde_json::to_vec(&vec![transfer("RDDEF", "1", "A")]).unwrap());
        assert!(st == 422 && b.contains("not_dvp"), "{st} {b}");
        assert_eq!(s.post("/intent/decode", "application/json", b"nope").0, 422);
        assert_eq!(s.post("/intent/decode", "application/x-norito", &box_body("h1")).0, 415);
        assert_eq!(s.json("/intent/lookup", serde_json::json!({"intent_hash": "h1"})).1["status"], "unknown");
    }

    // --- /intent/register + /intent/lookup

    #[test]
    fn register_then_lookup_consumes_once_over_both_registration_paths() {
        let s = srv();
        for (path, h) in [("/gw/intent", "h1"), ("/intent/register", "h2")] {
            let (st, b) = s.post(path, "application/json", &box_body(h));
            assert_eq!(st, 200, "{b}");
            let v: serde_json::Value = serde_json::from_str(&b).unwrap();
            assert_eq!(serde_json::json!([v["status"], v["intent_hash"], v["buyer"], v["expires_at"]]), serde_json::json!(["active", h, "BUYER", T0 + 600_000]));
            let (st, a) = s.json("/intent/lookup", serde_json::json!({"intent_hash": h, "path": "/v1/pipeline/transactions", "id": "x"}));
            assert_eq!(st, 200);
            assert_eq!(a, serde_json::json!({"status": "active", "buyer": "BUYER", "intent_hash": h, "expires_at": T0 + 600_000}));
            assert_eq!(s.json("/intent/lookup", serde_json::json!({"intent_hash": h})).1["status"], "consumed");
        }
        assert_eq!(s.json("/intent/lookup", serde_json::json!({"intent_hash": "zzz"})).1, serde_json::json!({"status": "unknown"}));
        // the OPA envelope works for registration too
        let env = serde_json::json!({"b64": base64::engine::general_purpose::STANDARD.encode(box_body("h3")), "ct": "application/json"});
        assert_eq!(s.json("/intent/register", env).0, 200);
        // refusals: not a dvp, bad box, bad media type
        assert_eq!(s.post("/gw/intent", "application/json", &serde_json::to_vec(&vec![transfer("RDDEF", "1", "A")]).unwrap()).0, 422);
        assert_eq!(s.post("/gw/intent", "application/json", b"x").0, 422);
        assert_eq!(s.post("/gw/intent", "text/plain", &box_body("h9")).0, 415);
        assert_eq!(s.json("/intent/lookup", serde_json::json!({"intent_hash": "h9"})).1["status"], "unknown");
    }

    #[test]
    fn lookup_expiry_follows_the_ttl_and_a_wrong_authority_does_not_consume() {
        let s = srv();
        assert_eq!(s.post("/gw/intent", "application/json", &box_body("h1")).0, 200);
        s.at(T0 + 599_999);
        let (_, a) = s.json("/intent/lookup", serde_json::json!({"intent_hash": "h1", "authority": "MALLORY"}));
        assert_eq!(a["status"], "active");
        s.at(T0 + 600_000);
        let (_, a) = s.json("/intent/lookup", serde_json::json!({"intent_hash": "h1", "authority": "BUYER"}));
        assert_eq!(a, serde_json::json!({"status": "expired", "buyer": "BUYER", "intent_hash": "h1", "expires_at": T0 + 600_000}));
        // authority is honoured on a live entry: only the buyer consumes
        assert_eq!(s.post("/gw/intent", "application/json", &box_body("h2")).0, 200);
        assert_eq!(s.json("/intent/lookup", serde_json::json!({"intent_hash": "h2", "authority": "MALLORY"})).1["status"], "active");
        assert_eq!(s.json("/intent/lookup", serde_json::json!({"intent_hash": "h2", "authority": "BUYER"})).1["status"], "active");
        assert_eq!(s.json("/intent/lookup", serde_json::json!({"intent_hash": "h2"})).1["status"], "consumed");
    }

    #[test]
    fn ttl_is_configurable_and_the_cap_refuses_with_503() {
        let dir = tmpdir("cap");
        let s = srv_in(&dir, |c| *c.intents.lock().unwrap() = IntentStore::open(&tmpdir("cap-s"), 1000, 2).unwrap());
        let (st, b) = s.post("/gw/intent", "application/json", &box_body("h1"));
        assert!(st == 200 && b.contains(&format!("\"expires_at\":{}", T0 + 1000)), "{st} {b}");
        assert_eq!(s.post("/gw/intent", "application/json", &box_body("h2")).0, 200);
        let (st, b) = s.post("/gw/intent", "application/json", &box_body("h3"));
        assert!(st == 503 && b.contains("store_full") && b.contains(r#""ok":false"#), "{st} {b}");
        assert_eq!(s.json("/intent/lookup", serde_json::json!({"intent_hash": "h3"})).1["status"], "unknown");
        // a registration of an intent that is already active is not a new slot
        assert_eq!(s.post("/gw/intent", "application/json", &box_body("h1")).0, 200);
        s.at(T0 + 1000);
        assert_eq!(s.post("/gw/intent", "application/json", &box_body("h3")).0, 200);
    }

    #[test]
    fn lookup_and_usage_reject_bad_requests() {
        let s = srv();
        assert_eq!(s.post("/intent/lookup", "application/json", b"{}").0, 400);
        assert_eq!(s.post("/intent/lookup", "application/json", b"not json").0, 400);
        assert_eq!(s.post("/intent/lookup", "text/plain", br#"{"intent_hash":"h"}"#).0, 415);
        assert_eq!(s.post("/usage", "application/json", br#"{"token":"RD"}"#).0, 400);
        assert_eq!(s.post("/usage", "text/plain", br#"{"token":"RD","since":"2026-11-04T17:00:00Z"}"#).0, 415);
    }

    #[test]
    fn registered_intents_survive_a_restart_of_the_process() {
        let dir = tmpdir("restart-srv");
        let s = srv_in(&dir, |_| {});
        assert_eq!(s.post("/gw/intent", "application/json", &box_body("h1")).0, 200);
        assert_eq!(s.post("/gw/intent", "application/json", &box_body("h2")).0, 200);
        assert_eq!(s.json("/intent/lookup", serde_json::json!({"intent_hash": "h2"})).1["status"], "active");
        let s2 = srv_in(&dir, |_| {});
        assert_eq!(s2.json("/intent/lookup", serde_json::json!({"intent_hash": "h2"})).1["status"], "consumed");
        assert_eq!(s2.json("/intent/lookup", serde_json::json!({"intent_hash": "h1"})).1["status"], "active");
        // a new pod (empty state dir) knows nothing: fail closed
        let s3 = srv_in(&tmpdir("restart-pod"), |_| {});
        assert_eq!(s3.json("/intent/lookup", serde_json::json!({"intent_hash": "h1"})).1["status"], "unknown");
    }

    // --- /usage

    fn usage_of(s: &Srv, token: &str) -> (u16, serde_json::Value) {
        s.json("/usage", serde_json::json!({"token": token, "since": "2026-11-04T17:00:00Z"}))
    }

    #[test]
    fn decoded_outflows_are_journaled_once_and_usage_counts_what_torii_applied() {
        let dir = tmpdir("usage-srv");
        let s = srv_in(&dir, |c| {
            c.status = Box::new(|h| {
                Ok(match h {
                    "a1" => Tx::Applied,
                    "a2" => Tx::Applied,
                    "r1" => Tx::Dead,
                    "q1" => Tx::InFlight,
                    "d1" => Tx::Applied,
                    "c1" => Tx::Applied,
                    "m1" => Tx::Applied,
                    _ => Tx::NotFound,
                })
            })
        });
        // the journal starts at T0 = since: complete
        for v in [
            view("a1", "A", vec![transfer("RDDEF", "100", "A")]),
            view("a2", "A", vec![transfer("RDDEF", "20", "A")]),
            view("r1", "A", vec![transfer("RDDEF", "1000", "A")]),
            view("q1", "A", vec![transfer("RDDEF", "3", "A")]),
            view("n1", "A", vec![transfer("RDDEF", "9999", "A")]), // never reaches Torii (denied)
            view("t2", "A", vec![transfer("DFABIDEF", "7", "A")]),
            view("m1", "A", vec![Instr::Mint(Movement { asset_definition: "RDDEF".into(), quantity: "50".into(), scale: 0, from: None, to: Some("A".into()), scope: "dataspace:1".into(), dataspace: Some(1) })]),
        ] {
            assert_eq!(decode_tx(&s, &v).0, 200);
        }
        // the same tx decoded again (the other bundle, a client retry) is one record
        assert_eq!(decode_tx(&s, &view("a1", "A", vec![transfer("RDDEF", "100", "A")])).0, 200);
        assert_eq!(usage_of(&s, "RD"), (200, serde_json::json!({"amount": "123", "complete": true})));
        assert_eq!(usage_of(&s, "DFABI"), (200, serde_json::json!({"amount": "0", "complete": true})));
        // a DvP's delivery leg is the seller's outflow; its payment leg is not (that one is counted at the buyer's consent)
        let mut d = dvp("hd");
        d.delivery = leg("RDDEF", "40", "A", "B");
        d.payment = leg("DFABIDEF", "8", "B", "A");
        assert_eq!(decode_tx(&s, &view("d1", "A", vec![Instr::Dvp(d)])).0, 200);
        assert_eq!(usage_of(&s, "RD").1, serde_json::json!({"amount": "163", "complete": true}));
        assert_eq!(usage_of(&s, "DFABI").1, serde_json::json!({"amount": "0", "complete": true}));
    }

    #[test]
    fn what_is_not_the_signers_configured_whole_unit_outflow_is_not_journaled() {
        let s = srv_in(&tmpdir("notrec"), |c| c.status = Box::new(|_| Ok(Tx::Applied)));
        let mut unsigned = view("x1", "A", vec![transfer("RDDEF", "5", "A")]);
        unsigned.signature_ok = false;
        let mut json_enc = view("x2", "A", vec![transfer("RDDEF", "5", "A")]);
        json_enc.encoding = "json".into();
        let mut scaled = view("x3", "A", vec![transfer("RDDEF", "5", "A")]);
        if let Instr::Transfer(m) = &mut scaled.instructions[0] {
            m.scale = 2;
        }
        let mut batch = view("x4", "A", vec![transfer("RDDEF", "5", "A")]);
        batch.executable = "batch".into();
        for v in [
            unsigned,
            json_enc,
            scaled,
            batch,
            view("x5", "A", vec![transfer("RDDEF", "5", "SOMEONE_ELSE")]), // not the signer's holding
            view("x6", "A", vec![transfer("OTHERDEF", "5", "A")]),         // not a configured asset
            view("x7", "A", vec![transfer("RDDEF", "0", "A")]),            // zero
            view("x8", "A", vec![transfer("RDDEF", "-5", "A")]),
            view("x9", "A", vec![transfer("RDDEF", "5", "A"), transfer("RDDEF", "5", "A")]), // the rego allows one instruction
            view("x10", "A", vec![]),
        ] {
            assert_eq!(decode_tx(&s, &v).0, 200);
        }
        assert_eq!(s.ctx.journal.lock().unwrap().len(), 0);
        assert_eq!(usage_of(&s, "RD").1, serde_json::json!({"amount": "0", "complete": true}));
    }

    #[test]
    fn a_consent_for_a_registered_intent_journals_the_buyers_payment_leg() {
        let s = srv_in(&tmpdir("consent"), |c| c.status = Box::new(|_| Ok(Tx::Applied)));
        // payment leg: BUYER pays RD 500 (the test dvp)
        assert_eq!(s.post("/gw/intent", "application/json", &box_body("h1")).0, 200);
        // another account's consent for it, an unknown intent, and a grant of some other permission: nothing
        assert_eq!(decode_tx(&s, &view("c0", "MALLORY", vec![consent("h1")])).0, 200);
        assert_eq!(decode_tx(&s, &view("c9", "BUYER", vec![consent("unknown")])).0, 200);
        let mut other = consent("h1");
        if let Instr::Grant(g) = &mut other {
            g.permission = Some("CanMintAsset".into());
        }
        assert_eq!(decode_tx(&s, &view("c8", "BUYER", vec![other])).0, 200);
        assert_eq!(usage_of(&s, "RD").1, serde_json::json!({"amount": "0", "complete": true}));
        // the buyer's consent: counted, and still counted when the lookup (which consumes) came first
        assert_eq!(s.json("/intent/lookup", serde_json::json!({"intent_hash": "h1"})).1["status"], "active");
        assert_eq!(decode_tx(&s, &view("c1", "BUYER", vec![consent("h1")])).0, 200);
        assert_eq!(usage_of(&s, "RD").1, serde_json::json!({"amount": "500", "complete": true}));
        assert_eq!(usage_of(&s, "DFABI").1, serde_json::json!({"amount": "0", "complete": true}));
    }

    #[test]
    fn usage_is_incomplete_without_a_journal_back_to_since_and_errors_are_not_2xx() {
        let s = srv_in(&tmpdir("usage-inc"), |c| c.status = Box::new(|_| Ok(Tx::Applied)));
        // the clock is T0 and the journal began a moment later than a `since` of T0 - 1 h
        let (st, v) = s.json("/usage", serde_json::json!({"token": "RD", "since": "2026-11-04T16:00:00Z"}));
        assert_eq!((st, v), (200, serde_json::json!({"amount": "0", "complete": false})));
        // Torii in doubt
        let s = srv_in(&tmpdir("usage-doubt"), |c| c.status = Box::new(|_| Err("down".into())));
        assert_eq!(decode_tx(&s, &view("a1", "A", vec![transfer("RDDEF", "5", "A")])).0, 200);
        assert_eq!(usage_of(&s, "RD").1["complete"], false);
        // bad request values
        let (st, v) = usage_of(&s, "EUR");
        assert!(st == 422 && v["error"]["code"] == "unknown_token" && v["ok"] == false, "{st} {v}");
        for since in ["", "2026-11-04", "2026-11-04T17:00:00+07:00"] {
            let (st, v) = s.json("/usage", serde_json::json!({"token": "RD", "since": since}));
            assert!(st == 422 && v["error"]["code"] == "bad_since", "{since}: {st} {v}");
        }
        // `/gw/usage` is the same route
        assert_eq!(s.json("/gw/usage", serde_json::json!({"token": "RD", "since": "2026-11-04T17:00:00Z"})).0, 200);
    }

    #[test]
    fn journal_and_intents_share_one_state_dir_without_clobbering() {
        let dir = tmpdir("shared");
        let s = srv_in(&dir, |c| c.status = Box::new(|_| Ok(Tx::Applied)));
        assert_eq!(s.post("/gw/intent", "application/json", &box_body("h1")).0, 200);
        assert_eq!(decode_tx(&s, &view("a1", "A", vec![transfer("RDDEF", "5", "A")])).0, 200);
        let mut names: Vec<String> = std::fs::read_dir(&dir).unwrap().map(|e| e.unwrap().file_name().into_string().unwrap()).collect();
        names.sort();
        assert_eq!(names, ["intents.json", "journal.jsonl"]);
        // restart: both come back
        let s2 = srv_in(&dir, |c| c.status = Box::new(|_| Ok(Tx::Applied)));
        assert_eq!(usage_of(&s2, "RD").1, serde_json::json!({"amount": "5", "complete": true}));
        assert_eq!(s2.json("/intent/lookup", serde_json::json!({"intent_hash": "h1"})).1["status"], "active");
    }
}
