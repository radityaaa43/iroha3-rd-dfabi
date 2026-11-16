# Iroha 3: APS sesuai dokumentasi dan repo resmi — Desain

Tanggal: 2026-11-16. Status: draf, menunggu persetujuan user. Memperbarui
`2026-10-23-iroha3-aps-rd-dfabi-design.md` dan `2026-11-10-iroha3-aps-all-flows-design.md`.

Sumber resmi yang dipakai:
- Dokumen APS: `hyperledger-iroha/iroha-docs` main, `src/get-started/atomic-private-settlement.md`
  (update 2026-09-01; halaman situs docs.iroha.tech saat ini 404, source dan sidebar masih ada).
  Dirujuk sebagai "docs:N".
- Upstream `hyperledger-iroha/iroha` @ `071e281e` (= main, ahead 0 per 2026-11-16):
  `specs/private_settlement.md` ("spec:N"), `specs/private_settlement_threat_model.md`,
  `specs/confidential_assets.md`, crate `iroha` client `src/client/private_settlement.rs`
  ("client:N").

## 1. Tujuan dan alasan

User (2026-11-16): "perbaiki semua! pastikan sesuai dengan dokumentasi/repo resmi!", lalu
"apapun dapat anda lakukan (meskipun reset chain)", dan memilih pendekatan A ("perbaiki A").

Audit 2026-11-16 menemukan desain berjalan sesuai dokumen APS dalam hal topologi (4 validator
per dataspace, 3-of-4), auditor terpisah, `min_approvals = 1`, retensi kunci, witness tetap di
driver pembayar, dan `recover_or_commit`. Penyimpangan yang diperbaiki desain ini:

| # | Penyimpangan | Rujukan resmi |
|---|---|---|
| D1 | Aset bisa ditebak dari route: satu CBDC per dataspace, dan driver selalu menaruh RD di leg 0 | spec:73, docs:37-40 |
| D2 | Transfer satu aset memakai leg pendamping aset LAIN (BI→BI 1 unit aset kedua) | spec:34 (2-255 leg, maks satu leg per dataspace) |
| D3 | Sponsor = akun operator/governance BI, bukan akun sponsor netral; note reimbursement dikirim ke kunci acak (1 RD terbakar per bundle) | docs:57 |
| D4 | Koordinator tidak restart-safe: Prepare memakai `prepare_…` biasa, state bundle hanya di memori | docs:152-157, 175-177 |
| D5 | Detail koordinator lain: upload gagal bila 1 dari 4 node gagal (upstream toleran), batas carrier konstanta V1, manifest receipt tidak dicocokkan, cache receipt lokal tanpa autentikasi, committee dari `peers.json` | docs:142-169, client:2283, client:2527-2603 |
| D6 | Bukti kualifikasi belum ada (latensi p50/p95/p99, uji restart/fault, pemindaian kebocoran) | docs:273-302 |

## 2. Fakta yang membatasi desain (hasil penelusuran repo resmi)

1. **Confidential assets bukan alternatif.** Instruksi `Shield`/`ZkTransfer`/`Unshield` pensiun
   dari wire (`specs/confidential_assets.md:218`, `isi/registry.rs:1395-1495`), tidak ada jalur
   produksi yang menambah note, view key auditor masih pekerjaan terbuka
   (`specs/confidential_assets.md:461-466`). APS tetap satu-satunya jalur transfer privat.
   Reset chain tidak mengubah ini.
2. **Leg pendamping tetap wajib untuk transfer satu aset.** `MIN_LEGS_V1 = 2`, maksimal satu leg
   per dataspace (`settlement_validation.rs:117-123,156-157`), amount 0 ditolak
   (`nexus/private_settlement.rs:1820`). Payer == recipient diterima (sudah terbukti live:
   BI→BI).
3. **Satu dataspace boleh punya beberapa pool.** Keunikan hanya per (route, pool_id)
   (`private_settlement/global_state.rs:455-485`); aset hanya muncul sebagai
   `asset_binding_commitment` yang di-salt (`nexus/private_settlement.rs:230-283`). APS tidak
   membaca `AssetDefinition` maupun homing-nya (`atomic_private_settlement/relation.rs:210-216`).
   Dua leg dengan aset sama di dua dataspace diperbolehkan.
4. **Yang tetap publik di V1** (spec:59-73, docs:25-40): timing, jumlah peserta, identitas
   dataspace, aktivitas per pool stabil, sponsor, fee, nomor leg reimbursement
   (`reimbursement_leg_ordinal`). Ini batas protokol, bukan target desain.
5. **Riwayat publik tidak bisa dihapus tanpa genesis baru**: pool lama sudah berlabel lewat
   riwayat dan nama dataspace ("Rupiah Digital dataspace", `network/nexus.toml:41-53`), dan
   nilai tidak bisa dipindah antar pool. Karena itu D1 butuh reset chain.

