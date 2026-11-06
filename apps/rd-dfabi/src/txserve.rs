//! `decode-tx serve`: the smallest HTTP/1.1 server that answers `POST /decode` with the decoder's JSON. Two input forms:
//! the raw tx body with the Content-Type sent to Torii, or the OPA `http.send` shape (`Content-Type: application/json`,
//! body `{"b64": <tx body, base64>, "ct": <its Content-Type>}`; other keys such as `path`/`id` are ignored).
//! The OPA gateway calls it on loopback, next to the policy engine.
//! std only: one thread per connection, `Connection: close`, no chunked bodies, no keep-alive.
//! ponytail: thread per connection, fine for a loopback sidecar; put a pool in front if one gateway ever sees thousands/s.

use std::{
    io::{Read, Write},
    net::{TcpListener, TcpStream},
    time::Duration,
};

use base64::Engine;

use crate::txview::{DecodeErr, Format, TxView, content_format};

/// Torii's tx body limit in the design (1 MiB); a bigger body is refused before it is decoded.
pub const MAX_BODY: usize = 1 << 20;
const MAX_HEAD: usize = 16 << 10;
const IO_TIMEOUT: Duration = Duration::from_secs(5);

pub type DecodeFn = fn(&[u8], Format) -> Result<TxView, DecodeErr>;

pub fn serve(listener: TcpListener, decode: DecodeFn) -> std::io::Result<()> {
    for conn in listener.incoming() {
        let Ok(stream) = conn else { continue };
        std::thread::spawn(move || {
            let _ = handle(stream, decode);
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

fn handle(mut s: TcpStream, decode: DecodeFn) -> std::io::Result<()> {
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
    if path != "/decode" {
        return fail(&mut s, 404, "Not Found", "decode_failed", "only POST /decode");
    }
    if method != "POST" {
        return fail(&mut s, 405, "Method Not Allowed", "decode_failed", "only POST /decode");
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
    let result = unwrap_envelope(ct, body).and_then(|(body, ct)| content_format(ct.as_deref()).and_then(|f| decode(&body, f)));
    match result {
        Ok(v) => respond(&mut s, 200, "OK", &serde_json::to_string(&v).unwrap()),
        Err(e) => {
            let (status, reason) = match e.error.code.as_str() {
                "bad_content_type" => (415, "Unsupported Media Type"),
                _ => (422, "Unprocessable Entity"),
            };
            respond(&mut s, status, reason, &serde_json::to_string(&e).unwrap())
        }
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

#[cfg(test)]
mod tests {
    use super::*;

    fn fake(body: &[u8], f: Format) -> Result<TxView, DecodeErr> {
        if body == b"good" {
            Ok(TxView {
                ok: true,
                encoding: format!("{f:?}").to_lowercase(),
                tx_hash: "00".into(),
                signature_ok: true,
                authority: "A".into(),
                chain_id: "c".into(),
                creation_time_ms: 1,
                time_to_live_ms: Some(2),
                nonce: None,
                admission_intent: "ordinary".into(),
                fee_payer: "authority".into(),
                executable: "instructions".into(),
                has_attachments: false,
                has_multisig: false,
                instructions: vec![],
            })
        } else {
            Err(DecodeErr::new("non_canonical", "trailing"))
        }
    }

    fn call(raw: &[u8]) -> (u16, String) {
        let l = TcpListener::bind(("localhost", 0)).unwrap();
        let addr = l.local_addr().unwrap();
        std::thread::spawn(move || serve(l, fake));
        let mut c = TcpStream::connect(addr).unwrap();
        c.write_all(raw).unwrap();
        let mut out = String::new();
        c.read_to_string(&mut out).unwrap();
        let status = out[9..12].parse().unwrap();
        (status, out.split_once("\r\n\r\n").unwrap().1.to_string())
    }

    fn post(ct: &str, body: &[u8]) -> Vec<u8> {
        let mut r = format!("POST /decode HTTP/1.1\r\nHost: x\r\nContent-Type: {ct}\r\nContent-Length: {}\r\n\r\n", body.len()).into_bytes();
        r.extend_from_slice(body);
        r
    }

    #[test]
    fn decodes_and_maps_errors_to_status() {
        let (s, b) = call(&post("application/x-norito", b"good"));
        assert_eq!((s, b.contains(r#""encoding":"norito""#)), (200, true));
        let (s, b) = call(&post("application/x-norito", b"goodX"));
        assert_eq!(s, 422);
        assert!(b.contains(r#""ok":false"#) && b.contains("non_canonical"));
        assert_eq!(call(&post("text/plain", b"good")).0, 415);
    }

    #[test]
    fn b64_envelope_is_unwrapped_and_its_ct_is_used() {
        let env = |ct: &str| format!(r#"{{"b64":"Z29vZA==","ct":"{ct}","path":"/p","id":"1"}}"#);
        let (s, b) = call(&post("application/json", env("application/x-norito").as_bytes()));
        assert_eq!((s, b.contains(r#""encoding":"norito""#)), (200, true));
        // "Z29vZFg=" is "goodX": the decoder's error comes back non-2xx
        let (s, b) = call(&post("application/json", br#"{"b64":"Z29vZFg=","ct":"application/x-norito"}"#));
        assert!(s == 422 && b.contains("non_canonical"), "{s} {b}");
        assert_eq!(call(&post("application/json", env("text/plain").as_bytes())).0, 415);
        assert_eq!(call(&post("application/json", br#"{"b64":"Z29vZA=="}"#)).0, 415);
        assert_eq!(call(&post("application/json", br#"{"b64":"%%","ct":"application/x-norito"}"#)).0, 422);
        assert_eq!(call(&post("application/json", br#"{"b64":5,"ct":"application/x-norito"}"#)).0, 422);
        // the envelope is only read on application/json: on x-norito the same bytes are just a (bad) tx body
        assert_eq!(call(&post("application/x-norito", env("application/x-norito").as_bytes())).0, 422);
    }

    #[test]
    fn refuses_other_routes_chunked_and_oversize() {
        assert_eq!(call(b"GET /decode HTTP/1.1\r\n\r\n").0, 405);
        assert_eq!(call(b"POST /other HTTP/1.1\r\n\r\n").0, 404);
        assert_eq!(call(b"POST /decode HTTP/1.1\r\nTransfer-Encoding: chunked\r\nContent-Type: application/json\r\n\r\n").0, 411);
        let big = format!("POST /decode HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: {}\r\n\r\n", MAX_BODY + 1);
        assert_eq!(call(big.as_bytes()).0, 413);
        // two Content-Type headers: Torii refuses, so do we
        let two = b"POST /decode HTTP/1.1\r\nContent-Type: application/json\r\nContent-Type: application/json\r\nContent-Length: 4\r\n\r\ngood";
        assert_eq!(call(two).0, 415);
    }
}
