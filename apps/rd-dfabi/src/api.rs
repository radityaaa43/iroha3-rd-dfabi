//! JSON contract between the Lensa TS adapter and `rd-dfabi`.
//!
//! Every command reads one JSON request (stdin, or `--input FILE`) and prints one envelope on stdout:
//! `{"ok":true,"data":<Response>}` or `{"ok":false,"error":{code,message,retryable}}`.
//! Long commands (`dvp`, `pool activate`, `auditor run`) also print NDJSON [`Progress`] lines on stderr.
//! Secrets never appear in any request or response: keys are named by party and read from `--home`.
//! Amounts are decimal strings (u128 on the wire, JS-safe). Schemas are generated from these types
//! (`rd-dfabi schema`) and committed under `schema/`; a test fails when they drift.

use schemars::JsonSchema;
use serde::{Deserialize, Serialize};

/// Frontend party ids (frontend/server/src/domain.ts PartyId).
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize, JsonSchema)]
pub enum Party {
    BI,
    A,
    B,
    C,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub enum Asset {
    #[serde(rename = "RD")]
    Rd,
    #[serde(rename = "DFABI")]
    Dfabi,
}

/// Decimal string, 0..=u128::MAX.
pub type Amount = String;
/// 32-byte hash as lowercase hex (no 0x).
pub type Hex32 = String;

/// Exactly one of `data` / `error` is set; `ok` says which.
#[derive(Debug, Serialize, Deserialize, JsonSchema)]
pub struct Envelope<T> {
    pub ok: bool,
    pub data: Option<T>,
    pub error: Option<ErrorBody>,
}

#[derive(Debug, Serialize, Deserialize, JsonSchema)]
pub struct ErrorBody {
    /// not_implemented | bad_request | no_such_wallet | insufficient_notes | aps_not_active | pool_busy |
    /// audit_rejected | audit_timeout | committee_unreachable | prove_failed | chain_rejected | internal
    pub code: String,
    pub message: String,
    /// true when the same request can be retried unchanged (pool_busy, committee_unreachable, audit_timeout).
    pub retryable: bool,
}

/// One NDJSON line on stderr while a long command runs; the adapter turns these into StepEvents.
#[derive(Debug, Serialize, Deserialize, JsonSchema)]
pub struct Progress {
    /// prove | availability | upload | audit | prepare | register | commit | finalize | activate
    pub phase: String,
    /// Leg ordinal (0 = ds-rd, 1 = ds-dfabi) when the phase is per leg.
    pub leg: Option<u8>,
    pub ms: u64,
}

#[derive(Debug, Serialize, Deserialize, JsonSchema)]
pub struct Route {
    pub dataspace: u64,
    pub lane: u32,
    pub incarnation: u64,
}

// ---- keys init -------------------------------------------------------------------------------

#[derive(Debug, Serialize, Deserialize, JsonSchema)]
pub struct KeysInitReq {
    pub party: Party,
    /// Overwrite an existing wallet seed. Refused when the wallet holds unspent notes.
    #[serde(default)]
    pub force: bool,
}

#[derive(Debug, Serialize, Deserialize, JsonSchema)]
pub struct KeysInitResp {
    pub party: Party,
    pub wallet_dir: String,
    /// X25519 view public key new notes are encrypted to (public).
    pub receive_view_key: Hex32,
    /// Spending authority = hash of the note spending secret (public).
    pub receive_authority: Hex32,
    /// BI only: auditor hybrid (X25519 + ML-KEM-768) public key placed in the audit policy.
    pub auditor_encryption_key: Option<String>,
}

// ---- pool activate ---------------------------------------------------------------------------

#[derive(Debug, Serialize, Deserialize, JsonSchema)]
pub struct PoolHolder {
    pub party: Party,
    /// One initial note per entry (1..=4096 per pool in total). Value of each note.
    pub notes: Vec<Amount>,
}

#[derive(Debug, Serialize, Deserialize, JsonSchema)]
pub struct PoolPlan {
    /// RD is pooled in ds-rd (dataspace 1, lane 1), DFABI in ds-dfabi (dataspace 2, lane 2).
    pub asset: Asset,
    pub holders: Vec<PoolHolder>,
}

#[derive(Debug, Serialize, Deserialize, JsonSchema)]
pub struct PoolActivateReq {
    pub plans: Vec<PoolPlan>,
    /// Client config of the account holding CanEnactGovernance (genesis account). Path only, read by the helper.
    pub governance_client_config: String,
    /// Build and print the plan (commitments count, pool ids) without submitting.
    #[serde(default)]
    pub dry_run: bool,
}

#[derive(Debug, Serialize, Deserialize, JsonSchema)]
pub struct PoolInfo {
    pub asset: Asset,
    pub pool_id: Hex32,
    pub route: Route,
    /// Opaque binding commitment of the asset definition (what the chain shows).
    pub asset_binding_commitment: Hex32,
    pub notes: u32,
    pub tx_hash: Option<Hex32>,
    pub block: Option<u64>,
}

#[derive(Debug, Serialize, Deserialize, JsonSchema)]
pub struct PoolActivateResp {
    pub pools: Vec<PoolInfo>,
    pub dry_run: bool,
}

// ---- dvp -------------------------------------------------------------------------------------

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "lowercase")]
pub enum AuditorMode {
    /// The helper plays the BI auditor in-process (PoC default on the Lensa host).
    Inline,
    /// An external `auditor run` (BI-side process) must approve; dvp waits for it.
    External,
}

