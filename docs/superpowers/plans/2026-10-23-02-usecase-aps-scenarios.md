# Skenario Use Case RD/DFABI dengan APS — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Menjalankan dan membuktikan skenario RD/DFABI privat (penerbitan, DvP, redemption, kegagalan, replay, audit BI, resiliensi) di jaringan 4 party memakai `AtomicPrivateSettlementV1`, dengan hasil PASS/FAIL dan bukti per skenario.

**Architecture:** Satu binary Rust `rd-dfabi` berperan sebagai wallet bank, coordinator, sponsor, dan auditor BI. Ia memanggil fungsi wallet/prover `iroha_core` dan client `iroha` @ `071e281e`, mengikuti test upstream `atomic_private_settlement_localnet.rs`. Wallet tiap bank disimpan di PVC miliknya. Auditor BI berjalan sebagai Deployment `bi-auditor`, terpisah dari node BI. Skenario dijalankan sebagai k8s Job lewat workflow di runner `iroha3`.

**Tech Stack:** Rust 1.93.1, crate `iroha`/`iroha_core`/`iroha_data_model` (git, rev `071e281e`), `clap`, `serde`/`toml`, GitHub Actions, Kubernetes Jobs.

**Spec:** `docs/superpowers/specs/2026-10-23-iroha3-aps-rd-dfabi-design.md`
**Prasyarat:** `docs/superpowers/plans/2026-10-23-01-network-setup.md` selesai sampai gate G1b PASS.

## Revisi 2026-11-09 (disetujui user, item (b))

Kajian kode upstream @ `071e281e` mengubah bentuk Task 2–9. Yang berlaku sekarang:

- **Tanpa wipe.** Aktivasi pool adalah transaksi runtime biasa (butuh `CanEnactGovernance`, dipegang
  akun operator). Pool tidak memeriksa aset: id aset hanya commitment yang dibuka auditor. DFABI tetap
  aset genesis yang sama, legnya jalan di lane/dataspace 2.
- **Satu pool baru per leg.** Wallet upstream hanya punya Merkle path untuk pool yang baru diaktifkan dengan
  tepat 2 note (`wallet.rs:750-760`). Jadi setiap DvP mengaktifkan 2 pool tepat sebelum proving; note asal
  di pool itu adalah "penerbitan" ke payer. Saldo publik RD/DFABI tidak bergerak. `NoteStore` (Task 3)
  dan saldo wallet antar-skenario tidak dibuat: note hasil terima tidak bisa dibelanjakan ulang.
- **Task 2 sudah selesai di genesis** (capability `IrohaIvmPrivateNoteStarkV1` Active sejak height 1).
- **S5 = FAIL (keterbatasan upstream)**: tidak ada API publik untuk Merkle path note generasi kedua.
- **Auditor**: Torii tidak punya route "pending legs". `bi-auditor` menerima `POST /approve` (governance,
  policy, payload digest) dari coordinator di dalam cluster (NetworkPolicy: hanya pod coordinator),
  lalu sendiri mengambil capsule, mendekripsi, menilai aturan, dan submit approval.
- **Build**: source driver dan workflow build ada di repo public `radityaaa43/iroha3-rd-node-build`
  (`driver/`, GitHub-hosted runner, image `ghcr.io/radityaaa43/iroha3-rd-driver:<sha8>`). Repo ini hanya
  berisi deploy: `deploy/k8s-apps/`, `deploy/jobs/scenario.yaml`, `.github/workflows/scenario.yml`,
  `scripts/keys-init.sh`.
- **Batas resource wajib**: build lokal lewat `driver/build.sh` (cgroup 10 GiB, 1 cargo job). Build tanpa
  batas menjatuhkan VM operator dua kali (2026-11-09). Job prover: request = limit (Guaranteed QoS),
  ukuran dari `prove-selftest` (peak RSS), tanpa priorityClass (tidak bisa preempt validator).
- **Residual PoC**: seed wallet keempat party ada di satu Secret yang dipasang ke Job coordinator (bukan
  wallet per bank); coordinator memakai akun operator bersama sebagai sponsor.

Urutan jalan: `selftest` → `scripts/keys-init.sh` → `auditor` → `s1-dvp` → `s2a-insufficient` →
`s2b-audit-reject` → `s3-replay` → `s4-redeem` (semua `gh workflow run scenario.yml -f target=...`).

