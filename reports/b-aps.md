# Item (b): Atomic Private Settlement (APS) for RD/DFABI

Date: 2026-11-10. Source `071e281e`, genesis `a3d75eea` (wiped and redeployed twice on 2026-11-09).
Driver `rd-dfabi` image `ghcr.io/radityaaa43/iroha3-rd-driver:ce4641e2` (public repo
`radityaaa43/iroha3-rd-node-build`, `driver/`).

**Result: PASS.** Scenarios s1 to s4 pass on the cluster, and Lensa runs DvP and award as private
APS bundles.

## Scenarios (cluster, `scenario.yml`, driver `23f7a444`)

| Scenario | Run | Result |
|---|---|---|
| selftest | 42587115383 | one leg proved in 15.6 s, peak RSS 1.1 GiB |
| s1 DvP A/B (RD 100, DFABI 10) | 42643887642 | `outcome=finalized` after 76 s |
| s2a insufficient note | 42644331626 | refused before proving (Job fails as intended) |
| s2b over BI's limit | 42644445137 | BI rejects leg 0, sponsor aborts: `outcome=aborted` |
| s3 replay | 42644788129 | finalized once; replayed carrier accepted by Torii, receipt unchanged |
| s4 BI/C | 42645296775 | `outcome=finalized` |
| s5 respend | not run | upstream limit: Merkle paths only for a fresh pool with 2 notes (plan revision) |

## Lensa (frontend branch `feat/iroha3-aps-lensa`, not pushed)

Measured through the Lensa API on 2026-11-10:

| Flow | Time | BI | Parties | Other banks |
|---|---|---|---|---|
| DvP A to B 3 | 168 s | `reported` (audit records) | `clear` | C `sealed` |
| award BI to C 2 | 132 s | `clear` (issuer) | C `clear` | A, B `sealed` |
| DvP B to C 1 | 163 s | `reported` | `clear` | A `sealed` |
| rd-transfer A to B 5 | 25 s | all four `clear` (public lane 1, unchanged) | | |

## Faults found and fixed

1. **Two pool activations in one tx never commit.** The activations route to ds-rd and ds-dfabi. In one
   transaction they become a cross-dataspace plan whose lane-0 payload is never produced: the tx stays
   Queued and no block is proposed. It also blocks lane 0 for every later tx, and restarts do not
   clear it. Fix: one tx per pool (driver `6b3a6962`). Recovery needed two network wipes.
   (A first diagnosis blamed `bi`'s node state; a fresh network reproduced the stall, so that was
   wrong.)
2. **Availability certification HTTP 400 on all four validators.** The driver took
   `SIDECAR_RETENTION_BLOCKS = 4096` from the upstream localnet test, which also sets the peers to
   4096. Our peers keep the default 1_000_000. Torii rejects
   `retention_until_height < stored_at + sidecar_retention_blocks` with
   `private_settlement_invalid_request`, which is masked as generic `bad_request` because the error
   has no message. Fix: `23f7a444`.
3. **Zero-value change note.** `funding = amount + reimbursement` makes
   `seal_private_settlement_audit_capsule_v1` fail ("audit canonical encoding failed") after both
   pools are activated. The driver now refuses it up front (`ce4641e2`); Lensa funds 1 extra.
4. **bi-auditor HTTP.** A GET without Content-Length hung waiting for EOF (`0cdd2571`).
5. **Deploy.** PVC needs `storageClassName: alicloud-essd-wffc`; Job `fsGroup` for 0400 Secret files;
   `client.toml` and `genesis.expected_hash` mounted via `subPath` (the Iroha config loader rejects
   symlinks).
6. **Restoring a PVC.** A helper pod with `fsGroup` makes the volume group-writable. iroha3d then
   refuses to start (snapshot, SoraNet replay store, private-settlement sidecar store need exact
   0700/0600). Never mount a peer PVC with `fsGroup`.
7. **CI.** The cache path contained `..`, so the cache was never saved. Fresh clone mtimes then made
   cargo rebuild all of upstream. Test step 55 min → 1 min.

## Residuals

- Public balances do not move: each leg spends a fresh note funded at pool activation (plan
  revision). Lensa's balance cards still show the public lane-1 balances.
- Transfers (one party) stay public on lane 1: APS needs at least 2 legs.
- One bundle at a time in Lensa (each proof ~1.1 GiB); a DvP takes 2.5 to 3 minutes.
- Lane-0 stall from a cross-dataspace tx is an upstream liveness bug at `071e281e`: any client that
  submits one blocks the network until a wipe.
- Network diagnostics evidence (signed `ops sumeragi diagnostics`, trace logs) is in the
  session scratchpad, not in the repo.