## 3. Pendekatan yang dipertimbangkan

| | Isi | Kelebihan | Kekurangan |
|---|---|---|---|
| **A (dipilih)** | Genesis baru + 4 pool + driver diperbaiki (D1-D5) + kualifikasi (D6) | Satu-satunya yang benar-benar menutup D1; semua penyimpangan ditangani | Reset chain: saldo dan riwayat hilang; 3-5 hari kerja |
| B | D3+D4+D5 di chain sekarang + pool tambahan | Tanpa reset, ~1-2 hari | D1 tidak efektif (pool lama berlabel) |
| C | D3+D4 saja, D1/D2 dicatat | ~1 hari | D1 tetap terbuka |

User memilih A (2026-11-16).

## 4. Desain

### 4.1 Jaringan dan genesis (reset)

- Validator, kunci peer, topologi, image node `071e281e`, cadence 1000 ms tetap sama. Hanya
  genesis dan state yang diganti (pola `~/agent-texts/iroha/netreset.sh`, 2026-11-13).
- **Nama netral**: dataspace `ds-1` dan `ds-2`, lane `lane-1`/`lane-2`, deskripsi netral
  ("private settlement dataspace 1/2"). Tidak ada kata RD/DFABI/Rupiah di catalog, routing,
  metadata manifest atau domain yang tampil publik.
- **Aset publik RD dan DFABI** tetap seperti sekarang (DataspaceRestricted di satu dataspace,
  dipakai jalur native/transparan saja). APS tidak bergantung pada homing ini (fakta 2.3).
- **Akun sponsor netral** `sponsor` didaftarkan di genesis: kunci sendiri (bukan kunci
  validator, governance, auditor, atau wallet BI), saldo XOR untuk fee. Izin
  `CanReadRestrictedDataspace` hanya di-grant bila gerbang G2 (bagian 6) membuktikan perlu;
  izin ini genesis-only (`iroha_core/src/executor.rs:8225-8233`).
- APS: `[nexus.atomic_private_settlement]` sama seperti sekarang (`activation_height = 11`,
  timeout 1200, expiry 7200). Notice 10 blok dipertahankan untuk PoC dan dicatat sebagai
  deviasi dari contoh docs (7200), yang docs sebut bukan rekomendasi.

### 4.2 Empat pool

- Pool: (ds-1, RD), (ds-1, DFABI), (ds-2, RD), (ds-2, DFABI). `pool_id` dan salt acak.
- **Aktivasi: satu transaksi per dataspace**, masing-masing berisi pool RD dan DFABI dataspace
  itu dengan urutan instruksi diacak; kedua transaksi dikirim berurutan acak, setelah blok
  aktivasi APS. Aktivasi lintas dua dataspace dalam satu transaksi (pola localnet upstream)
  menggantung di cluster ini sebagai NativeAmx tanpa lane payload (`driver/src/aps.rs:275-278`);
  aktivasi yang terbatas pada satu dataspace mempertahankan route lokal (spec:364-373), jadi
  pembagian per dataspace tidak membedakan aset. Tidak boleh pola "RD dulu, lalu DFABI".
- Semua pool memakai **set auditor yang sama** (BI saja, `min_approvals = 1`) dan kebijakan
  dengan bentuk identik, supaya `audit_policy_digest` tidak membedakan aset.
- Cadangan origin BI: suplai RD dan DFABI dibagi ke dua pool masing-masing aset (porsi: lihat 7).

### 4.3 Driver: pemilihan pool dan leg

- `PoolFile` diganti indeks per (dataspace, aset). Wallet dan saldo diagregasi lintas pool
  per aset; `/aps/wallet` dan `/aps/bundles` mengembalikan total per aset dan baris per bundle
  seperti sekarang (kontrak API Lensa tidak berubah kecuali label pool, 4.6).