## Global Constraints

- Semua prasyarat Global Constraints plan setup berlaku.
- Dependency Iroha: `git = "https://github.com/hyperledger-iroha/iroha", rev = "071e281e778c5928cab4d6e007b7ddc9b050df27"`, feature `zk-stark` di `iroha_core`.
- Dataspace: RD di `ds-rd` (id 1), DFABI di `ds-dfabi` (id 2). Carrier global di lane 0 `universal`.
- Auditor: BI satu-satunya auditor di kedua policy, `min_approvals = 1`.
- Party: `bi`, `bank-a`, `bank-b`, `bank-c`. Saldo awal dummy: RD `1000` untuk tiap bank dan `10000` untuk `bi`; DFABI `100` untuk `bank-b` dan `bank-c`, dan tidak ada untuk `bank-a` maupun `bi`.
- Kunci wallet (spending secret, view key) dan kunci auditor (signing + hybrid encryption) hanya di Secret/PVC party pemiliknya. BI tidak pernah menerima spending secret bank.
- Plaintext transaksi (amount, pihak, memo, witness) tidak boleh muncul di log Job, event, atau output workflow. Log hanya bundle id, tx hash, waktu, dan status.
- Image driver: `ghcr.io/radityaaa43/iroha3-rd-driver:<git-sha8>`.
- Scope sama dengan track lain: skrip dan flow, tanpa backend aplikasi. `bi-auditor` adalah bagian protokol APS (peran auditor), bukan backend.

## Review Focus

- Leg yang di-approve auditor lalu diubah coordinator (amount atau penerima beda) → harus ditolak saat Prepare. Approval terikat digest capsule, delta, dan proof (Task 6, S3b).
- `bi-auditor` restart di tengah bundle → approval tidak dobel dan bundle tetap selesai atau abort bersih (Task 4, test idempotensi).
- Bank C meminta capsule lewat Torii → harus ditolak (route auditor-only) (Task 5, cek leakage).
- Wallet bank menulis note store lalu Job mati sebelum commit → saldo wallet tidak boleh berubah sampai receipt final terlihat (Task 3, note store dua fase: `pending` → `confirmed`).
- Amount melebihi saldo wallet → driver menolak sebelum proving (Task 6, S2a).

---

### Task 1: Kerangka driver `rd-dfabi` dan image

**Files:**
- Create: `apps/rd-dfabi/Cargo.toml`, `apps/rd-dfabi/src/main.rs`, `apps/rd-dfabi/src/config.rs`
- Create: `apps/rd-dfabi/config.example.toml`
- Create: `apps/rd-dfabi/Dockerfile` (base: `rust:1.93.1-slim-bookworm` → `debian:bookworm-slim`, uid 1001)
- Create: `.github/workflows/build-driver.yml` (runner GitHub, push ke GHCR)

**Interfaces:**
- Produces: `rd_dfabi::config::Config::load(path: &Path) -> anyhow::Result<Config>` dengan field `chain_id: String`, `torii: BTreeMap<Party, Url>`, `party: Party`, `key_dir: PathBuf`, `wallet_dir: PathBuf`, `dataspaces: Dataspaces { rd: u32, dfabi: u32 }`.
- Produces: `enum Party { Bi, BankA, BankB, BankC }` dengan serde `kebab-case` (`"bi"`, `"bank-a"`, …).
- Produces: subcommand CLI: `capability activate`, `keys init`, `pool activate`, `wallet show`, `auditor run`, `dvp`, `audit report`.

- [ ] **Step 1: Test** `config_loads_example` (memuat `config.example.toml`, assert `party == Party::BankA`, `dataspaces.rd == 1`, `dataspaces.dfabi == 2`) dan `party_rejects_unknown` (`"bank-d"` → error).
- [ ] **Step 2:** `cargo test -p rd-dfabi config` → FAIL.
- [ ] **Step 3:** Implementasi `Config`, `Party`, skeleton `clap` (setiap subcommand `todo!()` kecuali `--help`).
- [ ] **Step 4:** `cargo test -p rd-dfabi config` → PASS. `docker build -f apps/rd-dfabi/Dockerfile .` → sukses, `rd-dfabi --help` tampil.
- [ ] **Step 5:** Workflow `build-driver.yml` (`timeout-minutes: 340`, bebaskan disk seperti build node) → `gh run watch --exit-status` sukses. Package dibuat public (langkah manual yang sama dengan plan setup Task 2).
- [ ] **Step 6: Commit** `feat(driver): rd-dfabi skeleton, config, image build`.

