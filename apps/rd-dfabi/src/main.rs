//! rd-dfabi: JSON-in / JSON-out CLI the Lensa TS adapter shells out to (like it does with `iroha`).
//! Design: design-b-aps-helper.md (Lensa session scratchpad, to be copied into docs/).
//! M1 live: keys init, pool activate (dry_run plan), balances, doctor (local checks). The rest are stubs until their milestone.
//! Crypto that needs iroha goes through `backend::Backend`; the light build uses `NoAps`, the aps build will plug the real one in.

mod api;
mod backend;
mod cmds;
mod store;
mod tree;
#[cfg(feature = "aps")]
mod aps;

use std::{io::Read, path::PathBuf, process::ExitCode};

use anyhow::{Context, Result};
use api::*;
use clap::{Parser, Subcommand};
use schemars::{JsonSchema, schema_for};
use serde::{Serialize, de::DeserializeOwned};

#[derive(Parser)]
#[command(name = "rd-dfabi", version, about = "RD/DFABI APS helper (JSON in, JSON out)")]
struct Cli {
    /// Wallet/audit-store root (mode 0700). Default: $RD_DFABI_HOME.
    #[arg(long, env = "RD_DFABI_HOME", global = true, default_value = "state/iroha3aps")]
    home: PathBuf,
    /// Read the JSON request from FILE instead of stdin.
    #[arg(long, global = true)]
    input: Option<PathBuf>,
    #[command(subcommand)]
    cmd: Cmd,
}

#[derive(Subcommand)]
enum Cmd {
    /// Create a party wallet (seed, view key, receive authority); BI also gets the auditor key.
    #[command(subcommand)]
    Keys(KeysCmd),
    /// One-time pool activation = initial supply notes (governance key required).
    #[command(subcommand)]
    Pool(PoolCmd),
    /// Private DvP: RD leg in ds-rd, DFABI leg in ds-dfabi, one bundle.
    Dvp,
    /// Public bundle status from the asking party's own Torii (what an outsider sees).
    Status,
    /// Public bundle receipt from the asking party's own Torii.
    Receipt,
    /// BI view: open the audit capsule (audit store first, committee capsule as fallback).
    #[command(subcommand)]
    Capsule(CapsuleCmd),
    /// Party view: decrypt the party's own output notes of a bundle.
    #[command(subcommand)]
    Note(NoteCmd),
    /// Private note balances per party and asset.
    Balances,
    /// BI auditor: approve/reject one bundle, or loop over waiting bundles.
    #[command(subcommand)]
    Auditor(AuditorCmd),
    /// Chain readiness: height, privacy capability, APS activation, committee keys.
    Doctor,
    /// Print the JSON schemas of every command (optionally write them to DIR).
    Schema {
        #[arg(long)]
        out: Option<PathBuf>,
    },
}
#[derive(Subcommand)]
enum KeysCmd {
    Init,
}
#[derive(Subcommand)]
enum PoolCmd {
    Activate,
}
#[derive(Subcommand)]
enum CapsuleCmd {
    Open,
}
#[derive(Subcommand)]
enum NoteCmd {
    Decrypt,
}
#[derive(Subcommand)]
enum AuditorCmd {
    Approve,
    /// Long-lived: NDJSON events on stdout, never plaintext.
    Run,
}

fn read_input<T: DeserializeOwned>(path: &Option<PathBuf>) -> Result<T> {
    let mut raw = String::new();
    match path {
        Some(p) => raw = std::fs::read_to_string(p).with_context(|| format!("read {}", p.display()))?,
        None => {
            std::io::stdin().read_to_string(&mut raw)?;
        }
    }
    if raw.trim().is_empty() {
        raw = "{}".into(); // commands whose request fields are all optional (balances, doctor)
    }
    serde_json::from_str(&raw).context("request is not valid JSON for this command")
}

fn envelope<T: Serialize>(r: Result<T, ErrorBody>) -> (String, u8) {
    let (ok, env) = match r {
        Ok(data) => (true, Envelope { ok: true, data: Some(data), error: None }),
        Err(error) => (false, Envelope { ok: false, data: None, error: Some(error) }),
    };
    (serde_json::to_string(&env).expect("envelope serialises"), if ok { 0 } else { 3 })
}

fn internal(m: String) -> ErrorBody {
    ErrorBody { code: "internal".into(), message: m, retryable: false }
}

fn open_store(cli: &Cli) -> Result<store::Store, ErrorBody> {
    store::Store::open(&cli.home).map_err(internal)
}

fn not_implemented<T>(cmd: &str) -> Result<T, ErrorBody> {
    Err(ErrorBody { code: "not_implemented".into(), message: format!("{cmd}: stub, see design milestones"), retryable: false })
}

/// Parse the request (so schema errors surface now), then call the stub.
fn call<Q: DeserializeOwned, R: Serialize>(cli: &Cli, cmd: &str, f: impl FnOnce(&Cli, Q) -> Result<R, ErrorBody>) -> (String, u8) {
    match read_input::<Q>(&cli.input) {
        Ok(q) => envelope(f(cli, q)),
        Err(e) => envelope::<R>(Err(ErrorBody { code: "bad_request".into(), message: format!("{cmd}: {e:#}"), retryable: false })),
    }
}

