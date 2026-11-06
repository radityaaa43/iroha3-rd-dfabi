//! `probe availability-share-material`: build, offline, the one request body that tells whether the
//! committee-role keys registered on the peers' own BLS keys are accepted as a private-settlement committee.
//!
//! The request is `iroha app nexus private-settlement availability-share` (POST
//! /v1/nexus/private-settlements/legs/availability-shares, signed by the manifest sponsor). Its handler runs
//! `validate_private_settlement_committee_authority_v1` before it checks anything else about the material, so
//! HTTP 200 (Stored / AlreadyStored) proves the roster, PoPs, lane incarnation and committee-role keys are
//! authoritative at `--context-height`. A 400 `private_settlement_invalid_request` is the failure, but it is
//! also what every other policy check returns (padding class, retention, expiry span, network id, ...), so the
//! defaults below follow the shipped config and the three that a network can change are flags.
//!
//! Everything in this file is the part that needs no iroha crate (input parsing, roster order, derived
//! fields, the command line). The typed material is built in `aps::availability_share_material`.
//! Nothing here reads a key store: roster and lifecycle come from JSON files the operator supplies at run time.

use std::path::{Path, PathBuf};

use clap::Args;
use serde_json::Value;
use sha2::{Digest, Sha256};

use crate::{api::ErrorBody, backend::err};

type Res<T> = Result<T, ErrorBody>;

pub const COMMITTEE_VALIDATORS: usize = 4;
pub const BLS_POP_BYTES: usize = 96;
pub const ML_KEM_768_PUBLIC_KEY_BYTES: usize = 1184;

fn bad(m: impl Into<String>) -> ErrorBody {
    err("bad_request", m, false)
}

#[derive(Args, Debug)]
pub struct AvailabilityShareArgs {
    /// Roster JSON: a peers file (array of {public_key, pop_hex}) or a GET /v1/sumeragi/consensus-keys dump.
    /// Read at run time, never embedded. A consensus-keys dump keeps only Committee-role records live at --context-height.
    #[arg(long, value_name = "PATH")]
    pub roster: PathBuf,
    /// GET /v1/nexus/lifecycle JSON: lane ids, dataspace ids and lane incarnations.
    #[arg(long, value_name = "PATH")]
    pub lifecycle: PathBuf,
    /// Network id literal `hash:<UPPERCASE_HEX>#<CHECKSUM>` (the chain's genesis.expected_hash content).
    #[arg(long, conflicts_with = "network_id_file")]
    pub network_id: Option<String>,
    /// File holding the network id literal.
    #[arg(long, value_name = "PATH")]
    pub network_id_file: Option<PathBuf>,
    /// Sponsor account public key (multihash string). The request must be signed by this account.
    #[arg(long, value_name = "PUBLIC_KEY")]
    pub sponsor_public_key: String,
    /// authority_context_height: a block at or after the current lane incarnation started, and at or before the chain tip.
    #[arg(long)]
    pub context_height: u64,
    /// Dataspace of the leg under test (its lane, incarnation and committee are checked).
    #[arg(long, default_value_t = 1)]
    pub dataspace: u64,
    /// Dataspace of the second leg (a manifest needs two; only its lane and incarnation are used).
    #[arg(long, default_value_t = 2)]
    pub other_dataspace: u64,
    /// expiry_height = context height + this. The network caps it at max_expiry_blocks (shipped default 7200).
    #[arg(long, default_value_t = 7000)]
    pub expiry_blocks: u64,
    /// retention_until_height = context height + this. Must stay above stored height + sidecar_retention_blocks (shipped default 1000000).
    #[arg(long, default_value_t = 1_100_000)]
    pub retention_blocks: u64,
    /// Auditor public key JSON {signing_public_key, x25519_hex, ml_kem_768_hex}. Default: a throwaway key generated now, whose private half is dropped.
    #[arg(long, value_name = "PATH")]
    pub auditor_public: Option<PathBuf>,
    /// Chain discriminant for account literals (decimal or 0x hex). Default: the library default.
    #[arg(long, value_parser = parse_u16)]
    pub chain_discriminant: Option<u16>,
}