---

### Task 2: Aktivasi capability private note

**Files:**
- Create: `apps/rd-dfabi/src/capability.rs`
- Create: `deploy/jobs/capability-activate.yaml`
- Create: `.github/workflows/scenario.yml` (input `scenario`; menerapkan `deploy/jobs/<scenario>.yaml` sebagai Job, menunggu selesai, mengambil log)

**Interfaces:**
- Produces: `capability::activate_private_note(client: &Client) -> Result<u64>` mengembalikan height saat capability `IrohaIvmPrivateNoteStarkV1` berstatus Active. Ikuti `activate_ivm_private_note` + `require_genesis_private_note_active` di test upstream.

- [ ] **Step 1: Test** unit `activation_record_targets_private_note_stark` (record yang dibangun memakai protokol `IrohaIvmPrivateNoteStarkV1`).
- [ ] **Step 2–4:** FAIL → implementasi → PASS.
- [ ] **Step 5: Jalankan di cluster** `gh workflow run scenario.yml -f scenario=capability-activate` → Job sukses, log berisi `private-note capability active at height <n>`.
- [ ] **Step 6: Commit** `feat(driver): activate IVM private-note capability`.

---

### Task 3: Kunci, wallet, dan aktivasi pool RD/DFABI (penerbitan awal)

**Files:**
- Create: `apps/rd-dfabi/src/keys.rs`, `apps/rd-dfabi/src/wallet.rs`, `apps/rd-dfabi/src/pool.rs`
- Create: `deploy/jobs/pool-activate.yaml`, `deploy/k8s-apps/wallet-pvc.yaml` (PVC `wallet-<party>` 1Gi per party)
- Create: `scripts/keys-init.sh` (operator, PC: `rd-dfabi keys init` per party → Secret `wallet-<party>`, `bi-auditor-keys`)

**Interfaces:**
- Produces: `wallet::NoteStore::open(dir: &Path) -> Result<NoteStore>`; `NoteStore::balance(&self, asset: Asset) -> u128` (hanya note `confirmed`); `NoteStore::stage(&mut self, notes: Vec<OwnedNote>, bundle_id: Hash) -> Result<()>`; `NoteStore::confirm(&mut self, bundle_id: Hash) -> Result<()>`; `NoteStore::spendable(&self, asset: Asset, amount: u128) -> Result<[OwnedNote; 2]>`.
- Produces: `enum Asset { Rd, Dfabi }`.
- Produces: `pool::activate(client, governance, asset: Asset, holders: &[(Party, u128)]) -> Result<PoolId>`. Policy auditor = BI saja, `min_approvals = 1`. Origin commitment dibangun per holder dengan `plan_atomic_private_settlement_bootstrap_v1` (2 note per holder). Submit `ActivatePrivateSettlementPoolV1::from_restricted`.

- [ ] **Step 1: Test** `note_store_balance_ignores_pending`, `note_store_confirm_moves_pending`, `spendable_rejects_insufficient` (minta `1001` dari saldo `1000` → error).
- [ ] **Step 2–4:** FAIL → implementasi `NoteStore` (file JSON per note di `wallet_dir`, tulis atomik via rename) → PASS.
- [ ] **Step 5: Jalankan** `scripts/keys-init.sh`, lalu `scenario=pool-activate` (RD: bank-a/b/c `1000`, bi `10000`; DFABI: bank-b/c `100`). Lalu `wallet show` per party.
Expected: bi `RD=10000 DFABI=0`, bank-a `RD=1000 DFABI=0`, bank-b `RD=1000 DFABI=100`, bank-c `RD=1000 DFABI=100`. Wallet bank-c yang dibuka dengan view key bank-a menunjukkan `0` note (tidak bisa mendekripsi).
- [ ] **Step 6: Commit** `feat(driver): wallets and RD/DFABI pool activation (initial issuance)`.

---

### Task 4: Layanan auditor BI

