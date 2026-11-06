//! Real implementation, compiled only with `--features aps` (pulls iroha_core, zk-stark; hours in CI).
//! Module plan (see design doc section 3 for the upstream file:line behind every item):
//!   store  - wallet seed, note store (pending -> confirmed), pool ledger, audit store; 0600 files, atomic rename
//!   tree   - depth-32 note tree over a pool's full leaf list (upstream accumulator is pub(crate))
//!   pool   - GovernedLeg, funding notes, ActivatePrivateSettlementPoolV1
//!   dvp    - prepare legs, prove, availability, upload, audit, prepare, register, commit, finalize
//!   audit  - seal/open capsule, approve, audit store
//!   torii  - signed GETs for status/receipt/lifecycle/capabilities
pub const UPSTREAM_REV: &str = "071e281e778c5928cab4d6e007b7ddc9b050df27";