fn parse_u16(s: &str) -> Result<u16, String> {
    match s.strip_prefix("0x") {
        Some(h) => u16::from_str_radix(h, 16),
        None => s.parse(),
    }
    .map_err(|e| e.to_string())
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RosterEntry {
    /// Multihash public key string, exactly as the chain prints it.
    pub public_key: String,
    pub pop: Vec<u8>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LaneRoute {
    pub dataspace_id: u64,
    pub lane_id: u32,
    /// Bare 64-hex hash.
    pub incarnation: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AuditorPublic {
    pub signing_public_key: String,
    pub x25519: [u8; 32],
    pub ml_kem_768: Vec<u8>,
}

/// Everything the typed builder needs, already parsed and checked for shape.
#[cfg_attr(not(feature = "aps"), allow(dead_code))]
#[derive(Debug, Clone)]
pub struct Plan {
    pub network_id: String,
    pub sponsor_public_key: String,
    pub context_height: u64,
    pub expiry_blocks: u64,
    pub retention_blocks: u64,
    /// Four entries in PublicKey order.
    pub roster: Vec<RosterEntry>,
    pub tested: LaneRoute,
    pub other: LaneRoute,
    pub auditor: Option<AuditorPublic>,
    pub chain_discriminant: Option<u16>,
    /// Fresh per run: makes bundle id, pool ids and nullifiers unique so a re-run is Stored, not Conflict.
    pub salt: [u8; 32],
}

fn strip_0x(s: &str) -> &str {
    s.strip_prefix("0x").unwrap_or(s)
}

fn u64_of(v: &Value) -> Option<u64> {
    v.as_u64().or_else(|| v.as_str().and_then(|s| s.parse().ok()))
}

/// PoP as a hex string (optional 0x) or an array of byte values (how a Vec<u8> field serialises).
fn pop_of(v: &Value) -> Res<Vec<u8>> {
    match v {
        Value::String(s) => hex::decode(strip_0x(s)).map_err(|_| bad("a PoP is not valid hex")),
        Value::Array(a) => a
            .iter()
            .map(|b| b.as_u64().and_then(|n| u8::try_from(n).ok()))
            .collect::<Option<Vec<u8>>>()
            .ok_or_else(|| bad("a PoP array holds a value that is not a byte")),
        _ => Err(bad("a roster record has no usable PoP")),
    }
}

/// Parse a peers file or a consensus-keys dump into unsorted entries.
pub fn parse_roster(raw: &str, context_height: u64) -> Res<Vec<RosterEntry>> {
    let v: Value = serde_json::from_str(raw).map_err(|e| bad(format!("roster is not JSON: {e}")))?;
    let rows = v.as_array().ok_or_else(|| bad("roster must be a JSON array"))?;
    if rows.iter().all(|r| r.get("pop_hex").is_some()) {
        return rows
            .iter()
            .map(|r| -> Res<RosterEntry> {
                let key = r.get("public_key").and_then(Value::as_str).ok_or_else(|| bad("a peers row has no public_key"))?;
                Ok(RosterEntry { public_key: key.to_owned(), pop: pop_of(&r["pop_hex"])? })
            })
            .collect();
    }
    // Consensus-keys dump: keep Committee-role records that are live at the context height; newest activation wins per key.
    let mut best: Vec<(u64, RosterEntry)> = Vec::new();
    for r in rows {
        let committee = r.get("id").is_some_and(|id| id.to_string().contains("Committee"));
        let disabled = r.get("status").is_some_and(|s| s.to_string().contains("Disabled"));
        let activation = r.get("activation_height").and_then(u64_of).unwrap_or(0);
        let expired = r.get("expiry_height").and_then(u64_of).is_some_and(|e| context_height >= e);
        if !committee || disabled || activation > context_height || expired {
            continue;
        }
        let key = r.get("public_key").and_then(Value::as_str).ok_or_else(|| bad("a consensus record has no public_key"))?;
        let entry = RosterEntry { public_key: key.to_owned(), pop: pop_of(r.get("pop").unwrap_or(&Value::Null))? };
        match best.iter_mut().find(|(_, e)| e.public_key == entry.public_key) {
            Some(slot) if slot.0 < activation => *slot = (activation, entry),
            Some(_) => {}
            None => best.push((activation, entry)),
        }
    }
    Ok(best.into_iter().map(|(_, e)| e).collect())
}

/// Four entries, 96-byte PoPs, no duplicates, in PublicKey order.
/// ponytail: sorts on the decoded multihash bytes, which is how upstream `PublicKey::cmp` orders (iroha_crypto lib.rs `impl Ord for PublicKey`);
/// the aps build re-sorts on the real `PeerId` anyway, so a wrong guess here cannot reach the wire.
pub fn sorted_roster(entries: Vec<RosterEntry>) -> Res<Vec<RosterEntry>> {
    if entries.len() != COMMITTEE_VALIDATORS {
        return Err(bad(format!("the committee needs exactly {COMMITTEE_VALIDATORS} keys, the roster gives {}", entries.len())));
    }
    let mut keyed = Vec::with_capacity(entries.len());
    for e in entries {
        let bytes = hex::decode(&e.public_key).map_err(|_| bad("a roster public key is not hex"))?;
        if e.pop.len() != BLS_POP_BYTES {
            return Err(bad(format!("a PoP has {} bytes, expected {BLS_POP_BYTES}", e.pop.len())));
        }
        keyed.push((bytes, e));
    }
    keyed.sort_by(|a, b| a.0.cmp(&b.0));
    if keyed.windows(2).any(|w| w[0].0 == w[1].0) {
        return Err(bad("the roster repeats a public key"));
    }
    Ok(keyed.into_iter().map(|(_, e)| e).collect())
}

/// Accept `hash:HEX#CRC`, `HEX#N` or bare HEX; return bare HEX.
pub fn hash_hex(s: &str) -> Res<String> {
    let t = s.trim();
    let t = t.strip_prefix("hash:").unwrap_or(t);
    let t = t.split('#').next().unwrap_or(t);
    if t.len() != 64 || !t.bytes().all(|b| b.is_ascii_hexdigit()) {
        return Err(bad("a lane incarnation is not a 64-digit hash"));
    }
    Ok(t.to_owned())
}

/// Resolve a dataspace to its single lane and that lane's incarnation.
pub fn parse_lifecycle(raw: &str, dataspace: u64) -> Res<LaneRoute> {
    let v: Value = serde_json::from_str(raw).map_err(|e| bad(format!("lifecycle is not JSON: {e}")))?;
    let lanes = v.get("lanes").and_then(Value::as_array).ok_or_else(|| bad("lifecycle has no `lanes` array"))?;
    let ids: Vec<u64> = lanes
        .iter()
        .filter(|l| l.get("dataspace_id").and_then(u64_of) == Some(dataspace))
        .filter_map(|l| l.get("id").or_else(|| l.get("lane_id")).and_then(u64_of))
        .collect();
    let lane = match ids.as_slice() {
        [one] => *one,
        [] => return Err(bad(format!("lifecycle has no lane for dataspace {dataspace}"))),
        _ => return Err(bad(format!("lifecycle has several lanes for dataspace {dataspace}"))),
    };
    let incs = v.get("incarnations").and_then(Value::as_array).ok_or_else(|| bad("lifecycle has no `incarnations` array"))?;
    let inc = incs
        .iter()
        .find(|i| i.get("lane_id").and_then(u64_of) == Some(lane))
        .and_then(|i| i.get("incarnation"))
        .and_then(Value::as_str)
        .ok_or_else(|| bad(format!("lifecycle has no incarnation for lane {lane}")))?;
    Ok(LaneRoute {
        dataspace_id: dataspace,
        lane_id: u32::try_from(lane).map_err(|_| bad("lane id does not fit u32"))?,
        incarnation: hash_hex(inc)?,
    })
}

pub fn parse_auditor_public(raw: &str) -> Res<AuditorPublic> {
    let v: Value = serde_json::from_str(raw).map_err(|e| bad(format!("auditor public key is not JSON: {e}")))?;
    let field = |k: &str| v.get(k).and_then(Value::as_str).ok_or_else(|| bad(format!("auditor public key lacks `{k}`")));
    let x25519: [u8; 32] = hex::decode(strip_0x(field("x25519_hex")?))
        .ok()
        .and_then(|b| b.try_into().ok())
        .ok_or_else(|| bad("x25519_hex must be 32 bytes of hex"))?;
    let ml_kem_768 = hex::decode(strip_0x(field("ml_kem_768_hex")?)).map_err(|_| bad("ml_kem_768_hex is not hex"))?;
    if ml_kem_768.len() != ML_KEM_768_PUBLIC_KEY_BYTES {
        return Err(bad(format!("ml_kem_768_hex must be {ML_KEM_768_PUBLIC_KEY_BYTES} bytes")));
    }
    Ok(AuditorPublic { signing_public_key: field("signing_public_key")?.to_owned(), x25519, ml_kem_768 })
}

/// 32 nonzero-in-practice bytes for one named field of one run (SHA-256 over domain, label, salt).
pub fn derived(salt: &[u8; 32], label: &str) -> [u8; 32] {
    let mut h = Sha256::new();
    h.update(b"rd-dfabi/probe/v1\0");
    h.update(label.as_bytes());
    h.update(salt);
    h.finalize().into()
}

/// The command to run, with placeholders. Stdout carries the material, so the redirect target is the --material file.
pub fn command_line() -> String {
    "iroha --config <SIGNER_CONFIG> app nexus private-settlement availability-share \
     --endpoint <BI_TORII_URL> --material <MATERIAL_JSON>"
        .to_owned()
}

/// The verdict table, printed under the command so the operator does not need the design doc.
pub fn verdicts() -> &'static str {
    "# signer must be the sponsor account whose public key was given to --sponsor-public-key\n\
     # 200 disposition Stored/AlreadyStored: PASS (committee keys accepted)\n\
     # 400 private_settlement_invalid_request: FAIL, but also what a wrong padding class, retention, expiry span, network id or context height returns\n\
     # 403 private_settlement_sponsor_required: signer is not the sponsor\n\
     # 404: APS unavailable on that node"
}

/// Top level keys of PrivateSettlementProvisionalLegMaterialV1 (deny_unknown_fields, so exact).
const MATERIAL_KEYS: [&str; 9] = [
    "version",
    "manifest",
    "audit_policy",
    "committee_authority",
    "statement",
    "proof",
    "delta",
    "audit_capsule",
    "availability_body",
];

/// Cheap guard on the serialised material: exactly the nine fields, nothing else.
pub fn check_material_shape(json: &str) -> Res<()> {
    let v: Value = serde_json::from_str(json).map_err(|e| err("internal", format!("material is not JSON: {e}"), false))?;
    let obj = v.as_object().ok_or_else(|| err("internal", "material is not a JSON object", false))?;
    let mut keys: Vec<&str> = obj.keys().map(String::as_str).collect();
    keys.sort_unstable();
    let mut want = MATERIAL_KEYS.to_vec();
    want.sort_unstable();
    if keys != want {
        return Err(err("internal", format!("material fields are {keys:?}, expected {want:?}"), false));
    }
    Ok(())
}

fn read(path: &Path, what: &str) -> Res<String> {
    std::fs::read_to_string(path).map_err(|e| bad(format!("read {what} {}: {e}", path.display())))
}

/// Parse every input file. `salt` is injected so tests stay deterministic.
pub fn plan_from_args(a: &AvailabilityShareArgs, salt: [u8; 32]) -> Res<Plan> {
    let network_id = match (&a.network_id, &a.network_id_file) {
        (Some(s), None) => s.trim().to_owned(),
        (None, Some(p)) => read(p, "network id")?.trim().to_owned(),
        _ => return Err(bad("give exactly one of --network-id and --network-id-file")),
    };
    let lifecycle = read(&a.lifecycle, "lifecycle")?;
    if a.dataspace == a.other_dataspace {
        return Err(bad("--dataspace and --other-dataspace must differ"));
    }
    let tested = parse_lifecycle(&lifecycle, a.dataspace)?;
    let other = parse_lifecycle(&lifecycle, a.other_dataspace)?;
    // The manifest orders legs by route (dataspace id first), so the tested leg is leg 0 only if its dataspace is lower.
    if tested.dataspace_id > other.dataspace_id {
        return Err(bad("--dataspace must be lower than --other-dataspace (legs are ordered by dataspace id)"));
    }
    if a.expiry_blocks == 0 {
        return Err(bad("--expiry-blocks must be positive"));
    }
    let auditor = a.auditor_public.as_deref().map(|p| parse_auditor_public(&read(p, "auditor public key")?)).transpose()?;
    Ok(Plan {
        network_id,
        sponsor_public_key: a.sponsor_public_key.trim().to_owned(),
        context_height: a.context_height,
        expiry_blocks: a.expiry_blocks,
        retention_blocks: a.retention_blocks,
        roster: sorted_roster(parse_roster(&read(&a.roster, "roster")?, a.context_height)?)?,
        tested,
        other,
        auditor,
        chain_discriminant: a.chain_discriminant,
        salt,
    })
}

#[cfg(feature = "aps")]
fn build(plan: &Plan) -> Res<String> {
    crate::aps::availability_share_material(plan)
}

#[cfg(not(feature = "aps"))]
fn build(_: &Plan) -> Res<String> {
    Err(err("aps_not_built", "the sealed audit capsule needs the iroha crypto: build rd-dfabi with --features aps", false))
}

/// Material JSON for stdout; the command and verdicts go to stderr.
pub fn run(a: &AvailabilityShareArgs) -> Res<String> {
    let salt = crate::store::random32().map_err(|m| err("internal", m, false))?;
    let plan = plan_from_args(a, salt)?;
    let material = build(&plan)?;
    check_material_shape(&material)?;
    eprintln!("{}\n{}", command_line(), verdicts());
    Ok(material)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Synthetic multihash-looking key: fixed prefix plus 48 bytes derived from the label. Not a real key.
    fn fake_key(label: &str) -> String {
        let a = derived(&[7; 32], label);
        let b = derived(&[8; 32], label);
        format!("ea0130{}{}", hex::encode_upper(a), hex::encode_upper(&b[..16]))
    }

    fn fake_pop(label: &str) -> Vec<u8> {
        let mut v = derived(&[1; 32], label).to_vec();
        v.extend(derived(&[2; 32], label));
        v.extend(derived(&[3; 32], label));
        v
    }

    fn peers_json(labels: &[&str]) -> String {
        let rows: Vec<Value> = labels
            .iter()
            .map(|l| serde_json::json!({"party": l, "public_key": fake_key(l), "pop_hex": format!("0x{}", hex::encode(fake_pop(l)))}))
            .collect();
        serde_json::to_string(&rows).unwrap()
    }

    #[test]
    fn peers_file_parses_and_sorts_by_key_bytes() {
        let raw = peers_json(&["p1", "p2", "p3", "p4"]);
        let sorted = sorted_roster(parse_roster(&raw, 10).unwrap()).unwrap();
        assert_eq!(sorted.len(), 4);
        let keys: Vec<Vec<u8>> = sorted.iter().map(|e| hex::decode(&e.public_key).unwrap()).collect();
        assert!(keys.windows(2).all(|w| w[0] < w[1]), "ascending key bytes");
        // PoP stays attached to its own key after the sort.
        for e in &sorted {
            let label = ["p1", "p2", "p3", "p4"].into_iter().find(|l| fake_key(l) == e.public_key).unwrap();
            assert_eq!(e.pop, fake_pop(label));
        }
        // Input order does not matter.
        let reversed = peers_json(&["p4", "p3", "p2", "p1"]);
        assert_eq!(sorted_roster(parse_roster(&reversed, 10).unwrap()).unwrap(), sorted);
    }

    #[test]
    fn roster_rejects_wrong_count_duplicates_and_short_pop() {
        let three = parse_roster(&peers_json(&["a", "b", "c"]), 1).unwrap();
        assert!(sorted_roster(three).unwrap_err().message.contains("exactly 4"));
        let mut dup = parse_roster(&peers_json(&["a", "b", "c", "d"]), 1).unwrap();
        dup[3] = dup[0].clone();
        assert!(sorted_roster(dup).unwrap_err().message.contains("repeats"));
        let mut short = parse_roster(&peers_json(&["a", "b", "c", "d"]), 1).unwrap();
        short[0].pop.truncate(95);
        assert!(sorted_roster(short).unwrap_err().message.contains("95"));
        assert_eq!(parse_roster("{}", 1).unwrap_err().code, "bad_request");
    }

    #[test]
    fn consensus_dump_keeps_live_committee_records_only() {
        let rec = |role: &str, label: &str, act: u64, status: &str, pop: Value| {
            serde_json::json!({
                "id": {"role": role, "name": format!("k-{label}")},
                "public_key": fake_key(label), "pop": pop, "activation_height": act, "status": status
            })
        };
        let pop_arr = |l: &str| Value::from(fake_pop(l).iter().map(|b| u64::from(*b)).collect::<Vec<_>>());
        let pop_hex = |l: &str| Value::from(hex::encode(fake_pop(l)));
        let rows = serde_json::json!([
            rec("Validator", "v1", 1, "Active", pop_arr("v1")),
            rec("Committee", "c1", 1, "Active", pop_arr("c1")),
            rec("Committee", "c2", 1, "Active", pop_hex("c2")),
            rec("Committee", "c3", 1, "Active", pop_arr("c3")),
            rec("Committee", "c4", 1, "Active", pop_arr("c4")),
            rec("Committee", "c5", 50, "Active", pop_arr("c5")),
            rec("Committee", "c6", 1, "Disabled", pop_arr("c6")),
        ])
        .to_string();
        let got = parse_roster(&rows, 10).unwrap();
        let labels: Vec<_> = got.iter().map(|e| e.public_key.clone()).collect();
        assert_eq!(labels, ["c1", "c2", "c3", "c4"].map(fake_key));
        assert!(sorted_roster(got).is_ok());
        // From height 50 the fifth key is live too, so the count is wrong and the caller is told.
        assert_eq!(parse_roster(&rows, 50).unwrap().len(), 5);
    }

    #[test]
    fn lifecycle_resolves_dataspace_lane_and_incarnation() {
        let inc = |s: &str| hex::encode_upper(derived(&[9; 32], s));
        let raw = serde_json::json!({
            "version": 1, "lane_count": 3,
            "lanes": [
                {"id": 0, "dataspace_id": 0, "alias": "universal"},
                {"id": 1, "dataspace_id": 1, "alias": "ds-rd"},
                {"id": "2", "dataspace_id": "2", "alias": "ds-dfabi"}
            ],
            "incarnations": [
                {"lane_id": 0, "incarnation": inc("l0")},
                {"lane_id": 1, "incarnation": format!("hash:{}#ABCD", inc("l1"))},
                {"lane_id": 2, "incarnation": inc("l2")}
            ]
        })
        .to_string();
        assert_eq!(parse_lifecycle(&raw, 1).unwrap(), LaneRoute { dataspace_id: 1, lane_id: 1, incarnation: inc("l1") });
        assert_eq!(parse_lifecycle(&raw, 2).unwrap().lane_id, 2);
        assert!(parse_lifecycle(&raw, 7).unwrap_err().message.contains("no lane"));
        assert!(parse_lifecycle("[]", 1).is_err());
        assert!(hash_hex("12345").is_err());
    }

    #[test]
    fn auditor_public_checks_lengths() {
        let ok = serde_json::json!({
            "signing_public_key": fake_key("aud"),
            "x25519_hex": hex::encode([5u8; 32]),
            "ml_kem_768_hex": hex::encode(vec![6u8; ML_KEM_768_PUBLIC_KEY_BYTES]),
        })
        .to_string();
        let a = parse_auditor_public(&ok).unwrap();
        assert_eq!((a.x25519, a.ml_kem_768.len()), ([5; 32], 1184));
        assert!(parse_auditor_public(&ok.replace(&hex::encode([5u8; 32]), "00")).is_err());
        assert!(parse_auditor_public("{}").is_err());
    }

    #[test]
    fn derived_fields_are_distinct_per_label_and_per_salt() {
        let s = [3u8; 32];
        let labels = ["pool0", "pool1", "asset0", "asset1", "root-old", "root-new", "nf0", "nf1", "cm0", "cm1", "cm2"];
        let set: std::collections::BTreeSet<_> = labels.iter().map(|l| derived(&s, l)).collect();
        assert_eq!(set.len(), labels.len());
        assert_ne!(derived(&s, "pool0"), derived(&[4u8; 32], "pool0"));
        assert!(set.iter().all(|d| d.iter().any(|b| *b != 0)));
    }

    #[test]
    fn material_shape_guard_wants_exactly_the_nine_fields() {
        let ok: serde_json::Map<String, Value> = MATERIAL_KEYS.iter().map(|k| ((*k).to_owned(), Value::Null)).collect();
        assert!(check_material_shape(&Value::Object(ok.clone()).to_string()).is_ok());
        let mut extra = ok.clone();
        extra.insert("surplus".into(), Value::Null);
        assert!(check_material_shape(&Value::Object(extra).to_string()).is_err());
        let mut missing = ok;
        missing.remove("proof");
        assert!(check_material_shape(&Value::Object(missing).to_string()).is_err());
        assert!(check_material_shape("[]").is_err());
    }

    #[test]
    fn command_line_has_placeholders_and_no_environment() {
        let c = command_line();
        for p in ["<SIGNER_CONFIG>", "<BI_TORII_URL>", "<MATERIAL_JSON>", "availability-share"] {
            assert!(c.contains(p), "{p}");
        }
        assert!(verdicts().contains("Stored/AlreadyStored"));
    }

    #[test]
    fn plan_from_files_orders_legs_and_demands_one_network_id_source() {
        let dir = std::env::temp_dir().join(format!("rd-dfabi-probe-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let inc = |s: &str| hex::encode_upper(derived(&[9; 32], s));
        std::fs::write(dir.join("peers.json"), peers_json(&["p1", "p2", "p3", "p4"])).unwrap();
        std::fs::write(
            dir.join("lifecycle.json"),
            serde_json::json!({
                "lanes": [{"id": 1, "dataspace_id": 1}, {"id": 2, "dataspace_id": 2}],
                "incarnations": [{"lane_id": 1, "incarnation": inc("a")}, {"lane_id": 2, "incarnation": inc("b")}]
            })
            .to_string(),
        )
        .unwrap();
        let mut a = AvailabilityShareArgs {
            roster: dir.join("peers.json"),
            lifecycle: dir.join("lifecycle.json"),
            network_id: Some("hash:SYNTHETIC".into()),
            network_id_file: None,
            sponsor_public_key: fake_key("sponsor"),
            context_height: 20,
            dataspace: 1,
            other_dataspace: 2,
            expiry_blocks: 7000,
            retention_blocks: 1_100_000,
            auditor_public: None,
            chain_discriminant: None,
        };
        let p = plan_from_args(&a, [1; 32]).unwrap();
        assert_eq!((p.tested.lane_id, p.other.lane_id, p.roster.len()), (1, 2, 4));
        a.network_id = None;
        assert!(plan_from_args(&a, [1; 32]).is_err());
        a.network_id = Some("x".into());
        (a.dataspace, a.other_dataspace) = (2, 1);
        assert!(plan_from_args(&a, [1; 32]).unwrap_err().message.contains("lower"));
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[cfg(not(feature = "aps"))]
    #[test]
    fn light_build_says_aps_is_needed() {
        let plan = Plan {
            network_id: String::new(),
            sponsor_public_key: String::new(),
            context_height: 1,
            expiry_blocks: 1,
            retention_blocks: 1,
            roster: vec![],
            tested: LaneRoute { dataspace_id: 1, lane_id: 1, incarnation: String::new() },
            other: LaneRoute { dataspace_id: 2, lane_id: 2, incarnation: String::new() },
            auditor: None,
            chain_discriminant: None,
            salt: [0; 32],
        };
        assert_eq!(build(&plan).unwrap_err().code, "aps_not_built");
    }
}
