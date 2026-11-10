# Iroha 3: semua flow RD/DFABI privat lewat APS — Desain

Tanggal: 2026-11-10. Status: disetujui user ("okey go", 2026-11-10). Memperluas
`2026-10-23-iroha3-aps-rd-dfabi-design.md` (O1, O3, O4, O5).

## 1. Tujuan

Untuk issuance RD/DFABI, transfer RD, transfer DFABI, DvP dan award: hanya pengirim,
penerima dan BI yang melihat transaksi utuh (nominal, pihak, aset). Data dibaca dari chain,
bukan dari database Lensa. Node validator bank lain tidak menyimpan plaintext.

## 2. Mengapa APS (hasil spike 2026-11-10, iroha `071e281e`)

- Dataspace/lane per bank tidak memenuhi tujuan: payload transaksi lane dikirim ke semua
  validator global (`iroha_core/src/sumeragi/v2_lane_work.rs:12067-12079`), ditanam di blok
  global (`iroha_data_model/src/block/execution_context.rs:353`) dan dieksekusi ulang ke
  world state bersama. `storage = commitment_only` hanya deklaratif. Committee lane minimal 4.
- `Shield`/`ZkTransfer`/`Unshield` (`ShieldedOnly`) sudah dihapus
  (`iroha_data_model/src/isi/registry.rs:1395`). ZK-ACE dan anonymous escrow juga pensiun.
- APS: validator hanya melihat commitment, nullifier, root dan ciphertext; BI membuka audit
  capsule. Satu-satunya mekanisme aktif yang memenuhi tujuan.

## 3. Koreksi atas desain item (b) dan rekomendasi chat sebelumnya (self-review)

1. **Note hasil terima BISA dibelanjakan ulang.** Batas "Merkle path hanya untuk pool baru
   2 note" (driver `aps.rs:9-12`) hanya batas helper wallet
   (`plan_atomic_private_settlement_bootstrap_v1`). Validator menerima settlement berturut di
   pool yang sama (`iroha_core/src/private_settlement/state.rs:694-695`: `old_epoch == epoch`,
   `old_root == root`), dan upstream punya test kontinuasi
   `wallet_continues_settlement_with_fresh_virtual_dummy_without_bootstrap`
   (`privacy_engines/atomic_private_settlement/relation.rs:961`): input 0 = note hidup dengan
   path dihitung dari riwayat commitment, input 1 = dummy virtual. Pohon note adalah Merkle
   SHA-256 depth 32 append-only dengan domain publik
   (`privacy_engines/proof_managed_accumulator.rs:19-39,116-137`) → path dihitung driver.
2. **Issuance bukan "pool baru per issuance".** Pool RD dan pool DFABI masing-masing
   diaktifkan SEKALI dengan 2 note origin milik BI (cadangan). Issuance = transfer privat
   BI → bank dari cadangan itu. Total suplai privat = nilai origin.
3. **Leg pendamping = BI → BI** di pool aset lain (bukan A → A), jadi bank tidak perlu
   memegang aset kedua. Belum terbukti protokol menerima payer == recipient (gate G2).
4. **Pool berurutan:** satu bundle per pool dalam satu waktu (`old_root` harus = root kini).
   Lensa sudah men-serialisasi tx (busy lock), jadi cukup.
5. **Saldo dari chain:** wallet tiap pihak memindai output terenkripsi pool dan mendekripsi
   dengan view key-nya; nullifier yang sudah terbit menandai note terpakai.

## 4. Desain

| Flow | Bundle APS (leg 0 di ds-rd, leg 1 di ds-dfabi) |
|---|---|
| rd-issue BI→X | RD: BI→X nominal · DFABI: BI→BI 1 |
| dfabi-issue BI→X | RD: BI→BI 1 · DFABI: BI→X nominal |
| rd-transfer X→Y | RD: X→Y · DFABI: BI→BI 1 |
| dfabi-transfer X→Y | RD: BI→BI 1 · DFABI: X→Y |
| dvp X jual DFABI ke Y | RD: Y→X harga · DFABI: X→Y |
| award BI jual DFABI ke X | RD: X→BI harga · DFABI: BI→X |

- Tiap leg: input 0 = satu note hidup payer yang cukup (nominal + kembalian ≥ 1, + 1 untuk
  reimbursement sponsor di leg 0), input 1 = dummy virtual; output 3 tetap (penerima,
  kembalian, slot ketiga).
- Kunci per pihak: spend secret + view key note (file 0600 di direktori kunci, sama seperti
  `<party>.seed`). Alamat pembayaran = `derive_note_authority_v1(spend)` + view public key.
- Saldo publik RD/DFABI (ds-rd) tidak dipakai lagi oleh flow Lensa iroha3.

## 5. Gate (berhenti dan lapor ke user bila gagal)

- **G1a** offline: leg kontinuasi (note hasil terima + dummy) terbukti dan terverifikasi lokal.
- **G1b** jaringan: dua bundle berturut di pool yang sama, bundle kedua membelanjakan note
  hasil bundle pertama, finalized.
- **G2** leg pendamping BI→BI diterima.
- **G3** riwayat pool (commitment origin + output terurut + output terenkripsi) terbaca dari
  chain lewat Torii/blok, cukup untuk menghitung root yang sama dengan pool head.
- **G4** governance pool tetap valid sepanjang demo (jendela validitas kebijakan pool).

## 6. Batasan yang dilaporkan

APS "not yet production-qualified"; ~2-3 menit per tx; metadata publik (waktu, jumlah
peserta, dataspace, pool aktif); satu note per leg (tanpa menggabung note); throughput
serial per pool.

## 7. Non-goal

Menggabung banyak note dalam satu leg, rotasi kunci auditor, TPS tinggi, migrasi saldo
publik lama.