- **Bentuk bundle** (leg diurutkan kanonik per dataspace, jadi leg 0 = ds-1):
  - **DvP / award**: satu leg RD dan satu leg DFABI; dataspace untuk leg RD dipilih acak di antara
    dataspace yang pool RD-nya punya note pembayar yang cukup, DFABI di dataspace lainnya (juga
    harus mencukupi).
  - **Transfer/issuance satu aset X**: leg asli X (payer → recipient) di satu dataspace, dan
    **leg pendamping X BI → BI 1 unit di dataspace lain**. Aset pendamping = aset yang sama,
    sehingga route dan pasangan pool tidak membedakan transfer RD dari transfer DFABI.
    Dataspace leg asli dipilih acak di antara yang mencukupi.
  - Bila hanya satu susunan yang mencukupi, pakai itu (pilihan acak dibatasi saldo; dicatat
    sebagai sisa kebocoran statistik).
  - **Saldo terpecah** (keputusan Claude): nilai tidak bisa pindah antar pool, dan satu leg hanya
    membelanjakan maks 2 note dari satu pool (`wallet.rs pick_notes`). Bila tidak ada satu pool
    yang mencukupi tetapi total dua pool cukup, transfer satu aset dipecah menjadi **dua leg asli**
    payer → recipient (satu per dataspace, masing-masing ≥ 1), tanpa leg pendamping. Bentuknya
    tetap "dua leg aset sama", jadi tidak membedakan aset. DvP yang tidak punya susunan cukup
    ditolak sebelum proving dengan pesan yang jelas di Lensa.
  - **Penerbitan menjaga keseimbangan**: issuance BI ke bank memilih pool aset itu yang saldo bank
    di dalamnya lebih kecil, supaya saldo tiap bank tetap kira-kira 50/50 per dataspace.
- **Reimbursement sponsor** tetap di leg 0 (`reimbursement_leg_ordinal = 0`, publik), dibayar
  **dalam aset leg 0**, nilai 1 unit terkecil aset itu. Aturan auditor menerima reimbursement
  1 unit RD atau 1 unit DFABI. Fee carrier publik tetap dibayar sponsor dalam XOR.
- Yang menanggung reimbursement = pembayar leg 0 (bila leg 0 = pendamping, BI yang menanggung).

### 4.4 Sponsor netral (D3)

- Driver koordinator (BI) memakai **kunci sponsor terpisah** (Secret sendiri) untuk semua peran
  yang upstream wajibkan dipegang `manifest.sponsor`: upload, availability share, Prepare/Commit
  vote, sertifikat fase, registrasi Prepare, carrier final/abort, dan otorisasi view key output
  reimbursement (`iroha_torii/src/private_settlement.rs:1162-1951`, `relation.rs:518-538`).
- Kunci governance BI hanya untuk `pool-init`. Kunci wallet BI hanya untuk leg BI.
- Output reimbursement memakai **note key milik sponsor** (bukan `NoteKeys::random()`), sehingga
  reimbursement bisa dibelanjakan dan tidak ada nilai yang terbakar.

### 4.5 Koordinator restart-safe dan alur sesuai docs (D4, D5)

- Ganti `prepare_private_settlement_bundle_v1` dengan
  `recover_or_prepare_private_settlement_bundle_v1` (client:1870); commit tetap
  `recover_or_commit_…` (client:2138).
- **State koordinator durable** di PVC: per bundle simpan manifest, delta, katalog authority,
  leg yang sudah disiapkan (proof terenkripsi), fase terakhir. **Tanpa witness, kunci, atau
  plaintext** (docs:131-134, 268-271). Saat start, driver melanjutkan setiap bundle tak-terminal:
  baca status publik; bila belum final, ambil sertifikat dari node lewat `recover_or_*`
  (tidak pernah dari cache lokal), lanjutkan sampai final atau expiry/abort.
- Upload mengikuti `certify_and_upload_private_settlement_legs_v1`: gagal hanya bila node yang
  ikut menandatangani sertifikat availability menolak upload.
- `max_carrier_bytes` dibaca dari nilai governed aktif, bukan konstanta V1.
- Receipt final dicocokkan dengan manifest yang diharapkan; cache receipt lokal hanya dipakai
  bila hash receipt cocok dengan status bundle yang dibaca dari kuorum node (kalau tidak,
  cache dihapus).
- Committee diambil dari state chain pada `authority_context_height`, bukan `peers.json`
  (`peers.json` hanya untuk alamat endpoint).

### 4.6 Lensa (frontend)

- Label pool di lensa: "Pool 1/2 (ds-1/ds-2)" tanpa nama aset untuk pihak luar; pihak
  transaksi dan BI tetap melihat aset dari note/capsule mereka.
- Saldo dan riwayat tetap dari `/aps/wallet` (teragregasi oleh driver). Adapter Lensa juga
  membaca `pools.json` langsung (`server/src/adapters/iroha3.ts:477-483`) dan menampilkan fee hanya
  di baris RD; keduanya disesuaikan ke indeks pool baru dan fee di aset leg 0.
- Penggantian state Lensa (`iroha3.json`) untuk chain baru; tidak ada perubahan model lain.

### 4.7 Kualifikasi yang dijalankan sendiri (D6)

- **Latensi**: 5 pemanasan + 30 bundle terukur untuk tiap flow (rd-issue, rd-transfer,
  dfabi-transfer, dvp, award) di chain baru; laporkan p50/p95/p99 dan interval kepercayaan,
  CPU/memori, ukuran proof/receipt. Jumlah peserta hanya N=2 (kita punya 2 dataspace privat);
  N=3/4/8/16 dari docs dicatat sebagai tidak dijalankan. Saldo awal bank dibuat cukup untuk
  seluruh 30+5 bundle per flow tanpa top-up di tengah.
