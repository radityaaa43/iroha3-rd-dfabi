//! `decode` feature: request body -> [`TxView`]. Uses iroha_data_model + norito only (no iroha_core, no `aps`).
//!
//! The decode is the one Torii runs on the tx route: `SignedTransaction::decode_all_versioned`
//! (iroha_data_model transaction/signed.rs:1999). It also re-encodes the tx and rejects any input that is not byte-identical
//! to its canonical form, so trailing bytes and non-canonical framing cannot differ between this decoder and Torii.
//! JSON mirrors Torii's `decode_versioned_json`: `{"version":1,"content":<SignedTransaction>}`, no other envelope key.

use std::panic::{AssertUnwindSafe, catch_unwind};

use iroha_data_model::{
    asset::AssetBalanceScope,
    isi::{
        BurnBox, GrantBox, Instruction, InstructionBox, MintBox, RegisterBox, SetKeyValueBox, TransferBox, instruction_wire_id,
        settlement::{DvpIsi, SettlementInstructionBox, SettlementLeg},
    },
    transaction::{Executable, ExecutableBatchItem, FeePaymentIntent, SignedTransaction, TransactionAdmissionIntent, TransactionDomain},
};
use iroha_version::codec::DecodeVersioned;

use crate::txview::{Consent, DecodeErr, Dvp, Format, Grant, Instr, Leg, Movement, TxView};

pub fn decode(body: &[u8], format: Format) -> Result<TxView, DecodeErr> {
    // A panic inside a decoder must fail closed, not kill the server thread silently.
    catch_unwind(AssertUnwindSafe(|| decode_inner(body, format)))
        .unwrap_or_else(|_| Err(DecodeErr::new("decode_failed", "decoder panicked")))
}

fn decode_inner(body: &[u8], format: Format) -> Result<TxView, DecodeErr> {
    let tx = match format {
        Format::Norito => SignedTransaction::decode_all_versioned(body).map_err(|e| {
            let m = e.to_string();
            let l = m.to_ascii_lowercase();
            let code = if l.contains("canonical") || l.contains("trailing") || l.contains("length") { "non_canonical" } else { "decode_failed" };
            DecodeErr::new(code, m)
        })?,
        Format::Json => decode_json(body)?,
    };
    Ok(view(&tx, format))
}

fn decode_json(body: &[u8]) -> Result<SignedTransaction, DecodeErr> {
    use iroha_version::Version;
    use norito::json::Value;
    let bad = |m: String| DecodeErr::new("decode_failed", m);
    let value = norito::json::from_slice::<Value>(body).map_err(|e| bad(format!("invalid JSON body: {e}")))?;
    let object = value.as_object().ok_or_else(|| bad("JSON body is not a versioned object".into()))?;
    if let Some(k) = object.keys().find(|k| !matches!(k.as_str(), "version" | "content")) {
        return Err(bad(format!("unknown envelope field `{k}`")));
    }
    // Same rule as Torii's `version_from_json_value`: a JSON number that fits u8.
    let version = match object.get("version") {
        Some(Value::Number(n)) => n.as_u64().and_then(|v| u8::try_from(v).ok()),
        _ => None,
    };
    if !version.is_some_and(|v| SignedTransaction::supported_versions().contains(&v)) {
        return Err(bad("missing or unsupported version".into()));
    }
    let content = object.get("content").ok_or_else(|| bad("missing `content`".into()))?;
    norito::json::from_value::<SignedTransaction>(content.clone()).map_err(|e| bad(format!("invalid SignedTransaction JSON: {e}")))
}

