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
`view_change_install_total` stayed `0` on every peer through every stall. The view never
advanced past the offline leader. Commits with 3 signers do work (`commit_qc_signatures_total=3`
of `commit_qc_validator_set_len=4`), so the stall is in leader failover, not in quorum.

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

## Open

G1 is not met. Plan 02 must not start until a 3-of-4 network keeps committing with any one
peer down. Next diagnostic: raise `logger.level` for `iroha_core::sumeragi` on the live peers,
repeat one stall, and check whether TimeoutVotes are produced, sent, received, and rejected.
