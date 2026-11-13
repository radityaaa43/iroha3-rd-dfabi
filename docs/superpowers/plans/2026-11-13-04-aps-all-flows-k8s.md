# Iroha 3: semua flow Lensa lewat APS di k8s per-org — Implementation Plan

Tanggal: 2026-11-13. Diminta user: "buatlah plan untuk keseluruhan task masing-masing. lalu kembangkan menggunakan multi sub
agent paralel". Melanjutkan spek `specs/2026-11-10-iroha3-aps-all-flows-design.md` (tujuan R1: hanya pengirim, penerima, BI
melihat transaksi; node bank lain tidak menyimpan plaintext). Plan `2026-11-10-03-aps-all-flows.md` mengasumsikan satu proses
di host memegang kunci semua pihak; plan ini menggantikan bagian deployment-nya untuk stack k8s per-org.

## 1. Masalah yang diselesaikan

Fakta live 2026-11-13 (blok 289):
- Flow Lensa (`/mint`, `/settle-grant`, `/dvp-native`, `/transfer`) adalah tx publik di ds-rd. Payload lane dikirim ke semua
  validator (`iroha_core/src/sumeragi/v2_lane_work.rs:12067-12079`, `frozen_validator_set()`), jadi node bank lain menyimpan
  pihak, aset, dan nominal. R1 gagal di level node.
- APS (pool RD `7e4083ee…`, DFABI `e6020710…`) sudah aktif. `pay` BI→BI sudah final live 5 kali (G1b, G2 terbukti).
- Driver menyusun bundle dalam satu proses yang memegang secret pembayar DAN penerima:
  - `pools.rs:348,390` `cfg.note_keys(&leg.recipient)`;
  - `aps.rs` `prepare_leg_to` menandatangani view-key authorization output 0/1/2 dengan KeyPair penerima, pembayar, dan
    sponsor (`for (index, signer) in [recipient, payer, sponsor_key]`).
  Di k8s, tiap bank memegang `<p>.seed` dan `<p>.note` di namespace-nya sendiri, jadi hanya BI→BI yang bisa jalan.

## 2. Desain: leg dibelah per pemegang kunci

`PrivateSettlementAuditViewKeyAuthorizationBodyV1` (iroha `crates/iroha_data_model/src/nexus/private_settlement.rs`
`output_view_key_authorization_body`) hanya berisi: network_id, bundle_id, leg_ordinal, route, output_ordinal, role,
authorized_account, recipient_view_key, output_active, note_spending_authority, expiry_height. Tidak ada nilai dan commitment,
jadi tiap pemilik output bisa menandatangani SEBELUM proving tanpa melihat leg:

| Output | Ditandatangani oleh | Di mana |
|---|---|---|
| 0 SettlementRecipient | akun penerima | driver penerima, `POST /aps/address` |
| 1 PayerChange + payer signature | akun pembayar | driver pembayar, `POST /aps/leg` (proving di sini) |
| 2 SponsorReimbursement | akun sponsor (BI) | driver koordinator BI |

**Koordinator = driver BI saja.** Alasannya:
- pool serial (`old_root` harus sama dengan root kini), dan satu koordinator berarti satu mutex;
- BI sudah auditor online (R2 dikecualikan untuk iroha);
- R1 mengizinkan BI melihat semua transaksi.

Bank tidak pernah memegang secret pihak lain. BI tidak pernah memegang secret bank.

### Kontrak wire (JSON; field norito = base64 dari `aps::enc`/`aps::dec`; hex = lowercase)

Semua driver (party side):
- `POST /aps/intent` (Lensa → driver sendiri). Menyimpan persetujuan one-shot untuk leg yang dibayar pihak ini.
  - Body: `{"intent":"<64hex>","asset":"rd"|"dfabi","to":"<public key ed0120…>","amount":"<u128 string>"}`.
  - Disimpan in-memory dengan TTL 15 menit (restart = Lensa mengulang). Intent yang sama dengan terms berbeda → 409.
  - Jawaban: `200 {"intent":…}`.