fn view(tx: &SignedTransaction, format: Format) -> TxView {
    let p = tx.payload();
    let (executable, instructions) = match tx.instructions() {
        Executable::Instructions(list) => ("instructions", list.iter().map(instr).collect()),
        Executable::Batch(items) => (
            "batch",
            items
                .iter()
                .map(|i| match i {
                    ExecutableBatchItem::Instruction(b) => instr(b),
                    ExecutableBatchItem::ContractCall(_) => Instr::Unknown { raw_kind: "contract_call".into() },
                })
                .collect(),
        ),
        Executable::ContractCall(_) => ("contract_call", vec![]),
        Executable::Ivm(_) => ("ivm", vec![]),
        Executable::IvmProved(_) => ("ivm_proved", vec![]),
    };
    TxView {
        ok: true,
        encoding: match format {
            Format::Norito => "norito",
            Format::Json => "json",
        }
        .into(),
        tx_hash: {
            let h = tx.hash();
            let raw: &[u8; 32] = h.as_ref();
            hex::encode(raw)
        },
        signature_ok: tx.verify_signature().is_ok(),
        authority: tx.authority().to_string(),
        chain_id: match tx.domain() {
            TransactionDomain::Network(n) => n.to_string(),
            TransactionDomain::Genesis => "genesis".into(),
        },
        creation_time_ms: p.creation_time_ms,
        time_to_live_ms: p.time_to_live_ms.map(|v| v.get()),
        nonce: tx.nonce().map(|v| v.get()),
        admission_intent: match tx.admission_intent() {
            TransactionAdmissionIntent::Ordinary => "ordinary",
            TransactionAdmissionIntent::QueuePlanSynced => "queue_plan_synced",
        }
        .into(),
        fee_payer: match tx.fee_payment_intent() {
            FeePaymentIntent::Authority(_) => "authority",
            FeePaymentIntent::Sponsor(_) => "sponsor",
        }
        .into(),
        executable: executable.into(),
        has_attachments: tx.attachments().is_some(),
        has_multisig: tx.multisig_signatures().is_some(),
        instructions,
    }
}

fn scope(s: &AssetBalanceScope) -> (String, Option<u64>) {
    match s {
        AssetBalanceScope::Global => ("global".into(), None),
        AssetBalanceScope::Dataspace(d) => (format!("dataspace:{}", d.as_u64()), Some(d.as_u64())),
    }
}

