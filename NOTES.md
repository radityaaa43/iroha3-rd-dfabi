# iroha3 notes

## Parked

- **Wallet reads next to a proof (INVESTIGATE, parked 2026-11-10 by lead).** After the restart
  rollout and the merges: one demo-class pay under `flock /tmp/lensa-paladin.lock` plus 4 parallel
  `rd-dfabi wallet` reads; sample `docker stats`; report peak RSS per container. Context: `walletOf`
  spawns one container per party (cap 2 GiB / 2 CPU, shared cap with the prover in dockerRunner),
  not serialized with the prover; overlap only on the first read after a Lensa restart (cache).
- **Note fragmentation (known risk, parked).** A leg spends one live note; no consolidate command.
  Workaround: BI top-up. See `reports/c-aps-all-flows.md` § Risks.