- `POST /aps/address` (koordinator → driver penerima).
  - Body: `{"bundle_id":"<64hex>","pool_id":"<64hex>","leg_ordinal":0|1,"route":"<norito>","expiry_height":N,"network_id":"<norito>"}`.
  - Driver menurunkan `note_keys(self).one_time(bundle,pool,0)` dan menandatangani body otorisasi output 0 dengan seed
    akunnya. Jawaban: `{"authority":"<64hex>","view_public":"<64hex>","authorization":"<norito PrivateSettlementAuditViewKeyAuthorizationV1>"}`.
  - Tidak membutuhkan intent: menerima uang tidak memindahkan dana pihak ini.
- `POST /aps/leg` (koordinator → driver pembayar).
  - Body: `{"intent":"<64hex>","ordinal":0|1,"manifest":"<norito AtomicPrivateSettlementV1>","authority_digest":"<64hex>","salt":"<64hex>","recipient":"<public key>","amount":"…","recipient_output":{"authority","view_public","authorization"},"sponsor_output":{"authority","view_public","authorization","active":bool}}`.
  - Driver mencocokkan intent tersimpan (aset dari pool leg, `to` == recipient, amount sama), lalu MENGONSUMSINYA (one-shot,
    juga bila proving gagal). Kemudian ia memindai note sendiri, memilih note, mem-prove leg, dan menjawab
    `{"prepared":"<norito AtomicPrivateSettlementPreparedLegV1>"}`.
  - Ketidakcocokan → 403 tanpa proving.
- `GET /aps/wallet` (Lensa → driver sendiri). Mengembalikan `wallet_json` milik pihak ini (format `pools::wallet`).

Driver BI saja (`[aps] coordinator = true`):
- `POST /aps/submit` (driver pihak mana pun → BI, juga Lensa BI → driver BI).
  - Body: `{"kind":"pay","intent":…,"asset":…,"from":"<pk>","to":"<pk>","amount":…}` atau
    `{"kind":"dvp","intent_rd":…,"intent_dfabi":…,"buyer":"<pk>","seller":"<pk>","rd":…,"dfabi":…}`.
  - Koordinator memegang mutex global. Langkahnya:
    1. Membangun manifest.
    2. Untuk tiap leg: meminta `/aps/address` ke penerima, menyiapkan dan menandatangani output 2 sponsor, lalu meminta
       `/aps/leg` ke pembayar.
    3. Leg pendamping BI→BI 1, atau leg yang dibayar BI, di-prove lokal tanpa HTTP.
  - Setelah itu `aps::settle` yang sudah ada dijalankan (audit quorum, prepare, commit). Jawaban:
    `{"outcome":"finalized"|"aborted","bundle_id","carrier_tx","height"}`.
  - Waktu: sekitar 100–200 s. Envoy route timeout 600 s.
- Driver bank, `POST /aps/submit` dari Lensa-nya: driver meneruskan body apa adanya ke gateway BI (`[aps] coordinator_url`,
  mTLS dengan leaf driver, CN = role) dan mengembalikan jawabannya.

Peta flow Lensa:

| Flow | Intent di | Submit oleh |
|---|---|---|
| issuance RD/DFABI BI→X | BI (leg BI) | Lensa BI |
| transfer X→Y | X | Lensa X |
| award BI jual DFABI ke X | X (RD X→BI) + BI (DFABI BI→X) | Lensa BI (`dvp`, buyer X, seller BI) |
| dvp X jual DFABI ke Y | Y (RD) + X (DFABI) | Lensa X (seller) |

### Route gateway (OPA package iroha3, `deploy/gateway/policy/iroha3.rego`)

| Row | Route | Role | Node |
|---|---|---|---|
| 16 | `POST /aps/intent`, `POST /aps/submit`, `GET /aps/wallet` | lensa | semua |
| 17 | `POST /aps/address`, `POST /aps/leg` | bi | semua |
| 18 | `POST /aps/submit` | bank-a, bank-b, bank-c | bi saja |

