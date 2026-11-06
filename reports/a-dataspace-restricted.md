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
   including the transactions and balances of C. C can read its own ds1 assets: `FindAssetById` on
   one's own account is not fan-out gated (live canary: C's own read returned
   `query_validation_failed` "Failed to find asset ...#dataspace:1", i.e. not found because C has no
   balance yet, not a 403). C cannot read other accounts' data or transactions (see the canary below).
   Lensa reads balances via the node operator account (`op-*`, `--scope dataspace:1`).
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
| 1 | Restricted-dataspace execution in ds1 from RD and DFABI transfers | Transfers and mints with `--scope dataspace:1` are `Applied` on all four nodes and balances move; `lane1/ds1` `tx_served` grows. `teu_lane_commit` lane height is NOT a pass criterion (see the lane-1 canary) | **PENDING** |
| 2 | DvP A to B via Lensa | tx `Applied`; B DFABI +5 and RD moved by the opposite amount (`--scope dataspace:1`) | **PENDING** |
| 3 | C gets 403 while the parties can read | bank-a, bank-b answer for the same query; bank-c answers HTTP 403 on `asset get` (and `transaction get`, if gated) | **PENDING** |
| 4 | Lensa balance and health | `GET /api/balance?model=iroha3&party=C` returns C's RD and DFABI via `op-bank-c`; `GET /api/health` ready | **PENDING** |

Check 3 also records the residual (not a pass criterion): with `op-bank-c` (operator key) `transaction
get` for the same hash succeeds, and bank-c's lane 1 height equals the others. Quote this in any privacy
claim.

If the grants did not take effect (check 3 returns data for C), the fallback is a second genesis
iteration. If lane 1 does not commit, rollback restores the Global-asset network `ea8b5dff` from the
backup (chain history is gone either way).

### Lane-1 canary (2026-11-06)

Canary after the frontend bootstrap: mint 1 RD to BI with scope `dataspace:1`, tx
`1f48a65eb1b96d37af8c3c07857436b545b0fd773030c58c7bbdcb61a16cb00b`, result `Applied`.

`GET /status` on all four nodes, before and after the mint:

| Field | Before | After |
|---|---|---|
| `blocks` | 4 | 7 |
| `teu_lane_commit` (`lane_id`: `block_height`) | - | `{0:7, 1:1, 2:1}`; the lane-1 value did not change |
| `teu_dataspace_backlog` lane 1 / ds 1 `tx_served` | - | 3 (rose) |

Question: does the lane-1 height of 1 mean the lane-1 pipeline is idle? Source reading at `071e281e`,
paths under `crates/`:

1. **What `teu_lane_commit.block_height` is.** `teu_lane_commit` is the cache
   `nexus_scheduler_lane_teu_status`, one `NexusLaneTeuStatus` per lane (`iroha_telemetry/src/metrics.rs:1375-1383`).
   The field is documented "Latest block height recorded for this lane"
   (`iroha_torii_shared/src/status/nexus.rs:314`).
2. **What writes it.** Three writers, none of them a per-lane block counter:
   - `StateTelemetry::record_lane_pipeline_summary` (`iroha_core/src/telemetry.rs:2643-2654`), called once
     per lane that has a routed tx in the block (an empty block falls back to the default lane) from
     `ValidBlock::validate_and_record_transactions_with_prepared` (`iroha_core/src/block.rs:15474-15528`).
     The value is the **global** height: `state_block._curr_block.height()` (`block.rs:15481`).
   - `record_lane_relay_finality` (`telemetry.rs:2704-2727`), called from `State::publish_prevalidated_lane_relay`
     (`iroha_core/src/state.rs:34122`) with `relay_proposal_height = envelope.block_header.height()`
     (`state.rs:33979`). The relay is built from the **global** block header
     (`iroha_core/src/sumeragi/v2_apply.rs:3961-3991`).
   - The seed: when the lane metadata cache is first built, a zero height is set to the global height at that
     moment (`telemetry.rs:929-931`). This is where the `1` of lanes 1 and 2 comes from (genesis height).
3. **How a restricted-dataspace tx commits.** It is an external entrypoint of the **global** block, and it
   is executed in the global `StateBlock` (`iroha_core/src/sumeragi/v2_candidate.rs:952-962` builds the
   block with its `execution_context`; execution is `block.rs:12016`, `validate_and_record_transactions_with_prepared`).
   The route (lane, dataspace) comes from `RoutingDecision`; a mint of a `DataspaceRestricted` asset routes to
   the asset's home dataspace (`iroha_core/src/queue/router.rs:3666-3680`,
   `asset_balance_operation_dataspace_target`). Lane-local blocks do exist as a separate artifact
   (`iroha_core/src/sumeragi/lane_planner.rs:2607-2620`, `prepare_v2_lane_payload_plan`; lane height is the
   lane tip plus one, `lane_planner.rs:1573`), but they are anchored by the global block, not committed
   instead of it: "A certified lane session is persisted only after a canonical global block anchors the
   exact ownership" (`iroha_core/src/sumeragi/v2_lane_work.rs:1-8`). Their real heights are in
   `GET /v1/sumeragi/status`, `committed_lane_blocks[].lane_block_height`
   (`iroha_torii/src/routing.rs:47880`, `iroha_core/src/sumeragi/status.rs:4863-4877`), not in `/status`.
4. **What `tx_served` counts.** "Cumulative transactions executed for this dataspace since node start"
   (`iroha_torii_shared/src/status/nexus.rs:561-562`). It adds the number of txs per (lane, dataspace)
   route in each block this node executes (`block.rs:13797-13803`, `13883-13890`;
   `telemetry.rs:2771-2783`). It counts executions on this node, not commits, and resets on restart.