fn instr(b: &InstructionBox) -> Instr {
    let any = b.as_any();
    let unknown = |sub: &str| {
        let wire = instruction_wire_id(b).unwrap_or("unregistered");
        Instr::Unknown { raw_kind: if sub.is_empty() { wire.into() } else { format!("{wire}.{sub}") } }
    };
    if let Some(m) = any.downcast_ref::<MintBox>() {
        return match m {
            MintBox::Asset(x) => {
                let (scope, dataspace) = scope(x.destination.scope());
                Instr::Mint(Movement {
                    asset_definition: x.destination.definition().to_string(),
                    quantity: x.object.to_string(),
                    scale: x.object.scale(),
                    from: None,
                    to: Some(x.destination.account().to_string()),
                    scope,
                    dataspace,
                })
            }
            _ => unknown("trigger_repetitions"),
        };
    }
    if let Some(m) = any.downcast_ref::<BurnBox>() {
        return match m {
            BurnBox::Asset(x) => {
                let (scope, dataspace) = scope(x.destination.scope());
                Instr::Burn(Movement {
                    asset_definition: x.destination.definition().to_string(),
                    quantity: x.object.to_string(),
                    scale: x.object.scale(),
                    from: Some(x.destination.account().to_string()),
                    to: None,
                    scope,
                    dataspace,
                })
            }
            _ => unknown("trigger_repetitions"),
        };
    }
    if let Some(m) = any.downcast_ref::<TransferBox>() {
        return match m {
            TransferBox::Asset(x) => {
                let (scope, dataspace) = scope(x.source.scope());
                Instr::Transfer(Movement {
                    asset_definition: x.source.definition().to_string(),
                    quantity: x.object.to_string(),
                    scale: x.object.scale(),
                    from: Some(x.source.account().to_string()),
                    to: Some(x.destination.to_string()),
                    scope,
                    dataspace,
                })
            }
            TransferBox::Domain(_) => unknown("domain"),
            TransferBox::AssetDefinition(_) => unknown("asset_definition"),
            TransferBox::Nft(_) => unknown("nft"),
        };
    }
    if let Some(d) = any.downcast_ref::<DvpIsi>() {
        return dvp(d);
    }
    if let Some(m) = any.downcast_ref::<SettlementInstructionBox>() {
        return match m {
            SettlementInstructionBox::Dvp(d) => dvp(d),
            SettlementInstructionBox::Pvp(_) => unknown("pvp"),
            _ => unknown(""),
        };
    }
    if let Some(m) = any.downcast_ref::<GrantBox>() {
        return Instr::Grant(match m {
            GrantBox::Permission(g) => {
                let payload = serde_json::from_str::<serde_json::Value>(g.object.payload().get()).ok();
                let consent = (g.object.name() == "CanExecuteSettlement")
                    .then(|| payload.as_ref().and_then(consent))
                    .flatten();
                Grant {
                    grant_kind: "permission".into(),
                    permission: Some(g.object.name().to_string()),
                    payload,
                    to: g.destination.to_string(),
                    consent,
                }
            }
            GrantBox::Role(g) => Grant { grant_kind: "role".into(), permission: None, payload: None, to: g.destination.to_string(), consent: None },
            GrantBox::RolePermission(g) => Grant {
                grant_kind: "role_permission".into(),
                permission: Some(g.object.name().to_string()),
                payload: serde_json::from_str(g.object.payload().get()).ok(),
                to: format!("{:?}", g.destination),
                consent: None,
            },
        });
    }
    if let Some(m) = any.downcast_ref::<RegisterBox>() {
        return Instr::Register {
            object: match m {
                RegisterBox::Peer(_) => "peer",
                RegisterBox::Domain(_) => "domain",
                RegisterBox::Account(_) => "account",
                RegisterBox::AssetDefinition(_) => "asset_definition",
                RegisterBox::Nft(_) => "nft",
                RegisterBox::Role(_) => "role",
                RegisterBox::Trigger(_) => "trigger",
                #[allow(unreachable_patterns)]
                _ => "other",
            }
            .into(),
        };
    }
    if let Some(m) = any.downcast_ref::<SetKeyValueBox>() {
        return Instr::SetKeyValue {
            target: match m {
                SetKeyValueBox::Domain(_) => "domain",
                SetKeyValueBox::Account(_) => "account",
                SetKeyValueBox::AssetDefinition(_) => "asset_definition",
                SetKeyValueBox::Nft(_) => "nft",
                SetKeyValueBox::Trigger(_) => "trigger",
            }
            .into(),
        };
    }
    unknown("")
}

/// DeliveryThenPayment -> delivery_then_payment
fn snake(s: &str) -> String {
    let mut out = String::new();
    for (i, c) in s.chars().enumerate() {
        if c.is_ascii_uppercase() && i > 0 {
            out.push('_');
        }
        out.push(c.to_ascii_lowercase());
    }
    out
}

fn dvp(d: &DvpIsi) -> Instr {
    let leg = |l: &SettlementLeg| Leg {
        asset_definition: l.asset_definition_id.to_string(),
        quantity: l.quantity.to_string(),
        scale: l.quantity.scale(),
        from: l.from.to_string(),
        to: l.to.to_string(),
    };
    Instr::Dvp(Dvp {
        settlement_id: d.settlement_id.name.to_string(),
        delivery: leg(&d.delivery_leg),
        payment: leg(&d.payment_leg),
        order: snake(&format!("{:?}", d.plan.order())),
        atomicity: snake(&format!("{:?}", d.plan.atomicity())),
        intent_hash: d.intent_hash().to_string(),
    })
}