Role `bi` adalah leaf driver BI (CN `bi`, role CA BI), sudah dipakai di row 15.

## 3. Task (paralel; tiap task = branch + PR sendiri, RED commit dulu, CI hijau, TIDAK merge oleh agent)

### T1 node-build: leg terbelah (library)

Branch `feat/aps-split-leg`. File: `driver/src/aps.rs`, file baru `driver/src/aps_split.rs`.
- `pub struct OutputKey { authority: [u8;32], view_public: [u8;32], authorization: PrivateSettlementAuditViewKeyAuthorizationV1, active: bool }`.
- `pub fn sign_output_key(signer: &KeyPair, ctx: &OutputCtx, output_ordinal: u8, role, keys: &NoteKeys, active: bool) -> Result<OutputKey>`.
  `OutputCtx { network_id, bundle_id, leg_ordinal, route, expiry_height }`; body dibangun persis seperti upstream
  `output_view_key_authorization_body`.
- `pub fn prepare_leg_split(ordinal, leg: &LegPayer { lane, asset, payer: KeyPair, recipient: PublicKey, amount }, governed, spend: Spend, change: &NoteKeys, recipient_output: &OutputKey, sponsor_output: &OutputKey, sponsor: &PublicKey, manifest, authority_digest, salt) -> Result<AtomicPrivateSettlementPreparedLegV1>`.
  Hanya memakai secret pembayar. Authorization output 0 dan 2 dipakai apa adanya.
- `prepare_leg_to` lama dibangun ulang di atas `prepare_leg_split`, supaya jalur CLI `pay`/`dvp` tetap satu kode.
- Tes RED:
  - `split_leg_needs_no_foreign_secret`: tanda tangan fungsi tidak menerima KeyPair penerima/sponsor; leg terbelah lolos
    `validate` upstream yang dipakai `settle`/`provisional_materials`.
  - `output_key_body_matches_upstream`: body buatan kita == `plaintext.output_view_key_authorization_body(i)`.
  - `a_foreign_authorization_is_refused`: authorization output 0 yang ditandatangani akun lain → error sebelum proving.

### T2 node-build: endpoint HTTP dan koordinator

Branch `feat/aps-http`. File: `driver/src/server.rs`, file baru `driver/src/aps_http.rs`, `driver/src/config.rs`
(`[aps] coordinator = bool`, `coordinator_url = "https://…:8443"` opsional).
- Implementasi kontrak §2 (intent store dengan TTL, `/aps/address`, `/aps/leg`, `/aps/wallet`, `/aps/submit`) di balik trait
  `ApsBackend` (prove, address, settle, wallet) dan `Peer` (HTTP ke driver lain lewat `tls_http`), supaya routing, validasi,
  intent one-shot, dan mutex bisa dites tanpa chain dan tanpa T1. Implementasi nyata trait memanggil API T1 dan bisa
  menyusul setelah T1 merge (`todo!()` dilarang: pakai stub yang mengembalikan error eksplisit `"split leg not wired"`).
- Tes RED (unit, fake backend):
  - intent one-shot;
  - intent terms berbeda → 409;
  - `/aps/leg` tanpa intent → 403 dan tidak ada proving;
  - `/aps/submit` di driver non-koordinator diteruskan ke `coordinator_url`;
  - dua submit bersamaan di koordinator berjalan serial;
  - body salah → 400;
  - route tak dikenal tetap 404;
  - jawaban tidak pernah memuat isi `.seed` atau `.note`.

### T3 dfabi: deploy

