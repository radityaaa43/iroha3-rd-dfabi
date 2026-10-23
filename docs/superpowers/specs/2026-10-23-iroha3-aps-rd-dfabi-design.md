# Iroha 3 Privacy PoC untuk RD & DFABI — Desain (revisi berbasis dokumentasi)

Tanggal: 2026-10-23. Status: disetujui untuk perencanaan. Menggantikan pendekatan
`Shield/ZkTransfer/Unshield` pada `Master_Implementation_Plan_Iroha3_Privacy_RD_DFABI_PoC.docx`
v1.0 (branch `i23-features` @ `ec0d6243`).

## 1. Mengapa revisi

Dokumentasi resmi (`hyperledger-iroha/iroha-docs` @ `753f3da`, 2026-09-01) merujuk kode
`0010c5a7` (`src/public/compat-matrix.json`). Pada kode itu dan sesudahnya:

- `Shield`, `ZkTransfer`, `Unshield` sudah dihapus upstream (`376c414f3`, 2026-08-03;
  test `default_registry_excludes_retired_confidential_instructions`). Satu-satunya halaman
  yang masih menyebutnya, `blockchain/anonymous-transactions.md`, sudah usang.
- Jalur privasi yang terdokumentasi untuk settlement adalah **`AtomicPrivateSettlementV1`**
  (APS): `get-started/atomic-private-settlement.md`, `reference/instructions.md`.

Karena itu PoC ini memakai APS.

## 2. Objective (revisi)

| ID | Objective | Status di desain ini |
|---|---|---|
| O1 | Hanya BI, pengirim, penerima melihat detail transaksi | Wajib. Detail leg hanya di audit capsule terenkripsi untuk auditor (BI); validator melihat data opaque. |
| O2 | Transaksi tetap jalan saat BI mati | **Dikecualikan** (keputusan user 2026-10-23, sama dengan track Fabric-X). Node validator BI boleh mati (quorum 3/4); layanan auditor BI harus hidup karena approval auditor wajib per leg. |
| O3 | Transfer RD/DFABI privat dengan note nyata | Terbatas: APS hanya bundle ≥2 leg di ≥2 dataspace. Transfer satu aset diuji sebagai skenario eksperimental. |
| O4 | DvP RD↔DFABI all-or-nothing, terikat ke satu trade | Wajib. Native APS: satu bundle, satu `FinalizeAtomicPrivateSettlementV1`. |
| O5 | BI membaca histori | Wajib. BI satu-satunya pemegang kunci dekripsi capsule; kunci lama disimpan untuk retensi. |

## 3. Keputusan

| Area | Keputusan | Diputuskan oleh |
|---|---|---|
| Source | `hyperledger-iroha/iroha` @ `071e281e778c5928cab4d6e007b7ddc9b050df27` (branch `optimizations`, merge PR #5627). `0010c5a7` tidak bisa di-compile. | Claude (fakta build) |
| Image | Build dari source dengan feature `external-software-signer-bin,zk-stark`; binary `iroha3d iroha kagami sorafs_external_software_signer` (`build/build-image.sh`). | Claude |
| Repo | GitHub baru **private** `radityaaa43/iroha3-rd-dfabi`. | User |
| CI build | GitHub-hosted runner → GHCR `ghcr.io/radityaaa43/iroha3-rd-node:<commit8>-stark`. Package GHCR dibuat **public** (isinya hanya binary open-source upstream) agar cluster bisa pull tanpa token. | Claude |
| CI deploy | Self-hosted runner **di cluster, namespace `iroha3`**, ServiceAccount hanya berhak di namespace itu. Tidak ada kubeconfig di GitHub. | User |
| Cluster | ACK `alibaba.yaml`, namespace `iroha3` (sudah ada, kosong). Namespace `iroha` (Iroha 2) tidak disentuh. | User |
| Topologi | 4 validator BLS: `bi`, `bank-a`, `bank-b`, `bank-c`, satu StatefulSet per party. 3 lane/dataspace: `universal` (lane 0, publik, carrier global), `ds-rd` (restricted, pool RD), `ds-dfabi` (restricted, pool DFABI). Keempat validator melayani ketiga lane. | Claude (APS mensyaratkan tepat 4 validator per dataspace) |
| Konsensus | Permissioned, committee 4 (f=1). | Claude |
| Auditor | BI satu-satunya auditor di policy kedua dataspace, `min_approvals = 1`. Layanan `bi-auditor` (Deployment terpisah dari node BI) mendekripsi capsule dan meng-approve sesuai aturan lokal. | User (pengecualian O2) + Claude (bentuk layanan) |
| Kunci | Kunci privat validator, genesis, SoraNet transport, auditor, dan wallet tidak pernah masuk Git atau GitHub. Dibuat di PC operator, dimasukkan sebagai k8s Secret. Kunci privat genesis tidak masuk cluster. | Best practice docs |
| Driver | Satu binary Rust `rd-dfabi` (wallet, coordinator, sponsor, auditor) memakai crate `iroha` / `iroha_core` @ `071e281e`, mengikuti `integration_tests/tests/nexus/atomic_private_settlement_localnet.rs`. JS/Python tidak dipakai (hanya transport, tidak bisa membuat proof). | Claude |

## 4. Skenario

Didukung native: penerbitan awal via aktivasi pool, DvP RD↔DFABI antarbank, DvP dengan BI
(redemption), DvP gagal tanpa perpindahan, anti-replay, audit BI, bank lain tidak bisa membaca,
node BI mati (consensus jalan).

Eksperimental (gate, boleh gagal dan dilaporkan): belanja ulang note hasil terima, transfer RD
tanpa obligasi (leg RD + leg DFABI A→A), 4 validator dipakai bersama semua dataspace.

Tidak didukung (dilaporkan, tidak diakali): transaksi saat auditor BI mati, mint RD tambahan ke
pool aktif, penarikan ke saldo publik, ≥75 TPS.

## 5. Constraint

- Node cluster 1.9–3.9 vCPU, ±7 GiB RAM, sudah dipakai namespace lain. Request kecil, ukur dulu.
- APS "disabled by default, not yet production-qualified" (docs). PoC ini bukan klaim produksi.
- Konfigurasi 4 peer bersama untuk semua dataspace belum diuji upstream (test resmi memakai
  validator terpisah). Ini gate pertama setup multi-lane.
- Genesis/topologi hanya diganti lewat wipe terkoordinasi semua peer (docs).

## 6. Non-goal

Integrasi RTGS nyata, HSM produksi, ≥75 TPS, lifecycle DFABI penuh, anonimitas traffic.
