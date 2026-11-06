# G1 — 4-peer network smoke and BI-node-down liveness

**Result: FAIL at step 3.** With one validator stopped, the remaining three do not reliably
commit. The network recovers once the stopped peer returns.

Date: 2026-11-01 (UTC). Runner: in-cluster `gha-runner-0`, namespace `iroha3`.

## Build under test

| Item | Value |
|---|---|
| Iroha source | `hyperledger-iroha/iroha@071e281e778c5928cab4d6e007b7ddc9b050df27` |
| Image | `ghcr.io/radityaaa43/iroha3-rd-node:071e281e-stark` = `sha256:bf81cd7379ffb9e2aac096ee9489bcd0ea96cd82350b073db8bc9a4c9a3efc60` |
| Genesis hash | `hash:2986B430A4DA42EC3A7F5DDB3FDDC38CB4F8EF81971F409E35A67F9B6DFE212F#3773` |
| Topology | 4 validators `bi`, `bank-a`, `bank-b`, `bank-c` (`kagami localnet --consensus-mode permissioned`), quorum 2f+1 = 3 |
| On-chain Sumeragi params | `block_cadence_ms=1000`, `max_clock_drift_ms=1000` (no other timeout knobs exist; see below) |
| Roster order (sorted by validator id) | 0 `bank-a`, 1 `bank-b`, 2 `bi`, 3 `bank-c` |

## Smoke runs (`scripts/smoke.sh`, workflow `smoke.yml`)

| Step | Run 41323453089 (15:53) | Run 41325328234 (16:14) |
|---|---|---|
| 1. 4 peers same height/hash | PASS (h4 `214d3682…`) | PASS (h16 `1ed745a1…`) |
| 2. ping from `client-bi` Applied, peers converge | PASS (block 7, `7920badd…`) | PASS (block 19, `ea8ff4ad…`) |
| 3. BI down, ping from `client-bank-a` Applied | **FAIL** | **FAIL** |
| 4. BI up, catch-up ≤ 120 s | not reached | not reached |

Step 3 error (both runs, CLI `ledger transaction ping`):

```
transaction <hash> did not reach state-resolved Applied within 300000 ms; last_status=not_observed; attempts=150
```

Run 1: tx `070f628f…`. Run 2: tx `547e344c…`. During both, the three banks held the tx
(`queue_size=1`), `peers=2`, and the height did not move.

## Diagnostics

| Stopped peer | Time (UTC) | Outcome |
|---|---|---|
| bi | 15:54–16:03 | stalled at block 8 for > 6 min; resumed (block 10) when bi returned |
| bank-c | 16:05–16:07 | stalled at block 11 (ping timed out after 100 s); resumed (block 13) when bank-c returned |
| bank-c | 16:09–16:14 | **progressed**: blocks 14→16, tx committed in ~16 s with 3 peers |
| bi | 16:15–16:20 (run 2) | stalled at block 20; resumed (block 22) when bi returned |

Stall log on the live peers (`iroha_core::sumeragi::status`), e.g. run 2:

```
Sumeragi v2 height has no classified semantic progress height=21 view=1 leader=2 blocker=MissingProposal
```

`leader=2` is `bi`, the stopped peer. `view_change_suggest_total` and
`view_change_install_total` stayed `0` on every peer through every stall.

**Correction (debug-log run, see Root cause):** views do change. The `/status` view-change
counters stay `0` even while debug logs show `installed certified Sumeragi v2 view` for views
1→6. The earlier reading "the view never advanced" was wrong; the stall is not in global
leader failover.

Ruled out:
- Clock skew: pod clocks agree within ~10 ms (`max_clock_drift_ms=1000`).
- Connectivity: the remaining 3 peers stay mutually connected (`peers=2` each).
- NetworkPolicy: P2P 1337 allowed between all `app.kubernetes.io/part-of=iroha3-rd` pods.

Observation (not shown to be the cause): block `created_at` is logical time,
`genesis time + (height-1) × 1 s` (block 1 `2026-10-23T11:55:57.369Z`, block 22
`2026-10-23T11:56:18.369Z`). Ledger time is ~9 days behind wall clock because genesis was
generated on 2026-10-23 and the network started on 2026-11-01.