#[derive(Debug, Serialize, Deserialize, JsonSchema)]
pub struct DvpReq {
    /// Pays RD (leg 0, ds-rd), receives DFABI.
    pub buyer: Party,
    /// Pays DFABI (leg 1, ds-dfabi), receives RD.
    pub seller: Party,
    pub rd_amount: Amount,
    pub dfabi_amount: Amount,
    /// Pays the public XOR fee for both carriers. Default BI.
    pub sponsor: Option<Party>,
    pub auditor: AuditorMode,
    pub memo: Option<String>,
    /// Whole-run budget; the helper aborts the bundle cleanly when exceeded.
    pub timeout_ms: Option<u64>,
}

#[derive(Debug, Serialize, Deserialize, JsonSchema)]
pub struct PhaseTiming {
    pub phase: String,
    pub leg: Option<u8>,
    pub ms: u64,
}

#[derive(Debug, Serialize, Deserialize, JsonSchema)]
pub struct DvpResp {
    pub bundle_id: Hex32,
    /// Lane-0 carrier txs (RegisterAtomicPrivateSettlementPrepareV1, FinalizeAtomicPrivateSettlementV1).
    pub prepare_tx: Hex32,
    pub finalize_tx: Hex32,
    /// Block of the finalize carrier.
    pub block: u64,
    pub authority_context_height: u64,
    pub phases: Vec<PhaseTiming>,
    pub total_ms: u64,
}

// ---- status / receipt ------------------------------------------------------------------------

#[derive(Debug, Serialize, Deserialize, JsonSchema)]
pub struct BundleReq {
    pub bundle_id: Hex32,
    /// Whose Torii answers (every party reads its own node).
    pub as_party: Party,
}

#[derive(Debug, Serialize, Deserialize, JsonSchema)]
pub struct PublicLeg {
    pub ordinal: u8,
    pub route: Route,
    pub pool_id: Hex32,
    pub nullifiers: Vec<Hex32>,
    pub output_commitments: Vec<Hex32>,
    pub old_root: Hex32,
    pub new_root: Hex32,
}

/// Only what a non-party validator can see; no amounts, no accounts, no asset ids.
#[derive(Debug, Serialize, Deserialize, JsonSchema)]
pub struct StatusResp {
    /// collecting | audited | prepared | committed | aborted | expired | unknown
    pub lifecycle: String,
    pub sponsor: String,
    pub legs: Vec<PublicLeg>,
    pub finalize_tx: Option<Hex32>,
    pub block: Option<u64>,
}

