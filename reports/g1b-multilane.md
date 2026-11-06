# G1b - 3-lane Nexus topology with APS enabled

**Result: PARTIAL.** Lane 0 (universal, public) works: 4 Active validators, height increases, APS
activation height passed. Lanes 1 (`ds-rd`) and 2 (`ds-dfabi`) do not progress, and their validator
count cannot be read. Two causes, both found here:

1. With this config, a tx cannot be routed to lane 1 or 2. RD and DFABI are `balance_scope_policy =
   Global`, so every tx lands in lane 0.
2. Every user tx is **Rejected** (`signed fee intent is missing PipelineGas charge limit`). This
   blocks any real traffic, including the frontend's RD/DFABI mints. Details under "Blocker".

Date: 2026-11-06 (UTC). Run from the operator PC against the live `iroha3` namespace.

## Build under test

| Item | Value |
|---|---|
| Iroha source | `hyperledger-iroha/iroha@071e281e` (PR #5627 optimizations) |
| Image | `ghcr.io/radityaaa43/iroha3-rd-node:071e281e-stark` = `sha256:bf81cd7379ffb9e2aac096ee9489bcd0ea96cd82350b073db8bc9a4c9a3efc60` (same on all 4 pods) |
| Chain id | `b97bcbb4-b638-47a0-8612-b4b5f73932c4` |
| Genesis hash (final) | `hash:5EEC72874B82BA5E661A577CEE115D3C913BB7C65D62C06DF957C570BECEABEB#DBC2` |
| Repo commit | `984a9c3 fix(network): APS genesis uses NPoS consensus` (on top of `2449d8c`) |
| Consensus | NPoS, 4 validators `bi`, `bank-a`, `bank-b`, `bank-c`, quorum 3 |
| APS config | `enabled = true`, `activation_height = 11` (genesis proposal height 1 + notice 10) |

## Deploy attempts

| # | Genesis | Consensus | Outcome |
|---|---|---|---|
| 1 | `d23c355a` | permissioned (`kagami localnet --consensus-mode permissioned`) | All pods crash-looped at start: `custom Nexus lane topology requires the authenticated Sumeragi v2 mode to be NPoS` (irohad `crates/irohad/src/main.rs`, line ~8108 in the checked-out source). A custom lane catalog (3 lanes) is refused outside NPoS. |
| 2 | `5eec7287` | NPoS (`984a9c3`) | Network wiped and redeployed. 4 pods Ready, 0 restarts, `/v1/nexus/lifecycle` reports `lane_count 3` on all 4 peers. |

## Per-lane results (attempt 2)

`scripts/check-lanes.sh`, `INTERVAL=15`, `TRAFFIC_CMD` = one `iroha ledger transaction ping`
(see "Traffic" below). Identical on all 4 peers:

| Lane | Alias | Visibility | Active validators | Height before | Height after | Result |
|---|---|---|---|---|---|---|
| 0 | universal | public | **4** (Active, `activation_height` 1, stake 10000 each) | 25 | 28 | PASS |
| 1 | ds-rd | restricted | **not verifiable** (404) | 1 | 1 | FAIL: no traffic reaches the lane, count unreadable |
| 2 | ds-dfabi | restricted | **not verifiable** (404) | 1 | 1 | FAIL: same |

Script exit 1 (8 of 12 lane checks FAIL, all on lanes 1 and 2). Lane heights are the genesis block
only: no lane block was ever produced on lane 1 or 2.

### Why the validator count is unverifiable for lanes 1 and 2

- `GET /v1/nexus/public-lanes/{lane}/validators` is public-lane only. It returns 404 for a restricted lane
  (as in the `check-lanes.sh` header).
- Signed operator path also 404s. I called `iroha app nexus public-lane validators --lane N` with the
  BI node key as `--operator-private-key-file` (the node key is allowlisted by default,
  `torii.operator_signatures.allow_node_key = true`). Lane 0 returns 4 validators; lanes 1 and 2
  return `404 query_validation_failed`.
- `iroha app nexus lane-report` and `iroha ops sumeragi diagnostics` (operator-signed) list lanes 1
  and 2 with `validator_ids: []`, `quorum: null`, `manifest_required: false`. Lane 0 also shows
  empty `validator_ids`, so this field does not carry the roster here. `lane_block_sessions` shows
  `validator_count: 4` for lane 0 only; no session exists for lanes 1 and 2.
- Not shown: whether `RegisterPublicLaneValidator` for lanes 1/2 took effect in genesis. No
  endpoint I found exposes it for a restricted lane.

The check-lanes.sh result for lanes 1 and 2 is therefore "unverified", not "zero validators".

### Lane 0 progression (diagnostics)

Operator-signed `ops sumeragi diagnostics`: lane 0 lane blocks 1..6 with commit QC signers = 3 of
4 (`min_quorum 3`, `validator_count 4`), `qc_mode_tag` `iroha2-consensus::npos-sumeragi@v2`, global
block height 28 at the end. One early lane-0 execution at proposal height 3 shows
`stuck_reason: evidence_conflict`; later lane blocks reach `queue_finalized`. NPoS epoch length 3600.
Chain commits blocks only when a tx arrives (idle height stays flat, as in G1); each tx advanced the
height by about 6.

## Traffic: routing to lanes 1 and 2

`nexus.toml` has `routing_policy { default_lane = 0, default_dataspace = "universal" }` and **no
rules**. Source (`crates/iroha_core/src/queue/router.rs`,
`asset_balance_operation_concrete_dataspaces`): an asset whose definition has
`balance_scope_policy = Global` always routes to the universal dataspace. `genesis-rd-dfabi.jq`
registers RD and DFABI with `balance_scope_policy: "Global"`. So RD/DFABI transfers between party
accounts go to lane 0, not to lanes 1 or 2. Ways to reach lane 1 or 2 (none done here):

- add `[[nexus.routing_policy.rules]]` (matcher by `account` or `instruction`, `lane`, `dataspace`) to
  `nexus.toml` and redeploy;
- register an asset definition with `DataspaceRestricted` policy (needs a new asset; not a ping or
  net-zero transfer, so outside this run's allowed writes).

Traffic actually sent: 3 `ledger transaction ping` txs from `client-bi` (run inside `bi-0` against
`127.0.0.1:8080`, with a copy of `network/out/bi/client.toml` in the pod's tmpfs, removed after).
`smoke.sh` was not run: its step 3 scales the `bi` StatefulSet to 0 (the known G1 FAIL) and has no
skip switch. No net-zero transfers were sent. No RD/DFABI balances were touched.

## Blocker: every user tx is Rejected

Each ping reached a block and ended `Rejected` (blocks 7, 13, ...):

```
result.Err = "signed fee intent is missing PipelineGas charge limit"   (executor.rs:3862)
```

Cause (from reading source `071e281e`, not yet confirmed by a quote dump):

- Genesis (kagami) sets the on-chain parameters `ivm_gas_accepted_assets = ["6TEAJqbb..."]` and
  `ivm_gas_units_per_gas`. With `per_gas_unit_fee = "0"` (in `nexus.toml`), the pipeline-gas fee
  component is enabled at execution, which requires a `PipelineGas` charge limit in the signed intent.
- The fee quote that the CLI uses (`POST` fee quote in Torii) reads `app.state.pipeline_snapshot()`,
  built from the node config. `peer.toml` has `[pipeline.gas]` with `tech_account_id` only, so
  `accepted_assets` is empty and the quote returns no `PipelineGas` limit.
- The client signs the quote as given, so execution rejects it. The CLI has no flag to add a charge limit.

This also means all 4 peers' txs fail the same way, and the other agent's frontend mint from BI will be
Rejected too. Candidate fixes (need a config or genesis change and redeploy, which was out of scope):

- set `pipeline.gas.accepted_assets = ["6TEAJqbb8oEPmLncoNiMRbLEK6tw"]` (and a matching `units_per_gas`)
  in the peer config overlay, so quote and execution agree; or
- drop the `ivm_gas_*` custom parameters from genesis, or set a non-zero `per_gas_unit_fee`, so the
  pipeline-gas component is off at execution.

Rejected txs still consume a block slot, so lane 0 height grows even though no state changes.

## APS activation evidence

| Check | Result |
|---|---|
| Height past activation | Global height 28 (last read), `activation_height` 11. |
| `GET /v1/privacy/capabilities` (account-signed; needs an `x-iroha-account` canonical-hex header, no CLI command exists, signed with a small script using the BI client key) | `committed_height 23`. Protocol `iroha-ivm-private-note-stark-v1`: `lifecycle.state = active`, `proposed_at_height 1`, `activated_at_height 1`, limits `max_input_count 2`, `max_output_count 2`. |
| APS gate in code (`state.rs: ensure_private_settlement_feature_active_v1`) | Needs: `enabled`, height >= `activation_height`, an Active activation of that protocol with `proposed_at_height + notice <= activation_height`. 1 + 10 = 11 <= 11 holds; the activation record is present. All inputs for the gate are satisfied. |
| Same protocol, `readiness` | `unavailable`, reason `missing-production-qualification`. The APS gate above does not check it; whether an APS bundle later hits this at proof time is unverified. |
| Public APS endpoints | `/v1/nexus/private-settlements/bundles*` exist in `/openapi.json`; the paths answer, but no bundle was submitted. |
| Other protocols | The other 10 listed privacy protocols are `unavailable` (`not-registered` or `compiled-profile`); unrelated to APS. |

There is no single "APS active" flag endpoint. The evidence is the activation record plus
height/config, not an executed settlement.

## Node logs (read-only, last 5000 lines per pod)

No error or warning about lanes 1/2, committee keys or APS. Warnings seen, all non-blocking so far:

- ~100x `peer_monitor ... /v1/configuration returned HTTP 403` (telemetry peer monitor is not
  operator-signed; noise).
- `permanently rejected Sumeragi ingress envelope ... WrongHeightContext / RouteOwnershipInvalid`
  (a few per pod, around start).
- `Sumeragi v2 height has no classified semantic progress` at heights 2, 8 and others during start.
- 4x `Kura retains the configured-primary replay floor; rebuilding state from blocks` at start.
- 3x `fastpq lane: failed to build batches ... sender balance underflow` at height 1 (genesis).
- `alias permission lookup denied` for an unrelated authority (not from these tests).
- 10x `503 Service Unavailable` on Torii during the first minute.

## Still unverified

- Lanes 1 and 2: any lane block, the validator roster and committee keys. Needs a routing rule or a
  `DataspaceRestricted` asset, plus a working fee config.
- APS bundle lifecycle (submit, prepare/commit votes, receipt): not exercised.
- R2 (BI offline) still fails per G1: lane 0 liveness needs the fixed lane author (`reports/g1-network.md`).
  Not re-run here.
- `iroha-ivm-private-note-stark-v1` readiness `missing-production-qualification` effect on a real bundle.

## Reproduce

```bash
export KUBECONFIG=alibaba.yaml
# torii forwards bi 38080, bank-a 38081, bank-b 38082, bank-c 38083
TRAFFIC_CMD='kubectl -n iroha3 exec bi-0 -c iroha3d -- sh -c "cd /dev/shm/c && iroha --config client.toml --machine --fee-payer authority ledger transaction ping --msg g1b-$(date +%s)"' \
  INTERVAL=15 scripts/check-lanes.sh
```