/// `{"debited_asset":..,"intent_hash":..,"settlement_id":..}`, all strings; anything else is not a consent (None).
fn consent(v: &serde_json::Value) -> Option<Consent> {
    let s = |k: &str| v.get(k)?.as_str().map(str::to_string);
    Some(Consent { debited_asset: s("debited_asset")?, intent_hash: s("intent_hash")?, settlement_id: s("settlement_id")? })
}


// Feature tests: synthetic keys and ids only, nothing from the live chain. The golden tests decode real captured request
// bodies from the directory in $RD_DFABI_TXCAP_DIR (files `NNN-*.body`, plus `dvp-intent.txt` and `dvp-sid.txt`) and are
// skipped when it is unset: the captures hold real account ids and stay out of git.
#[cfg(test)]
mod tests {
    use std::io::{Read, Write};

    use base64::Engine;
    use iroha_crypto::{Algorithm, Hash, HashOf, KeyPair};
    use iroha_data_model::{
        account::AccountId,
        asset::{AssetBalanceScope, AssetDefinitionId, AssetId},
        block::BlockHeader,
        id::NetworkId,
        isi::{
            Burn, Grant, Mint, Transfer,
            settlement::{DvpIsi, SettlementId, SettlementLeg, SettlementPlan},
        },
        permission::Permission,
        prelude::{Json, Level, Log},
        transaction::{FeePaymentIntent, TransactionBuilder},
    };
    use iroha_model_base::DataSpaceId;
    use iroha_version::codec::EncodeVersioned;

    use super::*;

    fn keys(seed: u8) -> KeyPair {
        KeyPair::try_from_seed(vec![seed; 32], Algorithm::Ed25519).unwrap()
    }
    fn acct(seed: u8) -> AccountId {
        AccountId::new(keys(seed).public_key().clone())
    }
    fn def(n: u8) -> AssetDefinitionId {
        AssetDefinitionId::from_uuid_bytes([n, 0, 0, 0, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, 0, 1]).unwrap()
    }
    fn asset(n: u8, owner: u8, ds: Option<u64>) -> AssetId {
        let scope = ds.map_or(AssetBalanceScope::Global, |d| AssetBalanceScope::Dataspace(DataSpaceId::new(d)));
        AssetId::with_scope(def(n), acct(owner), scope)
    }
    fn tx(signer: u8, instructions: Vec<InstructionBox>) -> SignedTransaction {
        let net = NetworkId::from_genesis_hash(HashOf::<BlockHeader>::from_untyped_unchecked(Hash::prehashed([7; Hash::LENGTH])));
        TransactionBuilder::new(net, acct(signer), FeePaymentIntent::authority(Vec::new(), None))
            .with_instructions(instructions)
            .sign(keys(signer).private_key())
    }
    fn norito(t: &SignedTransaction) -> Vec<u8> {
        t.encode_versioned()
    }
    fn ok(bytes: &[u8]) -> TxView {
        decode(bytes, Format::Norito).unwrap_or_else(|e| panic!("{e:?}"))
    }
    fn dvp_isi() -> DvpIsi {
        DvpIsi::new(
            SettlementId::new("dvp_test_1".parse().unwrap()),
            SettlementLeg::new(def(2), 5u32, acct(1), acct(2)),
            SettlementLeg::new(def(1), 50u32, acct(2), acct(1)),
            SettlementPlan::default(),
        )
    }

    #[test]
    fn mint_with_dataspace_scope() {
        let m = Mint::asset_quantity(100u32, asset(1, 2, Some(1)));
        let v = ok(&norito(&tx(1, vec![m.into()])));
        assert_eq!((v.encoding.as_str(), v.executable.as_str(), v.signature_ok), ("norito", "instructions", true));
        assert_eq!(v.authority, acct(1).to_string());
        assert_eq!((v.fee_payer.as_str(), v.admission_intent.as_str()), ("authority", "ordinary"));
        assert!(v.chain_id.starts_with("hash:"), "{}", v.chain_id);
        assert!(v.creation_time_ms > 0 && v.tx_hash.len() == 64);
        match v.instructions.as_slice() {
            [Instr::Mint(m)] => {
                assert_eq!((m.quantity.as_str(), m.scale, m.scope.as_str(), m.dataspace), ("100", 0, "dataspace:1", Some(1)));
                assert_eq!(m.asset_definition, def(1).to_string());
                assert_eq!((m.from.as_deref(), m.to.as_deref()), (None, Some(acct(2).to_string().as_str())));
            }
            other => panic!("{other:?}"),
        }
    }