// ---- capsule open (BI) / note decrypt (party) ------------------------------------------------

#[derive(Debug, Serialize, Deserialize, JsonSchema)]
pub struct CapsuleOpenReq {
    pub bundle_id: Hex32,
    /// Both legs when omitted.
    pub leg: Option<u8>,
}

#[derive(Debug, Serialize, Deserialize, JsonSchema)]
pub struct AuditLeg {
    pub ordinal: u8,
    pub asset: Asset,
    /// Canonical account ids from PrivateSettlementAuditPlaintextV1.
    pub payer: String,
    pub recipient: String,
    pub sponsor: String,
    pub amount: Amount,
    pub sponsor_reimbursement: Amount,
    pub memo: String,
}

#[derive(Debug, Serialize, Deserialize, JsonSchema)]
pub struct CapsuleOpenResp {
    pub bundle_id: Hex32,
    /// audit_store (plaintext kept at approval) | capsule (re-fetched from the committee and opened now)
    pub source: String,
    pub legs: Vec<AuditLeg>,
}

#[derive(Debug, Serialize, Deserialize, JsonSchema)]
pub struct NoteDecryptReq {
    pub party: Party,
    pub bundle_id: Hex32,
}

#[derive(Debug, Serialize, Deserialize, JsonSchema)]
pub struct OwnNote {
    pub leg: u8,
    pub asset: Asset,
    /// recipient | change | reimbursement
    pub role: String,
    pub value: Amount,
    pub commitment: Hex32,
    /// pending (bundle not final) | unspent | spent
    pub state: String,
}

#[derive(Debug, Serialize, Deserialize, JsonSchema)]
pub struct NoteDecryptResp {
    pub party: Party,
    pub bundle_id: Hex32,
    /// Empty for a party that owns no output of this bundle: it cannot decrypt anything.
    pub notes: Vec<OwnNote>,
}

// ---- balances --------------------------------------------------------------------------------

#[derive(Debug, Serialize, Deserialize, JsonSchema)]
pub struct BalancesReq {
    /// All parties when omitted.
    pub party: Option<Party>,
}

#[derive(Debug, Serialize, Deserialize, JsonSchema)]
pub struct Balance {
    pub party: Party,
    pub asset: Asset,
    /// Sum of unspent confirmed notes only; pending notes never count.
    pub total: Amount,
    pub notes: u32,
    pub largest_note: Amount,
}

#[derive(Debug, Serialize, Deserialize, JsonSchema)]
pub struct BalancesResp {
    pub balances: Vec<Balance>,
}

// ---- auditor ---------------------------------------------------------------------------------

#[derive(Debug, Serialize, Deserialize, JsonSchema)]
pub struct AuditorApproveReq {
    /// Approve one bundle. `auditor run` loops over all waiting bundles instead.
    pub bundle_id: Hex32,
    pub decision: AuditDecision,
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "lowercase")]
pub enum AuditDecision {
    Approve,
    Reject,
}

#[derive(Debug, Serialize, Deserialize, JsonSchema)]
pub struct AuditorApproveResp {
    pub bundle_id: Hex32,
    pub legs_approved: u8,
    /// Plaintext is stored in the BI audit store at this relative path.
    pub audit_store_path: String,
}

// ---- doctor ----------------------------------------------------------------------------------

#[derive(Debug, Serialize, Deserialize, JsonSchema)]
pub struct DoctorReq {}

#[derive(Debug, Serialize, Deserialize, JsonSchema)]
pub struct DoctorCheck {
    pub name: String,
    pub ok: bool,
    pub detail: String,
}

#[derive(Debug, Serialize, Deserialize, JsonSchema)]
pub struct DoctorResp {
    pub height: u64,
    /// privacy capability Active AND height >= nexus.atomic_private_settlement.activation_height.
    pub aps_active: bool,
    pub checks: Vec<DoctorCheck>,
}