/// (name, request schema, response schema). The single list both `schema` and the drift test use.
fn schemas() -> Vec<(&'static str, serde_json::Value, serde_json::Value)> {
    fn s<Q: JsonSchema, R: JsonSchema>(name: &'static str) -> (&'static str, serde_json::Value, serde_json::Value) {
        (name, serde_json::to_value(schema_for!(Q)).unwrap(), serde_json::to_value(schema_for!(Envelope<R>)).unwrap())
    }
    vec![
        s::<KeysInitReq, KeysInitResp>("keys-init"),
        s::<PoolActivateReq, PoolActivateResp>("pool-activate"),
        s::<DvpReq, DvpResp>("dvp"),
        s::<BundleReq, StatusResp>("status"),
        s::<BundleReq, StatusResp>("receipt"),
        s::<CapsuleOpenReq, CapsuleOpenResp>("capsule-open"),
        s::<NoteDecryptReq, NoteDecryptResp>("note-decrypt"),
        s::<BalancesReq, BalancesResp>("balances"),
        s::<AuditorApproveReq, AuditorApproveResp>("auditor-approve"),
        s::<DoctorReq, DoctorResp>("doctor"),
        // Progress is not a response; it is the stderr line format of dvp / pool activate / auditor run.
        ("progress", serde_json::to_value(schema_for!(Progress)).unwrap(), serde_json::Value::Null),
    ]
}

fn dispatch(cli: &Cli) -> (String, u8) {
    match &cli.cmd {
        Cmd::Keys(KeysCmd::Init) => call(cli, "keys init", |c, q: KeysInitReq| {
            let seed = store::random32().map_err(internal)?;
            cmds::keys_init(&open_store(c)?, &backend::NoAps, q, seed)
        }),
        Cmd::Pool(PoolCmd::Activate) => call(cli, "pool activate", |c, q: PoolActivateReq| {
            let store = open_store(c)?;
            cmds::pool_activate(&store, &backend::NoAps, &q, || store::random32().expect("urandom"))
        }),
        Cmd::Dvp => call(cli, "dvp", |_, _: DvpReq| not_implemented::<DvpResp>("dvp")),
        Cmd::Status => call(cli, "status", |_, _: BundleReq| not_implemented::<StatusResp>("status")),
        Cmd::Receipt => call(cli, "receipt", |_, _: BundleReq| not_implemented::<StatusResp>("receipt")),
        Cmd::Capsule(CapsuleCmd::Open) => call(cli, "capsule open", |_, _: CapsuleOpenReq| not_implemented::<CapsuleOpenResp>("capsule open")),
        Cmd::Note(NoteCmd::Decrypt) => call(cli, "note decrypt", |_, _: NoteDecryptReq| not_implemented::<NoteDecryptResp>("note decrypt")),
        Cmd::Balances => call(cli, "balances", |c, q: BalancesReq| cmds::balances(&open_store(c)?, &q)),
        Cmd::Auditor(AuditorCmd::Approve) => call(cli, "auditor approve", |_, _: AuditorApproveReq| not_implemented::<AuditorApproveResp>("auditor approve")),
        Cmd::Auditor(AuditorCmd::Run) => envelope::<()>(not_implemented("auditor run")),
        Cmd::Doctor => call(cli, "doctor", |c, _: DoctorReq| cmds::doctor(&open_store(c)?)),
        Cmd::Schema { out } => {
            let all = schemas();
            if let Some(dir) = out {
                std::fs::create_dir_all(dir).expect("create schema dir");
                for (name, q, r) in &all {
                    write_schema(dir, &format!("{name}.request.json"), q);
                    if !r.is_null() {
                        write_schema(dir, &format!("{name}.response.json"), r);
                    }
                }
            }
            (serde_json::to_string(&all.iter().map(|(n, _, _)| *n).collect::<Vec<_>>()).unwrap(), 0)
        }
    }
}

fn write_schema(dir: &std::path::Path, file: &str, v: &serde_json::Value) {
    std::fs::write(dir.join(file), serde_json::to_string_pretty(v).unwrap() + "\n").expect("write schema");
}

fn main() -> ExitCode {
    let cli = Cli::parse();
    let (out, code) = dispatch(&cli);
    println!("{out}");
    ExitCode::from(code)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn committed_schemas_match_the_types() {
        let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("schema");
        for (name, q, r) in schemas() {
            let want = |v: &serde_json::Value| serde_json::to_string_pretty(v).unwrap() + "\n";
            let got = std::fs::read_to_string(dir.join(format!("{name}.request.json"))).unwrap_or_default();
            assert_eq!(got, want(&q), "{name}.request.json is stale: run `rd-dfabi schema --out apps/rd-dfabi/schema`");
            if !r.is_null() {
                let got = std::fs::read_to_string(dir.join(format!("{name}.response.json"))).unwrap_or_default();
                assert_eq!(got, want(&r), "{name}.response.json is stale");
            }
        }
    }

    #[test]
    fn stub_reports_not_implemented_and_rejects_bad_json() {
        let (out, code) = envelope::<()>(not_implemented("x"));
        assert_eq!(code, 3);
        assert!(out.contains(r#""code":"not_implemented""#));
        assert!(serde_json::from_str::<DvpReq>(r#"{"buyer":"A"}"#).is_err());
        let ok: DvpReq = serde_json::from_str(
            r#"{"buyer":"A","seller":"B","rd_amount":"100","dfabi_amount":"10","auditor":"inline"}"#,
        )
        .unwrap();
        assert_eq!(ok.buyer, Party::A);
    }
}