**Files:**
- Create: `apps/rd-dfabi/src/auditor.rs`
- Create: `deploy/k8s-apps/bi-auditor.yaml` (Deployment 1 replika, PVC `bi-audit-store` 1Gi, Secret `bi-auditor-keys`)

**Interfaces:**
- Produces: `auditor::Rules { max_amount: BTreeMap<Asset, u128>, parties: BTreeSet<AccountId> }`; `auditor::evaluate(rules: &Rules, plain: &PrivateSettlementAuditPlaintextV1) -> Verdict` dengan `enum Verdict { Approve, Reject(&'static str) }`.
- Produces: loop `auditor run`: ambil leg yang menunggu approval → fetch capsule → dekripsi dengan kunci BI → `evaluate` → bila `Approve` panggil `approve_private_settlement_leg_v1` dan submit approval lewat Torii. Setiap plaintext disimpan ke `bi-audit-store` sebagai `<bundle_id>/<leg>.json` (O5).
- Rules default: `max_amount = {Rd: 1_000_000, Dfabi: 10_000}`, parties = 4 akun party.

- [ ] **Step 1: Test** `approves_known_parties_within_limit`, `rejects_unknown_party`, `rejects_over_limit`, `second_approval_for_same_leg_is_skipped` (idempotensi berdasarkan file di audit store).
- [ ] **Step 2–4:** FAIL → implementasi → PASS.
- [ ] **Step 5: Deploy** `kubectl apply -f deploy/k8s-apps/bi-auditor.yaml` lewat workflow → pod Ready. Log hanya berisi digest leg, tanpa plaintext.
- [ ] **Step 6: Commit** `feat(driver): BI auditor service with rule-based approval`.

---

### Task 5: S1 — DvP RD↔DFABI antarbank + uji kebocoran

**Files:**
- Create: `apps/rd-dfabi/src/dvp.rs`
- Create: `deploy/jobs/s1-dvp.yaml`
- Create: `scripts/leakage-check.sh`

**Interfaces:**
- Consumes: `NoteStore`, `pool`, `auditor` (via jaringan).
- Produces: `dvp::run(cfg, buyer: Party, seller: Party, rd: u128, dfabi: u128, sponsor: Party) -> Result<DvpReceipt>` dengan `DvpReceipt { bundle_id: Hash, tx_hash: Hash, prove_ms: [u64; 2], total_ms: u64 }`.
  Urutan per leg, mengikuti docs "Settlement workflow": prove lokal (`prove_atomic_private_settlement_v1`) → upload dan sertifikat availability 3-of-4 → tunggu approval auditor → Prepare → barrier → Commit → sponsor submit satu `FinalizeAtomicPrivateSettlementV1`. Leg 0: RD buyer→seller di `ds-rd`. Leg 1: DFABI seller→buyer di `ds-dfabi`. Gunakan varian `recover_or_*` agar Job yang di-restart bisa melanjutkan.

- [ ] **Step 1: Test** `dvp_legs_are_rd_then_dfabi_in_route_order` (urutan route kanonik), `dvp_rejects_same_buyer_and_seller`.
- [ ] **Step 2–4:** FAIL → implementasi → PASS.
- [ ] **Step 5: Jalankan** `scenario=s1-dvp` (bank-a beli `10` DFABI dari bank-b seharga `100` RD, sponsor `bi`).
Expected: receipt sukses. bank-a `RD=900 DFABI=10`, bank-b `RD=1100 DFABI=90`. Audit store BI berisi 2 plaintext yang cocok.
- [ ] **Step 6: `scripts/leakage-check.sh`** mengambil blok, event, dan `/v1/explorer/transactions` dari Torii `bank-c`, plus log pod `bank-c`, lalu mencari canary (`bank-a`, `bank-b`, account id keduanya, angka `100` dan `10` dalam bentuk Norito/JSON) di payload privat. Request `GET .../audit-capsule` dengan kredensial `bank-c` harus ditolak.
Expected: PASS. Catat metadata yang memang publik (route dataspace, jumlah leg, waktu, sponsor) sebagai residual di laporan.
- [ ] **Step 7: Commit** `feat(scenario): S1 private DvP RD<->DFABI with leakage check`.

---

### Task 6: S2 — DvP gagal tanpa perpindahan, S3 — replay