**Conclusion: A.** Restricted-lane txs execute inside global blocks. `teu_lane_commit.block_height` is not
a lane-local block counter. It is the global height of the last block in which the lane had a routed tx or a
relayed finality statement, seeded to the global height at lane-metadata init. The lane-1 pipeline is not
shown to be idle or broken by this number.

One point the source reading does not explain: `record_lane_pipeline_summary` and the `tx_served` update
sit in the same function and both key off the same routing decisions (`block.rs:13797-13803` vs
`15474-15528`), so a block that executes a lane-1 route should also move the lane-1 height. A lane-1 height
of 1 with `tx_served` 3 fits only if the 3 counted txs were genesis txs (height 1). That reading does not
match the report that `tx_served` rose during the canary. The suggested check below settles it.

Suggested read-only check (not run): `GET /v1/sumeragi/status` on one node, fields
`committed_lane_blocks[]` (`lane_id`, `dataspace_id`, `lane_block_height`) and `lane_payload_ownerships[]`.
Lane-1 entries with a height of 1 or more, anchored at global heights 5 to 7, mean lane-1 work is real
and `teu_lane_commit` simply does not report it. No lane-1 entries at all would mean the mint was
routed to lane 0 (universal) and the stale `1` is correct.

**Consequence for (a).** The goal of (a) is restricted-dataspace execution in ds1: RD and DFABI txs with
`--scope dataspace:1` execute, move balances, and are visible only to holders of the dataspace grant. The
goal is not "lane 1 produces its own blocks". No further wipe is planned for it.

Canary read results (BI's mint, read by A and C):

- A and C both got HTTP 403 `query_validation_failed` "exact `CanReadAccountData` permission is required to
  read account <BI>" when reading BI's balance. This is the account-level rule, not the dataspace gate.
- `tx get` by hash of BI's tx gave HTTP 403 `query_validation_failed` "transaction-details" for both A and C.
- C's read of its own ds1 asset returned `query_validation_failed` "Failed to find asset ...#dataspace:1"
  (not found, no balance yet), not a 403.

Because of this, the dataspace-grant evidence (success check 3) is deferred to the post-bootstrap A to B
rd-transfer: A and B read the tx; C reads the tx and A's balance (expect 403); C reads its own balance.
The exact codes will be recorded then.

## Results after bootstrap (2026-11-06)

Frontend merge `02f3f71` (feat/iroha3-dsr onto 9ddcf0b, 3 server files, tsc 0, iroha3 tests 53/53, not pushed); bootstrap funded A/B/C with RD 10000000000000 and DFABI 1000 each; one `lensa` restart.

| Check | Result | Evidence |
|---|---|---|
| 1. ds1 execution | **PASS by construction** | RD/DFABI are DataspaceRestricted to ds1 and execution rejects a leg whose scope does not match the route (`asset.rs:5555-5565`, `public_balance_scope.rs:76-83`), so every Applied mint/transfer of them executed in ds1. Canary mint `1f48a65e…` Applied; bootstrap mints moved balances; blocks 7→25. `teu_dataspace_backlog.tx_served` is frozen at post-genesis values on 071e281e (lane0/ds0 = 45, lane1/ds1 = 3 before and after every tx) and is not usable as a metric. Lane-local block heights are only on operator-gated `/v1/sumeragi/status` (401 unsigned; node key not used by decision). |
| 2. DvP A→B 5 via Lensa | **PASS** | tx `a01e2fee51848e5ab5a8f3e8a0fda8d446cf9d8aaff223604a4b40d07d2bdaf7`, block 31. A: DFABI 1000→995, RD +5000000; B: DFABI 1000→1005, RD −5000000. |
| 3. Read matrix (rd-transfer A→B 1, tx `0bebe544e810f195ff005572e897649369639e507ca60fb20a532f56d877056b`, block 34), each party's own account key | **PARTIAL** (see below) | A: tx get OK, own balance OK. B: tx get OK; A's balance HTTP 403 `query_validation_failed` "exact CanReadAccountData permission is required to read account". C: tx get HTTP 403 `query_validation_failed: transaction-details`; A's balance HTTP 403 CanReadAccountData; C's own ds1 balance OK (10000000000000). BI: tx get HTTP 403 `transaction-details`; A's balance HTTP 403 CanReadAccountData. Operator account on bank-c's node (`op-bank-c`, CanReadAllLedgerData): tx get OK. |
| 4. Lensa | **PASS** | `/api/health` all five models ready (iroha3 "Empat validator Iroha 3 menjawab"); `/api/balance?model=iroha3&party=C` returns RD/DFABI via the operator. Zeto and Noto balance reads OK after the restart; gateway sink reports bi zeto 39 / noto 11 on nodes 1-4, all ready. |

What check 3 actually shows:
- The denials are the account/transaction-party rules (`query_validation_failed`: CanReadAccountData, transaction-details), not the restricted-dataspace route gate ("cannot read N requested restricted dataspace route(s)" never appeared). Parties read their own tx and own balances; non-parties do not, through their own account keys.
- The CanReadRestrictedDataspace grants to BI/A/B are therefore not what separates C from the parties on these queries.
- BI's own account key cannot read the A→B tx or A's balance. BI sees everything only through the shared operator account (CanReadAllLedgerData), which is the same key on every node, including bank-c's.
- Residuals unchanged: bank-c's validator stores lane-1 blocks in plaintext and the operator reads them on bank-c's node. R1 is NOT met by (a); it needs the APS path (b).