- **Restart/fault**: restart validator (1 dari 4) di tengah bundle; restart driver koordinator
  saat fase upload, Prepare, Commit; restart driver bank saat proving. Lulus bila setiap
  bundle berakhir final atau abort/expiry bersih, tanpa saldo parsial (cek 4 pihak).
- **Kebocoran (canary)**: jalankan bundle dengan nominal dan akun canary, lalu pindai log semua
  pod, respons Torii publik, blok/receipt dan tampilan Lensa untuk pihak luar; tidak boleh ada
  nominal, akun, atau nama aset dalam plaintext.
- Hasil disimpan di `reports/aps-qualification-<tanggal>.md` beserta commit, image digest,
  dan deskripsi hardware.

## 5. Bukan tujuan

- Review kriptografi independen, artifact DOI, build reproducible bersertifikat, pengujian
  message loss 5/10/20% terautentikasi, dan N>2 dataspace (docs:273-302). Dicatat di laporan
  sebagai gerbang eksternal yang belum dipenuhi; fitur tetap "not production-qualified".
- Menyembunyikan timing, jumlah peserta, aktivitas pool (batas V1).
- Mengganti upstream commit atau parameter konsensus (cadence tetap 1000 ms).

## 6. Anti-tujuan dan gerbang

Anti-tujuan (gagal walau "jalan"):
- Plaintext nominal, akun, aset, witness, atau kunci muncul di log, metrik, event, respons
  Torii/driver untuk pihak luar, atau di state koordinator durable.
- Bundle menggantung tanpa terminal setelah restart koordinator.
- Pola deterministik yang mengikat pool ke aset (urutan aktivasi, leg 0 selalu RD,
  deskripsi/alias, digest kebijakan berbeda).
- Kembalinya mutex global yang menyerialkan bukti leg (perbaikan node-build #43).

Gerbang sebelum reset (dijalankan di chain SEKARANG, tanpa mengganggu pool lama):
- **G1 spike**: aktifkan pool RD tambahan di `ds-dfabi`, jalankan satu transfer RD dengan leg
  asli di ds-rd dan pendamping RD BI→BI di ds-dfabi, lalu satu bundle dengan leg 0 = DFABI
  (reimbursement 1 DFABI). Lulus = final, saldo tepat, auditor menyetujui.
- **G2 sponsor**: daftarkan akun sponsor di chain sekarang, jalankan satu bundle dengan sponsor
  itu, catat apakah polling status butuh `CanReadRestrictedDataspace`. Hasil menentukan genesis.
- **G3 restart**: bunuh driver koordinator di tengah Prepare dengan versi `recover_or_prepare`
  + state durable; bundle harus dilanjutkan sampai final.
- **G4 aktivasi**: aktifkan pool tambahan RD+DFABI di satu dataspace dalam satu transaksi di chain
  sekarang (sekaligus memenuhi G1); harus final dalam satu blok.
- Bila salah satu gerbang gagal: berhenti, laporkan ke user dengan bukti; tidak ada fallback
  otomatis ke pendekatan B/C.
- Reset baru dijalankan setelah G1-G4 lulus dan **snapshot disk** diambil untuk semua PVC
  peer, driver dan auditor di kedua cluster lewat CSI `VolumeSnapshot` (class
  `alibabacloud-disk-snapshot`, ada di kedua cluster), saat peer sudah dihentikan untuk reset.
  DeletionPolicy class = Delete, jadi objek `VolumeSnapshot` tidak dihapus sampai chain baru
  lulus kualifikasi. Rollback = restore PVC dari snapshot + genesis lama.

## 7. Diserahkan ke builder (keputusan Claude, bisa dikoreksi user)

- Porsi pembagian cadangan origin per pool (usul: 50/50).
- Algoritma acak pemilihan dataspace (usul: acak seragam di antara susunan yang mencukupi).
- Format file state koordinator (usul: satu file per bundle di PVC `pools-v2`, ditulis atomik).
- Saldo awal bank setelah reset (usul: sama dengan saldo per 2026-11-16 12:40Z, dibulatkan).
- Urutan dan pembagian PR (node-build driver, iroha3 network/deploy, frontend).

## 8. Dampak operasional

- Downtime iroha3 di Lensa selama reset dan re-funding (perkiraan 1-2 jam); model lain di Lensa
  tidak terganggu. Sesi lain (besu, fabricx) dikabari sebelum reset; Lensa roll lewat koordinasi
  lock seperti biasa.
- Semua saldo dan riwayat iroha3 hilang; riwayat lama hanya tersisa di snapshot.