## Expected behaviour per upstream (071e281e)

- Quorum is 2f+1 = 3 of 4 (`crates/iroha_core/src/sumeragi/v2_core/types.rs:526-528`).
- View change: a local timer signs a TimeoutVote, and a quorum TimeoutCertificate installs the
  next view (`specs/sumeragi_pacemaker.md:29-33`). Deadline for view v is
  `min(base·(v+1), base·10)`, with `base = block_cadence_ms × 10` = 10 s
  (`crates/iroha_core/src/sumeragi/v2_runtime.rs:108-118`,
  `crates/iroha_config/src/parameters/defaults.rs:4011`). No peer config key overrides this
  (`specs/sumeragi_pacemaker.md:21-24`).
- Leader for (height, view) rotates through the roster (`v2_core/types.rs:561-578`).
- Official test `integration_tests/tests/sumeragi_lock_convergence.rs:19-110` stops the view-0
  leader of a 4-peer permissioned network and expects commits within 300 s.

So with these settings the three live peers should form a TimeoutCertificate within ~30 s.
Here they never did.

## Infrastructure fixes made during G1

- `fix(deploy): iroha3-peer PriorityClass`: after `bi` was stopped, a pod from another
  namespace took its node slot within 4 min, and bi's ESSD disk pins it to zone
  `ap-southeast-5a` (2 nodes, 15/15 pods). PriorityClass `iroha3-peer` (10000) lets a
  restarting validator preempt a priority-0 pod. Verified: bi-0 rescheduled on
  `core-11197-node` with priority 10000.
- `bank-a-0` and `bank-b-0` still run the pre-PriorityClass revision (OnDelete) and pick it up
  on their next restart.

## Root cause (debug-log run, 2026-11-01 16:38–16:58 UTC)

Method: `[logger] filter = "iroha_core::sumeragi=debug"` in the cluster `peer-<party>` Secrets
(env `LOG_FILTER` is ignored: `irohad` uses `ConfigReader::new().without_env()` whenever
`--config` is given, `crates/irohad/src/main.rs:11633`), bi stopped, 6 ping txs from bank-a.

Observed:
- None of the 6 txs committed in 20 min (`queue_size` 0→5 on all three banks), although the
  global chain kept producing blocks 33→36.
- Each global height took exactly ~240 s: views 1–6 are installed at +10, +30, +61, +101, +151,
  +211 s (timeouts 10/20/30/40/50/60 s, `v2_runtime.rs:108-118`). In view 6 the leader assembles
  a candidate with `work_deferred: 1, selected: 0` ~26 s in, and that block commits. The user tx
  stays deferred.
- From the second bi stops, every live peer logs ~300/s `retained exact Sumeragi v2 output behind
  network-actor backpressure` (outputs to bi, `v2_worker_services_impl.rs:4166-4171`). These are
  per-target and released at commit, so they are a symptom, not the cause.

Code chain (071e281e):
1. Torii accepts only `QueuePlanSynced` transactions: "public transaction submission requires a
   signature-bound QueuePlanSynced admission intent" (`crates/iroha_torii/src/lib.rs:25160-25165`).
2. The global leader never selects a `QueuePlanSynced` transaction. It counts it as
   `work_deferred` and leaves it to "cross the autonomous lane and merge corridor … while the lane
   author takes ownership" (`crates/iroha_core/src/sumeragi/v2_candidate.rs:833-842`).
3. Each autonomous lane block has exactly one author:
   `validator_set[(lane_block_height - 1) % n]`, "independent of the global carrier view"
   (`crates/iroha_core/src/lane_consensus.rs:90-107`). A payload from anyone else is rejected with
   `ProducerNotDeterministicAuthor` (`lane_consensus.rs:854-860`). Lane NewView certificates only
   advance a retransmission cursor; they do not change the author (`lane_consensus.rs` struct doc
   for `LaneExecutablePayloadV1`).