Branch `feat/aps-k8s`. File: `deploy/driver/render.py`, `deploy/gateway/render.py`, `deploy/gateway/policy/*`,
`scripts/check-*.py`, test scripts.
- Driver render flag `--aps`:
  - `[aps]` di `rd-dfabi.toml` (`coordinator = true` hanya untuk bi; bank: `coordinator_url = "https://gateway.rd-iroha3-bi.svc.cluster.local:8443"`;
    bank-c memakai IP gateway-lb BI lewat `--remote-gw` yang sudah ada);
  - `pools_file` = ConfigMap `aps-pools` (render dari `pool_init_json` + pool record yang dibutuhkan `PoolFile::load`; cek
    field di node-build `pools.rs` `PoolRecord`);
  - memory request/limit 2Gi/3Gi (prover peak RSS ~1.1 GiB terukur);
  - driver BI: native sidecar `gw-tls` loopback 18101-18104 ke 4 Torii lewat gateway (pola `deploy/aps-run`), karena
    `settle` memakai klien iroha HTTP polos ke 4 committee endpoint;
  - NetworkPolicy egress driver: bank → gateway BI :8443; BI → semua gateway :8443.
- Envoy: route `/aps/` ke driver dengan timeout 600 s.
- OPA row 16–18 + `opa test`: allow dan deny per role, per node, per method.
- Checker render dan test mutasi diperbarui, seperti #76/#77.

### T4 frontend (rd-lensa-frontend): adapter mode APS lewat driver

Branch `feat/iroha3-aps-driver`. File: `server/src/adapters/iroha3-driver.ts`, `server/src/adapters/iroha3.ts`, tests vitest.
- `DriverClient` bertambah `apsIntent`, `apsSubmit`, `apsWallet`.
- Mode `driver` + konfigurasi `aps: true`: semua flow sesuai tabel §2. Intent id 32 byte acak per flow. Untuk DvP/award,
  intent dua pihak dikirim lebih dulu ke driver masing-masing, lalu submit oleh pihak sesuai tabel.
- Saldo dari `GET /aps/wallet`, bukan `/balance`.
- Timeout klien 660 s.
- Lens BI dari `/records` yang sudah ada.
- Tes RED: tiap flow memanggil endpoint yang benar di party yang benar dan urutannya benar (intent sebelum submit); saldo
  dari wallet; error 403/409 diteruskan dengan jelas.

### T5 integrasi dan live (lead, bukan agent; berurutan setelah T1–T4 merge)

1. Wire trait T2 ke API T1. PR kecil, RED: `prove-split-selftest` offline.
2. Build image (GitHub Actions). Ambil digest dari baris "pull by digest".
3. **Gate user: policy auditor.** 2-of-3 (bi, bank-a, bank-b) membuat auditor bank-a dan bank-b membaca SEMUA leg (R1
   bocor). Pilihan BI-saja butuh pool baru dengan pool-init baru (irreversible). Keputusan user sebelum langkah 4.
4. Roll per party, fail-stop, rollback file:
   - render dari commit dfabi yang sudah merge;
   - OPA dan envoy (`gw-opa.sh`, `gw-envoy.sh`);
   - driver (`d1.sh`).
5. Live semua skenario lewat APS: issuance, award, transfer, DvP. Cek per fase:
   - saldo wallet tiap pihak bergeser persis;
   - bank pihak ketiga tidak melihat apa pun (wallet-nya tidak berubah; `GET /tx` publik tidak ada);
   - tx publik yang terbit hanya carrier APS.

## 4. Aturan untuk semua agent

- TIDAK menyentuh cluster: tanpa kubectl, tanpa port-forward, tanpa tx chain. Tidak membaca Secret atau kunci.
- Tidak build image atau deploy di host. Rust dicek lewat CI `driver-test` (push branch, `gh run watch`). Python, OPA, dan
  vitest boleh dijalankan lokal.
- TDD: commit RED (tes gagal) dulu → push → CI merah → commit GREEN → CI hijau. PR terbuka, TIDAK merge.
- Perubahan minimal, ikuti gaya kode yang ada, komentar menyebut sumber (`file:line` upstream @071e281e).
- Kunci dan secret tidak pernah dicetak di log atau jawaban HTTP.