    #[test]
    fn transfer_in_dataspace_1_and_burn_global() {
        let t = Transfer::asset_quantity(asset(2, 1, Some(1)), 7u32, acct(3));
        let b = Burn::asset_quantity(9u32, asset(2, 1, None));
        let v = ok(&norito(&tx(1, vec![t.into(), b.into()])));
        match v.instructions.as_slice() {
            [Instr::Transfer(t), Instr::Burn(b)] => {
                assert_eq!((t.quantity.as_str(), t.scope.as_str(), t.dataspace), ("7", "dataspace:1", Some(1)));
                assert_eq!(t.asset_definition, def(2).to_string());
                assert_eq!((t.from.as_deref(), t.to.as_deref()), (Some(acct(1).to_string().as_str()), Some(acct(3).to_string().as_str())));
                assert_eq!((b.quantity.as_str(), b.scope.as_str(), b.dataspace), ("9", "global", None));
                assert_eq!((b.from.as_deref(), b.to), (Some(acct(1).to_string().as_str()), None));
            }
            other => panic!("{other:?}"),
        }
    }

    #[test]
    fn dvp_legs_intent_hash_and_consent() {
        let d = dvp_isi();
        let consent = Json::from_str_norito(&format!(
            r#"{{"debited_asset":"{}#{}#dataspace:1","intent_hash":"{}","settlement_id":"dvp_test_1"}}"#,
            def(1),
            acct(2),
            d.intent_hash()
        ))
        .unwrap();
        let g = Grant::account_permission(Permission::new("CanExecuteSettlement".to_string(), consent), acct(1));
        let v = ok(&norito(&tx(2, vec![g.into()])));
        let [Instr::Grant(g)] = v.instructions.as_slice() else { panic!("{:?}", v.instructions) };
        assert_eq!((g.grant_kind.as_str(), g.permission.as_deref()), ("permission", Some("CanExecuteSettlement")));
        assert_eq!(g.to, acct(1).to_string());
        let c = g.consent.as_ref().expect("consent");
        assert_eq!((c.intent_hash.as_str(), c.settlement_id.as_str()), (d.intent_hash().to_string().as_str(), "dvp_test_1"));

        let v = ok(&norito(&tx(1, vec![d.clone().into()])));
        let [Instr::Dvp(x)] = v.instructions.as_slice() else { panic!("{:?}", v.instructions) };
        assert_eq!(x.intent_hash, d.intent_hash().to_string());
        assert_eq!((x.settlement_id.as_str(), x.order.as_str(), x.atomicity.as_str()), ("dvp_test_1", "delivery_then_payment", "all_or_nothing"));
        assert_eq!((x.delivery.quantity.as_str(), x.delivery.asset_definition.clone()), ("5", def(2).to_string()));
        assert_eq!((x.delivery.from.clone(), x.delivery.to.clone()), (acct(1).to_string(), acct(2).to_string()));
        assert_eq!((x.payment.quantity.as_str(), x.payment.from.clone(), x.payment.to.clone()), ("50", acct(2).to_string(), acct(1).to_string()));
    }

    #[test]
    fn other_instruction_is_unknown_with_raw_kind() {
        let v = ok(&norito(&tx(1, vec![Log { level: Level::INFO, msg: "x".into() }.into()])));
        match v.instructions.as_slice() {
            [Instr::Unknown { raw_kind }] => assert!(!raw_kind.is_empty(), "{raw_kind}"),
            other => panic!("{other:?}"),
        }
    }

