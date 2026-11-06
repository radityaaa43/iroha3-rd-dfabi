# (a) - RD and DFABI as DataspaceRestricted assets in one dataspace

**Result: DEPLOYED, checks pending.** Genesis `a3d75eea` is live on all 4 peers and a canary ping
committed. The frontend steps and the four success checks are not done yet (see "Success checks").

**Privacy result: R1 is NOT met by (a) alone.** The Torii read grant is per dataspace, and every
validator stores every lane-1 block. See "Residuals". Real R1 needs the APS path (item (b)).

Date: 2026-11-06 (UTC).

## 1. What changed

| Item | Before (`ea8b5dff`) | Now (`a3d75eea`) |
|---|---|---|
| Genesis commit | - | `31e2520` |
| Chain id | previous network (genesis hash8 `ea8b5dff`) | `851464f5-af06-4311-8cb5-455cf74d0428` |
| RD / DFABI `balance_scope_policy` | `Global` (every tx lands in lane 0) | `DataspaceRestricted` |
| Home dataspace | none (universal) | **one** dataspace `ds-rd` (id 1, lane 1) for both assets |
| Asset ids | `7onbjg2gRXveoAAUFsohCZyGW98t` (RD), `4mBWK1JCwQdHLDPpuVKc56eLsXka` (DFABI) | unchanged |
| Aliases | `rd#wonderland.universal`, `dfabi#wonderland.universal` | `rd#wonderland.ds-rd`, `dfabi#wonderland.ds-rd` |
| `CanReadRestrictedDataspace` | none | BI, A, B on dataspace 1 and 2 (direct grant plus role `restricted_reader_ds{1,2}_{bi,a,b}`); **none for C** |
| Lane 2 (`ds-dfabi`) | idle | idle by design (nothing is homed there) |

The asset ids did not change: genesis `Register` does not check an id against its domain, and kagami's
staged genesis execution accepted the kept ids. Only the aliases moved, so the frontend id handling is
untouched. Manifest size: 13 transactions, kagami normalizes to 16, the cap is 16 (`block.rs:3328`), so
this design must not grow by another genesis transaction.

## 2. Why one dataspace

An earlier design put RD in `ds-rd` and DFABI in `ds-dfabi`. It was rejected: DvP across two restricted
dataspaces cannot execute. Source evidence at `071e281e`, paths under `crates/`:

- Routing allows it. A tx that touches two dataspaces becomes `RoutingPlan::NativeAmx`
  (`iroha_core/src/queue/router.rs:2296-2328`, `merge_transaction_target_dataspace`). A DvP over two
  restricted dataspaces is covered by `queue/router_cross_dataspace_plan_tests.rs:2195-2323`.
- Execution rejects it:
  - `tx.rs:3077-3087` (and `block.rs:11692-11715`)
  - `asset.rs:5555-5565`: a non-universal asset scope must match the executing dataspace
  - `asset/public_balance_scope.rs:76-83`
  - `settlement.rs:287-300`
  - upstream negative test `settlement.rs:3138-3273`
- Same-dataspace DvP is the supported shape (`settlement.rs:308-352`). Upstream has no positive unit
  test for this exact shape; the negative test differs only in the payment dataspace. It is proven only
  by success check 2.
