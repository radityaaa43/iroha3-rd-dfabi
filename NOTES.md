# iroha3 notes

## Parked

- **Wallet reads next to a proof (INVESTIGATE, parked 2026-11-10 by lead).** After the restart
  rollout and the merges: one demo-class pay under `flock /tmp/lensa-paladin.lock` plus 4 parallel
  `rd-dfabi wallet` reads; sample `docker stats`; report peak RSS per container. Context: `walletOf`
  spawns one container per party (cap 2 GiB / 2 CPU, shared cap with the prover in dockerRunner),
  not serialized with the prover; overlap only on the first read after a Lensa restart (cache).
- **Note fragmentation (known risk, parked).** A leg spends one live note; no consolidate command.
  Workaround: BI top-up. See `reports/c-aps-all-flows.md` § Risks.
- **Review follow-ups (lead, 2026-11-10; after restart rollout + merges; driver changes need image rebuild + rollout = CLUSTER-OP).**
  M1 pools.rs run_bundle: lock pools.json or reload before save (until then: no manual `pay`/`dvp-shared` while Lensa is up).
  M2 aps.rs settle: abort on every non-finalized exit, not only prepare (abort is accepted after Prepare is registered:
  iroha_core global_state.rs plan_private_settlement_abort_v1 removes the bundle's staged locks unless a receipt exists).
  M3 auditor GET /records: serialize only the 7 fields the adapter uses; confirm the CNI enforces NetworkPolicy.
  L1 receipt cache tmp name: random suffix, NOT pid (the driver is PID 1 in every container); refetch on decode failure (live race 2026-11-11, pools.rs:178; node-build PR #3). L2 pool_init: write origin note before activation.
  L3 checked_add for amount + reimbursement. L5 Lensa poolHeights()/journal: log or throw, atomic journal write (fe file).
  L4 closed: Cargo.lock holds one sha2 (0.10.9). Plan doc 03 is stale (wallet_json shape, test names).

## Component provenance (ASK from lead, 2026-11-10)

Pin: `hyperledger-iroha/iroha@071e281e778c5928cab4d6e007b7ddc9b050df27` (below: `iroha@071e281e:path:line`).
Ours: driver = `radityaaa43/iroha3-rd-node-build@d928b6e` `driver/src/*` (3,255 lines); Lensa = `rd-lensa-frontend`
`server/src/adapters/iroha3-aps.ts`, `iroha3.ts`; deploy = `radityaaa43/iroha3-rd-dfabi@7916af0`.

| Component | Upstream @ pin | Our changes | Official alternative @ pin |
|---|---|---|---|
| Node image `iroha3-rd-node:071e281e-stark` | iroha@071e281e `Dockerfile` | No source patch. Build args only: `FEATURES="external-software-signer-bin,zk-stark"`, `BINARIES=iroha3d iroha kagami sorafs_external_software_signer` (`node-build/build/build-image.sh:24-35`). Driver build adds `apps/rd-dfabi` as a workspace member (`driver/build.sh`), not in the image. | n/a (this is upstream) |
| Network config / genesis | `kagami localnet`, `kagami genesis validate` (iroha@071e281e `crates/iroha_kagami`) | Our overlay: `network/generate.sh`, `network/nexus.toml` (3 lanes, APS on), `network/genesis-rd-dfabi.jq` | none for our RD/DFABI topology |
| APS coordinator (upload, votes, prepare, commit, finalize, abort, receipts) | Rust client `iroha@071e281e:crates/iroha/src/client/private_settlement.rs` (public methods) | Calls only those public methods (`driver/src/aps.rs:340` settle, `:478` abort_bundle) | same client methods; CLI `iroha nexus private-settlement leg-upload/prepare-vote/commit-vote/bundle-submit/...` (`crates/iroha_cli/src/nexus.rs:70-98`) for the network steps |
| Leg proving, bootstrap (fresh pool) — **custom** (composition) | public `plan_atomic_private_settlement_bootstrap_v1`, `prepare_*`, `encode/consume_*_wallet_bundle_v1` (`iroha@071e281e:crates/iroha_core/src/privacy_engines/atomic_private_settlement/mod.rs:26-37`) | Composition copied from upstream integration test `integration_tests/tests/nexus/atomic_private_settlement_localnet.rs` (`driver/src/aps.rs:1080` prepare_leg); placeholder authorizations follow that test (`aps.rs:981`, `:1024`) | none as a published wallet/CLI: the CLI has no prove/leg-prepare command (`nexus.rs:70-98`); docs say the client builds proofs in a native wallet |
| **Spend a received note (continuation)** — **custom, kept (option A)** (tree.rs, item (c)) | Protocol accepts it: `iroha_core/src/private_settlement/state.rs:694-695` (old_root/old_epoch = pool head). Path helpers are crate-private: `privacy_engines/proof_managed_accumulator.rs:201,247,288` `pub(crate)`; the only continuation example is a unit test `atomic_private_settlement/relation.rs:961` with test-only path helper `:922` | **REIMPLEMENTED by us**: client-side note tree `driver/src/tree.rs:20-22,44` copies the leaf/node/empty-leaf domains and depth 32 of `proof_managed_accumulator.rs:19-39,116-137`; feeds the public `AtomicPrivateSettlementInputSecretV1::new` (`aps.rs:1309-1323`). Verified only by our tests vs `plan_atomic_private_settlement_bootstrap_v1` and by live finalization | **none**: upstream exposes Merkle paths only for a fresh two-note pool |
| Wallet scan, balances — **custom** (wallet scan, one-time view keys, pools.json) | public `decrypt_ivm_private_wallet_note_v1`, `derive_note_nullifier_v1` (`ivm_private_note/mod.rs:54-60,75-76`) | Ours: `wallet.rs:53` open_output, `:81` note_nullifier (builds a carrier statement; only pool/program ids are read, `relation.rs:1030-1052`), `:128` scan; one-time view keys `H(view‖bundle‖pool‖role)` `wallet.rs:40` (our scheme); pool index `pools.json` + receipt cache (`pools.rs`) | none (no wallet/indexer for APS notes upstream) |
| Long-lived pools, pay / dvp-shared — **custom** | public `ActivatePrivateSettlementPoolV1::from_restricted`, `PrivateSettlementPoolGovernanceV1::from_restricted_mapping` | Ours: `pools.rs:249` pool_init, `:301` pay (companion leg BI→BI 1), dvp-shared, wallet | none |
| bi-auditor (HTTP service, approve + record store) — **custom** | upstream online auditor: `iroha nexus private-settlement audit-online` (`crates/iroha_cli/src/nexus/private_settlement_online_auditor.rs`, 1,707 lines; fail-closed, business policy: allowed payers/recipients/sponsors/assets, `:48-64`) | **Ours**: `driver/src/auditor.rs` (468 lines) decrypts with public `seal/open` capsule APIs and submits approvals via the client; adds a decrypted record store + `GET /records` | **YES**: `audit-online` (one-shot per leg). It has no record store/history API, so BI history would need another source |
| Lensa wrapper | none | Ours: `iroha3-aps.ts` (runs the driver container, parses `result_json=`/`wallet_json=`), `iroha3.ts` shared-pool mode | none |
| Deploy manifests | none (upstream ships compose/kagami examples) | Ours: `deploy/k8s/*` (StatefulSets, probes 3 s), `deploy/k8s-apps/bi-auditor.yaml`, `deploy/jobs/*` | none |

Item (c) depends on custom code (tree.rs); it is kept; the no-custom rule applies to new work only (user decision 2026-11-10).

Verdict: the node is unpatched upstream. The APS network protocol is driven only through official public
APIs. Two things are ours, not official: (1) receiving-note spends depend on our client-side reimplementation of
the crate-private note-tree hashing (tree.rs); upstream offers no API for it. (2) bi-auditor is our service;
upstream has an official one-shot equivalent (`audit-online`). [unverified]: whether upstream main (post-071e281e)
has since exposed a continuation/wallet API; not checked, pin rule.