    #[test]
    fn trailing_and_truncated_bytes_are_rejected() {
        let good = norito(&tx(1, vec![Mint::asset_quantity(1u32, asset(1, 2, None)).into()]));
        for bad in [[good.clone(), vec![0]].concat(), good[..good.len() - 1].to_vec(), vec![], vec![1, 2, 3]] {
            let e = decode(&bad, Format::Norito).unwrap_err();
            assert!(!e.ok && matches!(e.error.code.as_str(), "non_canonical" | "decode_failed"), "{e:?}");
        }
    }

    #[test]
    fn json_body_decodes_to_the_same_view_as_norito() {
        let t = tx(1, vec![Mint::asset_quantity(3u32, asset(1, 2, Some(1))).into()]);
        let body = format!(r#"{{"version":1,"content":{}}}"#, norito::json::to_string(&t).unwrap());
        let j = decode(body.as_bytes(), Format::Json).unwrap_or_else(|e| panic!("{e:?}"));
        let n = ok(&norito(&t));
        assert_eq!(j.encoding, "json");
        assert_eq!(
            (j.tx_hash, serde_json::to_value(&j.instructions).unwrap()),
            (n.tx_hash, serde_json::to_value(&n.instructions).unwrap())
        );
        for bad in [br#"{"version":1,"content":{},"x":1}"#.as_slice(), br#"{"version":9,"content":{}}"#, br#"{"version":"1","content":{}}"#, b"[]", b"not json"] {
            assert!(decode(bad, Format::Json).is_err());
        }
    }

    /// POST /decode through the real server: the raw body and the OPA `http.send` shape give the same answer.
    fn post(ct: &str, body: &[u8]) -> (u16, String) {
        let l = std::net::TcpListener::bind(("localhost", 0)).unwrap();
        let addr = l.local_addr().unwrap();
        std::thread::spawn(move || crate::txserve::serve(l, decode));
        let mut c = std::net::TcpStream::connect(addr).unwrap();
        let mut req = format!("POST /decode HTTP/1.1\r\nHost: x\r\nContent-Type: {ct}\r\nContent-Length: {}\r\n\r\n", body.len()).into_bytes();
        req.extend_from_slice(body);
        c.write_all(&req).unwrap();
        let mut out = String::new();
        c.read_to_string(&mut out).unwrap();
        (out[9..12].parse().unwrap(), out.split_once("\r\n\r\n").unwrap().1.to_string())
    }
    fn wrap(bytes: &[u8], ct: &str) -> Vec<u8> {
        let b64 = base64::engine::general_purpose::STANDARD.encode(bytes);
        serde_json::to_vec(&serde_json::json!({"b64": b64, "ct": ct, "path": "/v1/pipeline/transactions", "id": "x"})).unwrap()
    }

    #[test]
    fn server_raw_and_b64_envelope_agree_and_errors_are_non_2xx() {
        let good = norito(&tx(1, vec![Mint::asset_quantity(1u32, asset(1, 2, Some(1))).into()]));
        let (s1, raw) = post("application/x-norito", &good);
        let (s2, env) = post("application/json", &wrap(&good, "application/x-norito"));
        assert_eq!((s1, s2), (200, 200));
        assert_eq!(raw, env);
        assert!(raw.contains(r#""kind":"mint""#), "{raw}");
        let trailing = [good.clone(), vec![0]].concat();
        for (s, b) in [post("application/x-norito", &trailing), post("application/json", &wrap(&trailing, "application/x-norito"))] {
            assert_eq!(s, 422);
            assert!(b.contains(r#""ok":false"#), "{b}");
        }
        assert_eq!(post("application/json", &wrap(&good, "text/plain")).0, 415);
        assert_eq!(post("application/json", br#"{"b64":"!!","ct":"application/x-norito"}"#).0, 422);
        assert_eq!(post("application/json", br#"{"b64":"AAAA"}"#).0, 415);
    }

    fn cap(dir: &std::path::Path, prefix: &str) -> Option<Vec<u8>> {
        std::fs::read_dir(dir).unwrap().map(|e| e.unwrap().path()).find_map(|p| {
            let n = p.file_name()?.to_str()?;
            (n.starts_with(prefix) && n.ends_with(".body")).then(|| std::fs::read(&p).unwrap())
        })
    }

    #[test]
    fn golden_captured_bodies() {
        let Some(dir) = std::env::var_os("RD_DFABI_TXCAP_DIR") else { return };
        let dir = std::path::Path::new(&dir);
        let text = |f: &str| std::fs::read_to_string(dir.join(f)).ok().map(|s| s.trim().to_string());
        let mut seen = 0;
        let mut defs = Vec::new();
        for prefix in ["001", "002"] {
            let Some(b) = cap(dir, prefix) else { continue };
            let v = ok(&b);
            assert!(v.signature_ok && v.chain_id.starts_with("hash:") && v.executable == "instructions", "{prefix}");
            let [Instr::Transfer(t)] = v.instructions.as_slice() else { panic!("{prefix}: {:?}", v.instructions) };
            assert_eq!((t.scope.as_str(), t.dataspace, t.scale), ("dataspace:1", Some(1), 0), "{prefix}");
            assert_eq!(t.from.as_deref(), Some(v.authority.as_str()), "{prefix}: sender signs");
            assert!(t.to.is_some() && t.quantity.parse::<u128>().is_ok_and(|q| q > 0), "{prefix}");
            defs.push(t.asset_definition.clone());
            // exactly Torii's decode: one more byte is refused, and the same bytes through the b64 envelope agree
            assert!(decode(&[b.clone(), vec![0]].concat(), Format::Norito).is_err(), "{prefix}");
            assert_eq!(post("application/json", &wrap(&b, "application/x-norito")).0, 200, "{prefix}");
            seen += 1;
        }
        if let [a, b] = defs.as_slice() {
            assert_ne!(a, b, "001 and 002 are different tokens (RD, DFABI)");
        }
        if let Some(b) = cap(dir, "003") {
            let v = ok(&b);
            let [Instr::Mint(m)] = v.instructions.as_slice() else { panic!("{:?}", v.instructions) };
            assert!(v.signature_ok && m.from.is_none() && m.to.is_some() && m.scope == "dataspace:1");
            seen += 1;
        }
        let (intent, sid) = (text("dvp-intent.txt"), text("dvp-sid.txt"));
        if let Some(b) = cap(dir, "007") {
            let v = ok(&b);
            let [Instr::Grant(g)] = v.instructions.as_slice() else { panic!("{:?}", v.instructions) };
            let c = g.consent.as_ref().expect("007 is a CanExecuteSettlement consent");
            assert!(v.signature_ok && g.permission.as_deref() == Some("CanExecuteSettlement"));
            assert!(c.debited_asset.ends_with("#dataspace:1"), "{}", c.debited_asset);
            if let (Some(i), Some(s)) = (&intent, &sid) {
                assert_eq!((&c.intent_hash, &c.settlement_id), (i, s));
            }
            seen += 1;
        }
        if let Some(b) = cap(dir, "008") {
            let v = ok(&b);
            let [Instr::Dvp(d)] = v.instructions.as_slice() else { panic!("{:?}", v.instructions) };
            assert!(v.signature_ok && d.atomicity == "all_or_nothing");
            assert_ne!(d.delivery.asset_definition, d.payment.asset_definition);
            assert_eq!((&d.delivery.from, &d.delivery.to), (&d.payment.to, &d.payment.from), "legs cross");
            if let (Some(i), Some(s)) = (&intent, &sid) {
                assert_eq!((&d.intent_hash, &d.settlement_id), (i, s));
            }
            seen += 1;
        }
        assert!(seen > 0, "RD_DFABI_TXCAP_DIR holds none of 001/002/003/007/008 *.body");
    }
}
