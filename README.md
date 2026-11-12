# Iroha 3 Privacy PoC — RD & DFABI

Proof of concept privasi transaksi Rupiah Digital (RD) dan DFABI di Hyperledger Iroha 3
untuk 4 party (BI, Bank A, Bank B, Bank C), memakai `AtomicPrivateSettlementV1` (APS),
jalur privasi yang terdokumentasi di [docs.iroha.tech](https://docs.iroha.tech/get-started/atomic-private-settlement).

- Desain: [`docs/superpowers/specs/2026-10-23-iroha3-aps-rd-dfabi-design.md`](docs/superpowers/specs/2026-10-23-iroha3-aps-rd-dfabi-design.md)
- Plan 1, setup jaringan: [`docs/superpowers/plans/2026-10-23-01-network-setup.md`](docs/superpowers/plans/2026-10-23-01-network-setup.md)
- Plan 2, skenario use case: [`docs/superpowers/plans/2026-10-23-02-usecase-aps-scenarios.md`](docs/superpowers/plans/2026-10-23-02-usecase-aps-scenarios.md)

Source Iroha: `hyperledger-iroha/iroha` @ `071e281e`. Image node di-build di repo public terpisah
[`radityaaa43/iroha3-rd-node-build`](https://github.com/radityaaa43/iroha3-rd-node-build)
(repo ini private dan terhubung ke runner di cluster, jadi tidak boleh public).
Target: namespace `iroha3` di cluster ACK, deploy lewat GitHub Actions dengan runner di dalam cluster.

> **Kunci tidak pernah masuk Git.** Kunci privat validator, genesis, wallet, auditor, dan
> kubeconfig cluster dibuat atau disimpan di luar repo. Repo ini hanya berisi artefak publik.

Status: PoC, bukan klaim produksi. APS di upstream masih "disabled by default, not yet production-qualified".

> Catatan: `deploy/runner` (self-hosted runner di dalam cluster, ServiceAccount dengan `pods/exec` dan baca Secret di namespace lama `iroha3`) sudah DIHAPUS dari repo ini. Semua workflow memakai runner GitHub-hosted; `scripts/check-rbac-exec.py` (dijalankan oleh `scripts/test-rbac-exec.sh` di CI) menolak Role mana pun yang memberi `pods/exec|attach|portforward`, resource `*`, atau get/list/watch Secret tanpa `resourceNames`.