- Fallback `SettleAtomic` (per-leg scopes, routes NativeAmx, `router/settlement_atomic.rs:33-67`) is
  **not used**. Upstream marks it unqualified (`settlement/atomic.rs:3-4`, TODO "network
  qualification"), it needs a universal coordinator with a universal-targeted co-instruction in the same
  tx (`router.rs:2296-2328`), the shipped `iroha` CLI has no `settlement atomic` command (dvp, pvp, fx
  only), and the frontend decoder rejects scoped asset ids. Candidate for a later cluster experiment.

Consequence: lane 1 carries RD transfers, DFABI transfers and DvP. Lane 2 stays at height 1.

## 3. Residuals

These are the privacy limits of (a). They are not bugs; they follow from the lane layout and the grant
model.

1. **bank-c stores everything.** All four validators are in all three lanes (`nexus.toml` header;
   `generate.sh` registers each validator in lanes 1 and 2). bank-c's validator therefore stores every
   lane-1 block in plaintext. The shared operator account (`CanReadAllLedgerData`, the same key on all
   four nodes) can read all of it on bank-c's node. C's 403 is a Torii API permission, not
   confidentiality.
2. **The read grant is per dataspace, not per transaction.** BI, A and B can read ALL `ds-rd` data,
   including the transactions and balances of C. C cannot read even its own balances through its own
   account; Lensa reads balances via the node operator account (`op-*`, `--scope dataspace:1`).
3. **R1 is not met.** R1 ("only BI, sender and receiver see a transaction") does not hold with (a)
   alone: a third party (A or B) sees a transaction between BI and C, and C's validator holds the data.
   Real R1 needs the APS path, item (b): Atomic Private Settlement with commitments and an audit
   capsule wrapped to BI.
4. **R2 stays exempt.** See `reports/g1-network.md`, "Root cause" and its conclusion (R2 is not
   achievable with 4 validators where BI is one of them; same exemption as before, (a) does not change
   it). The lane author rule is unchanged.
5. Proof level: genesis execution was proven offline (kagami executes the staged genesis). Lane
   commits, DvP execution and the 403 behaviour were source-derived and are proven only by the live
   checks below.

## 4. Deploy record so far

| Step | Result |
|---|---|
| Backup | `~/iroha3-backup-2026-11-06-dsr`, mode 700, checksummed (`MANIFEST.sha256`) |
| Wipe | 4 StatefulSets and 4 PVCs in namespace `iroha3` only; `gha-runner` untouched |
| Genesis | committed on all 4 peers: blocks 1, peers 3, view_changes 0; 4 Committee consensus keys registered at activation 1 |
| Canary ping | `f79d0df392b5fe3d944441ec0d267f54968a3e4cb3f3137041ff8c2219dfe08b`, result `Ok` |
| Heights after canary | height 4 on all nodes; lanes `{0:4, 1:1, 2:1}` |

Warning seen during height 1 that did not block commit:

```
fastpq lane: failed to build batches height=1 ... TransferWitness ... sender balance underflow while chaining transfer
```

The same warning class appeared at genesis in G1b (`reports/g1b-multilane.md`, "Node logs"). It is
logged, not fatal.

## 5. Success checks

Status after the genesis deploy and canary. Frontend steps (operator key, bootstrap, mints, Lensa
restart) come next; the table is filled after them.

| # | Check | Pass criterion | Result |
|---|---|---|---|
| 1 | Lane 1 commits from RD and DFABI transfers | On all four nodes lane 1 height grows by at least 2 and `lane1/ds1` shows served txs; lane 2 stays at 1 (expected) | **PENDING** |
| 2 | DvP A to B via Lensa | tx `Applied`; B DFABI +5 and RD moved by the opposite amount (`--scope dataspace:1`) | **PENDING** |
| 3 | C gets 403 while the parties can read | bank-a, bank-b answer for the same query; bank-c answers HTTP 403 on `asset get` (and `transaction get`, if gated) | **PENDING** |
| 4 | Lensa balance and health | `GET /api/balance?model=iroha3&party=C` returns C's RD and DFABI via `op-bank-c`; `GET /api/health` ready | **PENDING** |

Check 3 also records the residual (not a pass criterion): with `op-bank-c` (operator key) `transaction
get` for the same hash succeeds, and bank-c's lane 1 height equals the others. Quote this in any privacy
claim.

If the grants did not take effect (check 3 returns data for C), the fallback is a second genesis
iteration. If lane 1 does not commit, rollback restores the Global-asset network `ea8b5dff` from the
backup (chain history is gone either way).