**Files:**
- Create: `deploy/jobs/s2-dvp-fail.yaml`, `deploy/jobs/s3-replay.yaml`
- Modify: `apps/rd-dfabi/src/dvp.rs` (flag `--expect-reject`, `--replay <bundle_id>`)

- [ ] **S2a:** bank-a menjual DFABI yang tidak dimilikinya → driver menolak sebelum proving (`spendable` error). Saldo tetap.
- [ ] **S2b:** auditor menolak. Rules `max_amount.Rd` sementara diturunkan di bawah amount → tidak ada approval → bundle abort setelah `audit_timeout_blocks` (atau `AbortAtomicPrivateSettlementV1` oleh sponsor). Expected: tidak ada note berubah di kedua dataspace; wallet `pending` dibuang.
- [ ] **S3a:** submit ulang carrier S1 → ditolak (nullifier atau bundle id duplikat). State tidak berubah.
- [ ] **S3b:** leg diubah setelah approval (amount berbeda) → ditolak saat Prepare.
- [ ] Setiap butir: test atau Job, hasil diverifikasi lewat `wallet show` sebelum/sesudah, lalu commit `test(scenario): S2 failure atomicity, S3 replay`.

---

### Task 7: S4 — Redemption DFABI ke BI

**Files:**
- Create: `deploy/jobs/s4-redeem.yaml`

- [ ] bank-c menjual `20` DFABI ke BI seharga `200` RD (`dvp --buyer bi --seller bank-c`). BI membayar dari note RD awalnya (Task 3).
Expected: bank-c `RD=1200 DFABI=80`, BI `RD=9800 DFABI=20`.
- [ ] Commit `test(scenario): S4 DFABI redemption to BI`.

---

### Task 8: Gate eksperimental — S5 belanja ulang note, S6 transfer RD saja

**Files:**
- Create: `deploy/jobs/s5-respend.yaml`, `deploy/jobs/s6-rd-transfer.yaml`
- Modify: `apps/rd-dfabi/src/dvp.rs` (mode `transfer`: leg RD A→B + leg DFABI A→A bernilai `1`)

- [ ] **S5:** bank-b memakai RD yang diterima di S1 untuk membeli DFABI dari bank-c. Butuh Merkle path note generasi kedua. Jika wallet upstream tidak menyediakannya, catat **FAIL (keterbatasan upstream)** dengan error persis. Jangan menulis prover sendiri.
- [ ] **S6:** bank-a mengirim `50` RD ke bank-b dengan leg pendamping DFABI bank-a→bank-a `1`. Bank-a perlu DFABI (dari S1). Jika `payer == recipient` ditolak protokol, catat FAIL dengan error persis.
- [ ] Commit `test(scenario): experimental S5 respend and S6 RD-only transfer`.

---

### Task 9: S7 — Resiliensi

**Files:**
- Create: `scripts/s7-resilience.sh`

- [ ] **S7a:** `kubectl scale sts bi --replicas=0` → jalankan DvP kecil. Expected: **sukses**, karena consensus 3/4 dan `bi-auditor` terpisah. Lalu scale `bi` ke 1 → `bi` menyusul ke height dan hash yang sama.
- [ ] **S7b:** `kubectl scale deploy bi-auditor --replicas=0` → jalankan DvP. Expected: tidak ada approval → abort setelah timeout, tidak ada perpindahan. Ini perilaku yang dikecualikan dari O2 dan dicatat sebagai **"sesuai desain APS"**. Scale kembali → DvP berikutnya sukses.
- [ ] **S7c:** restart `bi-auditor` di tengah bundle → bundle selesai sekali, tanpa approval ganda.
- [ ] Commit `test(scenario): S7 BI node and auditor resilience`.

---

### Task 10: Laporan hasil

**Files:**
- Create: `reports/scenarios.md`

- [ ] Tabel per skenario (S1–S7): PASS/FAIL, bundle id/tx hash, `prove_ms` per leg, total latency, CPU/RAM pod Job (`kubectl top`), residual metadata publik, dan pemetaan ke O1–O5. Bagian "Keterbatasan": transfer satu aset, auditor online, isi ulang pool, topologi 4 peer bersama, status "not production-qualified".
- [ ] Commit `docs(report): APS scenario results` dan push.