4. Spec: every lane committee is exactly `3f+1`, and its pool "must contain at least `3f+1`
   distinct live peers … undersized pools fail closed" (`specs/nexus.md:216`).

Conclusion: with 4 validators (`3f+1`, f=1), once the lane height reaches the offline
validator's turn, no valid lane payload can be produced and **no user transaction commits**
until that validator returns. The global chain keeps sealing transaction-less blocks every
~240 s. Which lane height the outage hits decides whether a few txs still pass first
(bank-c 16:09: one tx in ~16 s) or the stall is immediate.

So with this build, R2 (network keeps settling while BI is offline) is **not achievable with a
4-validator network where BI is one of the validators**. No peer config or on-chain parameter
changes the lane-author rule; `block_cadence_ms` only scales the global timeouts.

## Open

G1 is not met, and the cause is an upstream design property of the autonomous lane at
071e281e, not a deployment error. Resolved 2026-11-06 by accepting R2 as exempt for the
APS track (see "R2 verdict" below), so Plan 02 may proceed on this topology. Any alternative
(e.g. more validators so that `3f+1` live peers remain without BI) needs a localnet gate first;
there is no official example of it.

## R2 verdict (2026-11-06): EXEMPT

R2 ("system keeps working while BI is offline") stays **exempt** for the Iroha 3 APS track, as
in the team charter (`agents/TEAM.md`: "Iroha 3 (APS): BI is an online auditor, exempt from R2.").
Decision: option F below. Research only, no live experiment; source `071e281e`.

Root cause: the lane block author is fixed and has no failover.
- Author = `validators[(h-1) % n]`, no mode, view or liveness input: `crates/iroha_core/src/lane_consensus.rs:96-107`,
  enforced at `:854-860`. Autonomous payloads must be view 0 (`:984`, `:1048`), so a lane view change cannot move authorship.
- Lane pool = registered set, not live set; committee is exactly `3f+1`, so dropping BI from a 4-pool fails closed
  (`crates/iroha_core/src/state/lane_authority.rs:461-650`).
- `QueuePlanSynced` cannot be disabled: `ToriiProxyTransactionAdmissionV1` has a single variant
  (`crates/iroha_core/src/torii_proxy.rs:1345-1352`); Torii answers 409 otherwise (`crates/iroha_torii/src/lib.rs:25160-25165`).
- Removing BI via `SlashPublicLaneValidator` needs a tx through the stalled lane: circular.

Options:

| Option | R2 | Cost |
|---|---|---|
| A. BI out of lane pools, 4 non-BI validators (A, B, C + new node-d) | unverified; predicted BI-down only (any other validator down still stalls) | genesis change + wipe, 5th peer (cluster slots tight), no image rebuild, ~1-2 days; APS legs still stall while BI (sole auditor) is offline unless a second auditor + `min_approvals` is added |
| B. Pool >=5 + beacon-seeded committee | refuted as fix | probabilistic, beacon setup |
| C. Governance removal of BI | refuted as runtime failover | circular; planned swap only |
| D. Disable `QueuePlanSynced` | refuted | not configurable |
| E. More validators / higher f / knobs | refuted | worse or no effect |
| F. Keep R2 exempt | exempt (chosen) | zero |
| G. Upstream rewrite | unverified | 4-8 days, target build not known to compile |

Option A is deferred; do it only if a BI-down demo is requested.

Upstream: no issue or PR names the stall. The fix is a rewrite, not a patch: `d7dfb1ea` (2026-09-29) deleted
`lane_consensus.rs` and `lane_planner.rs` on the `optimizations` branch (`QueuePlanSynced` gone; per-lane Sumeragi
cores with timeout-certificate view change). PR #5653 (2026-11-03, closed unmerged): "The optimizations branch does
not compile". HEAD builds with Rust 1.99.1 (ours 1.93.1), APS config knobs are retired, and genesis is incompatible
(wipe + redo Task 8).

Track 2 probe (CI-only `cargo build` of candidate pins `929a6068`, `e3bbd985`): pending.
