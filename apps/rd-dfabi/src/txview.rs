//! Output contract of `decode-tx`: what the OPA gateway rules see of one Iroha 3 transaction request body.
//!
//! Plain serde types, so the schema (`schema/decode-tx.*.json`) and the HTTP server are testable in the light build.
//! The `decode` feature fills them from a `SignedTransaction` (decode.rs). Every id is the string the `iroha` CLI prints
//! (account = I105, asset definition = Base58); amounts are decimal strings. Nothing here can carry a key or a signature.
//!
//! Fail-closed contract for rego: a body that is not exactly one canonical `SignedTransaction` gives `{"ok":false,...}`
//! (and exit code 3 / HTTP 422); an instruction the decoder has no view for is `{"kind":"unknown","raw_kind":...}`.

#![cfg_attr(not(feature = "decode"), allow(dead_code))]

use schemars::JsonSchema;
use serde::{Deserialize, Serialize};

/// Request side: the only input besides the raw body. In `serve` mode it is the request's `Content-Type` header.
#[derive(Debug, Serialize, Deserialize, JsonSchema)]
pub struct DecodeTxReq {
    /// `application/x-norito` (versioned Norito SignedTransaction, what the CLI sends) or `application/json`
    /// (optionally `; charset=utf-8`). Same rule as Torii's `typed_request_content_format`.
    pub content_type: String,
}

/// Response: exactly one of the two shapes; `ok` says which.
#[derive(Debug, Serialize, Deserialize, JsonSchema)]
#[serde(untagged)]
pub enum DecodeOut {
    Ok(TxView),
    Err(DecodeErr),
}

#[derive(Debug, Serialize, Deserialize, JsonSchema)]
pub struct DecodeErr {
    /// Always false.
    pub ok: bool,
    pub error: DecodeErrBody,
}

#[derive(Debug, Serialize, Deserialize, JsonSchema)]
pub struct DecodeErrBody {
    /// bad_content_type | decode_failed | non_canonical | too_large | needs_decode_feature | io
    pub code: String,
    pub message: String,
}

impl DecodeErr {
    pub fn new(code: &str, message: impl Into<String>) -> Self {
        Self { ok: false, error: DecodeErrBody { code: code.into(), message: message.into() } }
    }
}

#[derive(Debug, Serialize, Deserialize, JsonSchema)]
pub struct TxView {
    /// Always true.
    pub ok: bool,
    /// norito | json: how the body was encoded. The tx route accepts both; a policy normally denies json.
    pub encoding: String,
    /// Transaction hash, lowercase hex (what the CLI prints and `transaction status` takes).
    pub tx_hash: String,
    /// True when the transaction signature verifies against the authority's key (Torii checks it again).
    pub signature_ok: bool,
    /// Authority account (I105).
    pub authority: String,
    /// Network id the tx is bound to (`hash:<HEX>#<crc>`), or "genesis" for the genesis-only domain.
    pub chain_id: String,
    pub creation_time_ms: u64,
    /// Absent only in malformed input.
    pub time_to_live_ms: Option<u64>,
    pub nonce: Option<u32>,
    /// ordinary | queue_plan_synced
    pub admission_intent: String,
    /// authority | sponsor
    pub fee_payer: String,
    /// instructions | contract_call | ivm | ivm_proved | batch. Only `instructions` and `batch` fill `instructions`.
    pub executable: String,
    /// True when the tx carries proof attachments.
    pub has_attachments: bool,
    /// True when the tx carries a multisig signature bundle.
    pub has_multisig: bool,
    /// In order. For `batch`, contract-call items are `unknown` with raw_kind `contract_call`.
    pub instructions: Vec<Instr>,
}

/// One instruction. `kind` is the discriminator.
#[derive(Debug, Serialize, Deserialize, JsonSchema)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Instr {
    /// Asset mint: `to` is the credited account.
    Mint(Movement),
    /// Asset burn: `from` is the debited account.
    Burn(Movement),
    /// Asset transfer (`iroha ledger asset transfer`).
    Transfer(Movement),
    /// Native delivery-versus-payment settlement.
    Dvp(Dvp),
    /// Permission or role grant. The DvP consent (`CanExecuteSettlement`) fills `consent`.
    Grant(Grant),
    /// Registration; `object` names what (domain, account, asset_definition, nft, role, trigger, peer).
    Register { object: String },
    /// SetKeyValue; `target` names the object type (domain, account, asset_definition, nft, trigger).
    SetKeyValue { target: String },
    /// Everything else (other instruction boxes, other Transfer/Mint/Burn variants, contract calls).
    Unknown { raw_kind: String },
}

