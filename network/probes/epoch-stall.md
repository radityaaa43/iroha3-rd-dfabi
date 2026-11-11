# Probe design: does an NPoS epoch boundary stall a stock iroha3d? (DESIGN only, no value or mode decided)

Question (user): is the stall at the epoch end real, and what are the options? The probe answers it on a throwaway chain in CI, before any S5 cluster operation.
Nothing here fixes an epoch length or a consensus mode; the large value and the mode are inputs, chosen by lead/user after the rows below.

## What upstream (iroha@071e281e) says, to be confirmed by the rows
- NPoS epoch 0 ends at height `epoch_length_blocks` (iroha_core/src/sumeragi/v2_context.rs:339-352); permissioned mode has `u64::MAX` (:339-345).
- At the epoch end the node needs the next-epoch KAGEMUSHA parameter (v2_context.rs:896-899, error :377/:1061) and the Commit vote carries a next-epoch snapshot, which needs the local Pasta authority (iroha_core/src/sumeragi/v2_worker_io_execution.rs:260-268, "requires a provisioned Pasta epoch authority").
- Stock `iroha3d` has no loader for that authority (irohad/src/taira_runtime_signer.rs:516-526 is the only setter; bin iroha3d_taira.rs:5 is chain-locked).
- `epoch_length_blocks` is a NonZeroU64 in the `sumeragi_npos_parameters` genesis custom parameter (iroha_data_model/src/parameter/system.rs:412); validation needs `epoch_length_blocks * 3` not to overflow u64 (:538-542), so the usable maximum is below u64::MAX / 3 = 6148914691236517205.
- A multilane (custom lane or dataspace) catalog is refused unless the signed genesis mode is NPoS: irohad/src/main.rs:8104-8109; `uses_multilane_catalogs` is irohad config `actual.rs:3015-3026`. Our 3-lane / 2-dataspace APS needs it. The mode is signed into the genesis (kagami `genesis generate --consensus-mode`, iroha_kagami/src/genesis/generate.rs:120,256), not a peer.toml key.

## Rows (each is a CI job on the node image 071e281e-stark, 4 stock nodes, throwaway keys, no secrets, no cluster)
| row | genesis | expected | what is quoted |
|---|---|---|---|
| R1 control | NPoS, `epoch_length_blocks = 20` | height reaches 20, no 21 within 120 s | last height, node log line (Pasta authority / missing next-epoch parameter) |
| R2 large | NPoS, `epoch_length_blocks = L` (input, `L < 6148914691236517205`) | height >= 40 | heights over time, any boundary error |
| R3 permissioned | permissioned, DEFAULT single-lane catalog | height >= 40 | heights over time |
| R4 permissioned + our lanes | permissioned, our 3-lane catalog | start refused | the `custom Nexus lane topology requires ... NPoS` message |

RED = R1 must show the stall (otherwise the question is not real and R2 proves nothing). R2/R3 are only meaningful next to a stalling R1 of the same build.
Traffic: one transfer every few seconds so blocks exist (record whether blocks are produced idle; if not, the heights above are driven by that traffic).

## Mechanics (reuses what network/generate.sh already does)
1. `kagami localnet --peers 4 --consensus-mode <npos|permissioned>` (throwaway chain id).
2. For R1/R2: set `epoch_length_blocks` in the `sumeragi_npos_parameters` custom parameter of the localnet `genesis.json` with jq; re-sign with the localnet `genesis.private_key` (`kagami genesis sign`, as generate.sh does at its signing step, with `--config` of peer 0).
3. Rewrite the localnet configs to container form (generate.sh "Rewrite localnet" block), run 4 containers `iroha3d --sora --config ...` on one docker network.
4. Poll the Torii status of each node for the committed height every 5 s for 180 s; print one line per sample.
5. Fail the job (RED) when R1 does NOT stall, or R2/R3 stall, or R4 starts.

Status: design only; the workflow file comes after lead/user confirm the rows and `L`.
