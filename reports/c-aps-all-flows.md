# Item (c): every RD/DFABI flow private through APS

Date: 2026-11-10. Source `071e281e`, same network as item (b) (no wipe).
Driver `ghcr.io/radityaaa43/iroha3-rd-driver:c1afa678` (repo `radityaaa43/iroha3-rd-node-build`,
branch `feat/aps-continuation`). Lensa branch `feat/iroha3-aps-all-flows`.
Spec `docs/superpowers/specs/2026-11-10-iroha3-aps-all-flows-design.md`, plan
`docs/superpowers/plans/2026-11-10-03-aps-all-flows.md`.

**Result: PASS.** Issuance, transfer (RD and DFABI), DvP and award all settle as APS bundles in two
long-lived pools. Only payer, payee and BI read amount and parties; the other banks' validators hold
commitments, nullifiers, ciphertexts and STARK proofs. Balances and history are read from the chain.

## Why APS, and why not a dataspace per bank

Spike on `071e281e` (code read, evidence checked by hand):

- A lane's transactions are fanned out in plaintext to every global validator
  (`iroha_core/src/sumeragi/v2_lane_work.rs:12067-12079`, `frozen_validator_set()`), embedded in the
  global block (`iroha_data_model/src/block/execution_context.rs:353`, `autonomous_lane_payloads`;
  `merge.rs:1158` "complete producer-authenticated payload") and re-executed into one shared world
  state. `storage = "commitment_only"` is not read by Kura, WSV, block sync or gossip. A lane committee
  is at least 4 peers (`fault_tolerance >= 1`, `iroha_config` user.rs:12318).
  So a dataspace per bank still leaves the plaintext on bank C's node.
- The documented private issuance/transfer path (`Shield`/`ZkTransfer`/`Unshield`, asset policy
  `ShieldedOnly`) is removed at this commit (`iroha_data_model/src/isi/registry.rs:1395`,
  `default_registry_excludes_retired_confidential_instructions`); ZK-ACE and anonymous escrow too.
- APS is the only active mechanism that keeps contents off the validators.

## Design

| Flow | Bundle (leg 0 RD in ds-rd, leg 1 DFABI in ds-dfabi) |
|---|---|
| rd-issue BI→X | RD BI→X · DFABI BI→BI 1 |
| dfabi-issue BI→X | RD BI→BI 1 · DFABI BI→X |
| rd-transfer X→Y | RD X→Y · DFABI BI→BI 1 |
| dfabi-transfer X→Y | RD BI→BI 1 · DFABI X→Y |
| dvp (X sells DFABI to Y) | RD Y→X · DFABI X→Y |
| award (BI sells to X) | RD X→BI · DFABI BI→X |

- `pool-init` activates one RD and one DFABI pool once, each with BI's reserve note
  (RD 10^15, DFABI 10^6). Policy and pool mapping have no retirement height.
- Every leg spends one live note of the payer (input 0) plus a virtual dummy (input 1). The driver
  rebuilds the pool's depth-32 SHA-256 note tree from the activation commitments and the finalized
  receipts, and computes the Merkle path itself. Upstream's helper only covers a fresh two-note pool;
  the protocol accepts any live note (upstream test
  `wallet_continues_settlement_with_fresh_virtual_dummy_without_bootstrap`).
- Each output gets a one-time view key `H(party view key, bundle, pool, role)`: recipient ids are
  public, so a fixed key would link a party's payments, and Prepare rejects repeated recipient ids
  within a bundle.
- A party's balance = its unspent notes in both pools; spent notes are found by their published
  nullifier. BI's history comes from its auditor records (`bi-auditor GET /records`).

## Gates

| Gate | Evidence | Result |
|---|---|---|
| G1a received note spendable (offline) | CI `continuation_leg_proves_and_verifies`, smoke `continuation_verified=true` (~20 s, 1.2 GiB) | PASS |
| G1b same, on the cluster | A spent BI's 1000 to pay B 300 (block 332); B spent it to pay C 100 | PASS |
| G2 companion leg BI→BI | audited and finalized in every single-asset bundle | PASS |
| G3 pool history from chain | every rebuilt root equals the finalized `new_root`; wallets match by hand | PASS |
| G4 long-lived pool | 9 bundles on the same two pools | PASS |

## Live run (cluster, driver CLI)

| # | Bundle | Time |
|---|---|---|
| 1 | rd-issue BI→A 1000 | 90 s |
| 2 | rd A→B 300 | 86 s |
| 3 | rd B→C 100 | 89 s |
| 4 | dfabi-issue BI→A 5 | 90 s |
| 5 | dfabi A→B 2 | 97 s |
| 6 | rd-issue BI→B 3 000 000 | 89 s |
| 7 | rd-issue BI→C 2 000 000 | 95 s |
| 8 | dvp A sells 1 DFABI to B for 1 000 000 RD | 89 s |
| 9 | award BI sells 1 DFABI to C | 94 s |

Wallets read from the chain afterwards, equal to the hand calculation (each RD-leg payer also pays the
sponsor 1): A RD 1 000 699 / DFABI 2, B 2 000 198 / 3, C 1 000 099 / 1,
BI 999 999 995 998 995 / 999 994.

## Faults found and fixed

1. A leg's three outputs need distinct view keys (`validate_output_authorizations`); a bundle's
   outputs need distinct recipient ids (`PrivateSettlementPrepareBarrierV1::validate_shape`). Fixed by
   one-time view keys per output (driver `9319d3ce`).
2. Prepare votes reserve the pool head (`sidecar_store.rs ensure_reservations_available_v1`). A bundle
   that stopped after the votes locked both pools until expiry. The driver now aborts it
   (`ParticipantRejected`), and `abort-bundle` releases one by hand.
3. The pool index lists a bundle before submission; history applies only finalized receipts, in
   finalized-height order, so a crash after finalization never loses a bundle.

## Residuals

- Custodial demo: the Lensa host holds every party's note keys (as for the other models).
- A recipient learns amount, not payer, from the chain; Lensa shows the counterparty from the
  payer's own record (journal), or only the party's side when the flow was not run from Lensa.
- One note per leg (no note merging): a payer needs one note larger than amount + 1.
- The sponsor reimbursement (1 per RD-leg payer) goes to a throwaway key.
- Public metadata: timing, participant dataspaces, pool activity. APS is "not yet
  production-qualified" upstream.
- About 90 s per flow (two STARK proofs, ~1.1 GiB each); bundles in one pool are serial.
- The stress test still uses public balances.