#[derive(Debug, Serialize, Deserialize, JsonSchema)]
pub struct Movement {
    /// Asset definition id (Base58).
    pub asset_definition: String,
    /// Decimal string, as printed by the data model.
    pub quantity: String,
    /// Decimal scale of the quantity; 0 for whole units.
    pub scale: u32,
    pub from: Option<String>,
    pub to: Option<String>,
    /// global | dataspace:<n>: the balance bucket the instruction addresses.
    pub scope: String,
    /// n of `dataspace:<n>`, else null.
    pub dataspace: Option<u64>,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema)]
pub struct Leg {
    pub asset_definition: String,
    pub quantity: String,
    pub scale: u32,
    pub from: String,
    pub to: String,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema)]
pub struct Dvp {
    pub settlement_id: String,
    pub delivery: Leg,
    pub payment: Leg,
    /// delivery_then_payment | payment_then_delivery
    pub order: String,
    /// all_or_nothing | commit_first_leg | commit_second_leg
    pub atomicity: String,
    /// `DvpIsi::intent_hash` (`hash:<HEX>#<crc>`): what the buyer's consent grant must name.
    pub intent_hash: String,
}

#[derive(Debug, Serialize, Deserialize, JsonSchema)]
pub struct Grant {
    /// permission | role | role_permission
    pub grant_kind: String,
    /// Permission name (e.g. CanExecuteSettlement); null for a role grant.
    pub permission: Option<String>,
    /// Permission payload as the chain stores it; null when absent or not JSON.
    pub payload: Option<serde_json::Value>,
    /// Receiving account (I105) for permission and role grants; the role name for role_permission.
    pub to: String,
    pub consent: Option<Consent>,
}

/// The payload of a `CanExecuteSettlement` grant (the DvP consent), field for field.
#[derive(Debug, Serialize, Deserialize, JsonSchema)]
pub struct Consent {
    pub debited_asset: String,
    /// global | dataspace:<n>: the balance bucket `debited_asset` names. A DvP leg carries no scope (SettlementLeg has none,
    /// core takes the bucket from this consent: isi/settlement.rs resolve_authorized_settlement_leg_asset_ids); null when
    /// `debited_asset` does not parse as an asset id.
    pub debited_scope: Option<String>,
    /// n of `dataspace:<n>`, else null.
    pub debited_dataspace: Option<u64>,
    pub intent_hash: String,
    pub settlement_id: String,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Format {
    Norito,
    Json,
}

/// Torii's rule (utils.rs `typed_request_content_format`) for the two accepted media types: exactly one header value,
/// `application/json` with no parameter or one `charset=utf-8`, or parameter-free `application/x-norito`.
pub fn content_format(header: Option<&str>) -> Result<Format, DecodeErr> {
    let bad = |m: &str| DecodeErr::new("bad_content_type", m);
    let h = header.ok_or_else(|| bad("missing Content-Type"))?.trim();
    let mut parts = h.split(';').map(str::trim);
    let media = parts.next().unwrap_or("").to_ascii_lowercase();
    let params: Vec<&str> = parts.collect();
    match (media.as_str(), params.as_slice()) {
        ("application/x-norito", []) => Ok(Format::Norito),
        ("application/json", []) => Ok(Format::Json),
        ("application/json", [p]) if p.replace(' ', "").eq_ignore_ascii_case("charset=utf-8") => Ok(Format::Json),
        _ => Err(bad("Content-Type must be application/x-norito or application/json")),
    }
}

/// Output line plus exit code for a decode result (0 ok, 3 error: same code the other subcommands use).
pub fn render(r: Result<TxView, DecodeErr>) -> (String, u8) {
    let (out, code) = match r {
        Ok(v) => (DecodeOut::Ok(v), 0),
        Err(e) => (DecodeOut::Err(e), 3),
    };
    (serde_json::to_string(&out).expect("decode output serialises"), code)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn content_type_follows_torii_rule() {
        assert_eq!(content_format(Some("application/x-norito")).unwrap(), Format::Norito);
        assert_eq!(content_format(Some("Application/JSON; charset=UTF-8")).unwrap(), Format::Json);
        assert_eq!(content_format(Some("application/json")).unwrap(), Format::Json);
        for bad in [None, Some(""), Some("text/plain"), Some("application/x-norito; v=1"), Some("application/json; charset=latin1")] {
            assert_eq!(content_format(bad).unwrap_err().error.code, "bad_content_type", "{bad:?}");
        }
    }

    #[test]
    fn error_renders_with_exit_3_and_unknown_has_raw_kind() {
        let (out, code) = render(Err(DecodeErr::new("non_canonical", "x")));
        assert_eq!(code, 3);
        assert_eq!(out, r#"{"ok":false,"error":{"code":"non_canonical","message":"x"}}"#);
        let u = serde_json::to_string(&Instr::Unknown { raw_kind: "iroha.log".into() }).unwrap();
        assert_eq!(u, r#"{"kind":"unknown","raw_kind":"iroha.log"}"#);
    }
}
