# Iroha 3: semua flow RD/DFABI privat lewat APS — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Issuance, transfer RD/DFABI, DvP dan award di Lensa iroha3 hanya terlihat utuh oleh pengirim, penerima dan BI, dengan saldo dan riwayat dibaca dari chain.

**Architecture:** Driver Rust `rd-dfabi` (repo `iroha3-rd-node-build`, folder `driver/`) dapat dua pool APS jangka panjang (RD di ds-rd, DFABI di ds-dfabi) yang diaktifkan sekali dengan cadangan BI. Setiap operasi = satu bundle APS dua leg yang membelanjakan satu note hidup + dummy virtual, dengan Merkle path dihitung driver dari riwayat pool di chain. Lensa memanggil driver untuk keenam flow dan untuk saldo/riwayat per pihak.

**Tech Stack:** Rust 2024 (anggota workspace iroha @ `071e281e`, `driver/build.sh`), TypeScript/Node 22 + vitest (Lensa `frontend/server`), Playwright (`frontend/web/playwright.flows.config.ts`), k8s Job (`iroha3/deploy/jobs`).

**Spec:** `iroha3/docs/superpowers/specs/2026-11-10-iroha3-aps-all-flows-design.md`

## Global Constraints

- Upstream tetap `hyperledger-iroha/iroha@071e281e778c5928cab4d6e007b7ddc9b050df27`; tidak ada patch ke iroha.
- Build/test driver hanya lewat `driver/build.sh test|build` (cgroup cap `MEM=10g CPUS=6 JOBS=1`); build pertama tanpa cache ~55 menit.
- Log driver, Job dan Lensa tidak boleh memuat nominal, pihak, memo atau secret (docs APS "Failure and recovery"). Satu-satunya keluaran berisi nominal: baris `result_json=`/`wallet_json=` di stdout yang dibaca Lensa, tidak di-log ulang.
- File kunci 0600, tidak masuk Git; kunci baru di `~/iroha3-keys` seperti `<party>.seed`.
- Output note bernilai 0 dilarang (seal audit gagal, terukur 2026-11-10): kembalian ≥ 1 di setiap leg, leg 0 juga membayar reimbursement sponsor `1`.
- Eksperimen jaringan (G1b, G2, G3) memakai cluster live lewat container driver, sama seperti DvP Lensa harian: hanya menambah pool/bundle baru, tidak mengubah deployment/config. Tidak ada wipe genesis.
- Gate gagal ⇒ berhenti, laporkan ke user, jangan cari jalan memutar.

## Review Focus

1. Payer tidak punya satu note yang cukup (saldo terpecah di beberapa note) ⇒ driver menolak sebelum proving dengan pesan jelas, Lensa menampilkan "Saldo di satu note tidak cukup", tidak ada pool/aktivasi baru. Test: Task 5 `pick_note_rejects_when_no_single_note_covers`.
2. Dua flow Lensa jalan bersamaan pada pool yang sama ⇒ yang kedua menunggu (serial), bukan gagal `ParentHeadMismatch`. Test: Task 8 `aps runs are serialized`.
3. Riwayat pool berubah di antara baca-riwayat dan submit (bundle lain finalized) ⇒ driver mendeteksi `old_root` usang lewat pool head dan mengulang sekali, bukan mengirim bundle yang pasti ditolak. Test: Task 5 `stale_root_is_detected_before_proving`.
4. Note diterima tapi belum ditemukan wallet (scan tertinggal) ⇒ saldo tidak pernah negatif/ganda; note terpakai (nullifier terbit) tidak ikut dijumlah. Test: Task 6 `balance_excludes_spent_and_counts_each_note_once`.
5. Bank C membaca lewat Torii-nya sendiri ⇒ tidak ada nominal/pihak. Test: Task 10 live check `bank C lens sealed for every flow`.

---

## Fase A — Spike (gate G1a, G3, G1b, G2, G4)

### Task 1: Pohon note pool dihitung driver (`tree.rs`)

**Files:**
- Create: `node-build/driver/src/tree.rs`
- Modify: `node-build/driver/src/main.rs` (tambah `mod tree;`)

**Interfaces:**
- Produces: `pub struct PoolTree { namespace: PrivacyNamespaceV1, leaves: Vec<[u8; 32]> }`, `PoolTree::new(pool_id: PrivacyPoolIdV1) -> Result<Self>` (namespace `IrohaIvmPrivateNoteStarkV1` + `PoolProgram{pool_id, program_id: atomic_private_settlement_program_id_v1()}`), `fn append(&mut self, commitments: &[PrivacyCommitmentV1]) -> Result<()>`, `fn root(&self) -> PrivacyRootV1`, `fn path(&self, position: usize) -> Result<[[u8; 32]; 32]>`, `fn position(&self, c: PrivacyCommitmentV1) -> Option<usize>`.
- Hash persis `proof_managed_accumulator.rs:19-39,116-137`: leaf = SHA256(`"iroha.privacy.proof-managed-note-tree.leaf.v1"` ‖ u64be(len(norito(namespace))) ‖ norito(namespace) ‖ commitment); node = SHA256(`"…node.v1"` ‖ level_u8 ‖ left ‖ right); empty leaf = SHA256(`"…empty-leaf.v1"`); depth 32; algoritma path = `continuation_membership_path` (`relation.rs:922-957`).

- [ ] **Step 1: Test** `tree_matches_upstream_bootstrap_plan` di `tree.rs`: buat 2 commitment acak dan 3 output acak, panggil `plan_atomic_private_settlement_bootstrap_v1(pool_id, inputs, outputs, secrets)`; `PoolTree` dari origin terurut ⇒ `root() == plan.old_root`; setelah `append(outputs)` ⇒ `root() == plan.new_root`; `path(position_of(inputs[0]))` == path di `plan` untuk input 0.
- [ ] **Step 2:** `driver/build.sh test` ⇒ FAIL (modul belum ada).
- [ ] **Step 3:** Implement `PoolTree` sesuai Interfaces.
- [ ] **Step 4:** `driver/build.sh test` ⇒ PASS.
- [ ] **Step 5:** Commit `feat(driver): pool note tree computed client-side (Merkle path for any leaf)`.

### Task 2: Gate G1a — leg kontinuasi terbukti offline

**Files:**
- Modify: `node-build/driver/src/aps.rs` (fungsi baru), `node-build/driver/src/main.rs` (subcommand)

**Interfaces:**
- Consumes: `PoolTree` (Task 1).
- Produces: `pub fn prove_continuation_selftest(peers_json: &Path) -> Result<()>`; CLI `rd-dfabi prove-continuation-selftest <peers.json>`; mencetak `continuation_verified=true prove_ms=<n> peak_rss=<..>`.

- [ ] **Step 1: Test** `continuation_leg_proves_and_verifies` (pakai `fixtures/peers.json`): settlement 1 = bootstrap seperti `prove_selftest`; settlement 2 di pool yang sama: input 0 = output penerima settlement 1 (spend secret penerima, posisi + path dari `PoolTree`), input 1 = dummy virtual (`dummy_domain` di-set, `prepare_atomic_private_settlement_input_openings_v1`), `old_epoch=2,new_epoch=3`, `old_root` = root setelah settlement 1; `prove_atomic_private_settlement_v1` lalu `verify_atomic_private_settlement_v1` ⇒ `Ok`. Ikuti `relation.rs:961-1100`.
- [ ] **Step 2:** `driver/build.sh test` ⇒ FAIL.
- [ ] **Step 3:** Implement `prove_continuation_selftest` (pakai ulang `funding`, `govern`, `proof_manifest`, `prepare_leg` yang ada; bagian baru hanya input kontinuasi).
- [ ] **Step 4:** `driver/build.sh test` ⇒ PASS. **GATE G1a**: gagal ⇒ stop, lapor.
- [ ] **Step 5:** Commit `feat(driver): offline continuation leg (received note + virtual dummy) proves and verifies`.

### Task 3: Gate G3 — riwayat pool dari chain

**Files:**
- Create: `node-build/driver/src/history.rs`

**Interfaces:**
- Produces: `pub struct PoolHistory { pub pool_id: PrivacyPoolIdV1, pub tree: PoolTree, pub epoch: u64, pub outputs: Vec<OutputRow>, pub nullifiers: BTreeSet<PrivacyNullifierV1> }`, `pub struct OutputRow { pub position: usize, pub commitment: PrivacyCommitmentV1, pub encrypted: PrivacyEncryptedOutputV1, pub bundle_id: String }`, `pub fn load(client: &Client, pool_id: PrivacyPoolIdV1) -> Result<PoolHistory>`.

- [ ] **Step 1: Discovery (catat di commit message):** cari sumber publik untuk (a) commitment origin pool (`ActivatePrivateSettlementPoolV1` di tx aktivasi), (b) per bundle finalized: `output_commitments`, `encrypted_outputs`, `nullifiers` per leg (receipt `GET /v1/nexus/private-settlements/bundles/{id}/receipt`, atau instruksi `FinalizeAtomicPrivateSettlementV1` di blok global), (c) pool head (epoch, root). Urutan append = urutan finalisasi bundle × urutan statement.
- [ ] **Step 2: Test** `history_root_equals_pool_head` (unit, fixture JSON hasil Step 1): `load` dari fixture ⇒ `tree.root()` == root pool head fixture, `epoch` sama.
- [ ] **Step 3:** Implement `load`.
- [ ] **Step 4:** Live: `rd-dfabi pool-history <config> --pool <hex>` pada pool DvP yang sudah finalized di cluster ⇒ root == pool head. **GATE G3**: tidak ada sumber publik ⇒ stop, lapor.
- [ ] **Step 5:** Commit `feat(driver): pool history read from chain; tree root matches pool head`.

### Task 4: Kunci note per pihak + pool jangka panjang (G4)

**Files:**
- Modify: `node-build/driver/src/config.rs`, `node-build/driver/src/main.rs`, `node-build/driver/src/aps.rs`
- Modify: `iroha3/deploy/k8s-apps/rd-dfabi.toml` (field `[pools] rd = "<hex>" dfabi = "<hex>"`)

**Interfaces:**
- Produces: CLI `rd-dfabi keys new-note <dir> <name>` ⇒ `<dir>/<name>.note` (0600, 32-byte spend secret + 32-byte view secret, hex); `Config::note_keys(party) -> Result<NoteKeys>`, `NoteKeys { spend: [u8;32], view: [u8;32] }`, `NoteKeys::authority() -> [u8;32]` (`derive_note_authority_v1`), `NoteKeys::view_public()` (`ivm_private_recipient_public_key_v1`).
- Produces: CLI `rd-dfabi pool-init <config> --rd-reserve N --dfabi-reserve N` ⇒ aktivasi pool RD dan DFABI dengan 2 note origin milik BI (reserve, dan `1`), cetak `pool_init_json={"rd":"<pool hex>","dfabi":"<pool hex>"}`.

- [ ] **Step 1: Test** `note_keys_roundtrip_and_permissions`: file 0600, baca ulang sama, `authority()` deterministik.
- [ ] **Step 2: Discovery G4:** batas jendela validitas governance pool (`govern(..., height, expiry_height, ...)`, field validity di `PrivateSettlementPoolGovernanceV1`) — tentukan nilai expiry terbesar yang diterima; catat. Bila maksimum < 1 minggu blok ⇒ catat kebutuhan `RotatePrivateSettlementPoolPolicyV1` sebagai task tambahan, lapor user.
- [ ] **Step 3:** Implement `keys new-note`, `NoteKeys`, `pool-init`.
- [ ] **Step 4:** `driver/build.sh test` ⇒ PASS.
- [ ] **Step 5:** Commit `feat(driver): per-party note keys and one-time long-lived RD/DFABI pools`.

### Task 5: Gate G1b + G2 — `pay` di pool bersama

**Files:**
- Modify: `node-build/driver/src/aps.rs` (generalisasi `run_dvp` → `run_bundle`), `node-build/driver/src/main.rs`
- Create: `node-build/driver/src/wallet.rs`

**Interfaces:**
- Consumes: `PoolHistory::load` (Task 3), `PoolTree::path` (Task 1), `NoteKeys` (Task 4).
- Produces: `pub struct OwnedNote { pub position: usize, pub commitment, pub value: u128, pub rho, pub blinding, pub memo_digest }`; `wallet::scan(history: &PoolHistory, keys: &NoteKeys) -> Vec<OwnedNote>` (dekripsi `encrypted` dengan view secret; buang yang nullifier-nya ada di `history.nullifiers`); `wallet::pick_note(notes: &[OwnedNote], need: u128) -> Result<OwnedNote>` (note terkecil dengan `value > need`).
- Produces: `pub struct LegSpec { pub pool: PrivacyPoolIdV1, pub lane: u32, pub asset: AssetDefinitionId, pub payer: Party, pub recipient: Party, pub amount: u128 }`; `pub fn run_bundle(cfg: &Config, legs: [LegSpec; 2], options: &Options) -> Result<()>`; CLI:
  - `rd-dfabi pay <config> --asset rd|dfabi --from P --to Q --amount N` (leg pendamping = BI→BI `1` di pool aset lain)
  - `rd-dfabi dvp <config> --buyer P --seller P --rd N --dfabi N` (sekarang di pool bersama; flag `--*-funding` dihapus)
  - stdout tetap `result_json=` (+ field `"kind"`).

- [ ] **Step 1: Test** `pick_note_rejects_when_no_single_note_covers` (notes 5,5; need 8 ⇒ Err "no single note covers"; need 4 ⇒ note 5) dan `pick_note_requires_change` (note 5, need 5 ⇒ Err).
- [ ] **Step 2: Test** `stale_root_is_detected_before_proving`: history root ≠ pool head root ⇒ `run_bundle` reload sekali, lalu Err bila masih beda (fungsi murni `check_head(history_root, head_root) -> Result<()>`).
- [ ] **Step 3:** `driver/build.sh test` ⇒ FAIL; implement `wallet.rs`, `run_bundle`, CLI; `driver/build.sh test` ⇒ PASS; `driver/build.sh build`.
- [ ] **Step 4: Live gate (cluster, image lokal):** `pool-init` (reserve RD 10^15, DFABI 10^6); `pay rd BI→A 1000` ⇒ finalized; `pay rd A→B 300` ⇒ finalized (**G1b**: A membelanjakan note hasil terima); `pay rd B→C 100` ⇒ finalized; leg pendamping BI→BI diterima (**G2**). `rd-dfabi balance` (Task 6) belum ada: verifikasi dengan `wallet::scan` lewat `rd-dfabi wallet <config> --party P` sementara. Gagal ⇒ stop, lapor.
- [ ] **Step 5:** Commit `feat(driver): pay and dvp on shared long-lived pools (received notes are spendable)`; tag image `<commit8>`, push CI.

## Fase B — Driver lengkap

### Task 6: Saldo dan riwayat per pihak dari chain

**Files:**
- Modify: `node-build/driver/src/wallet.rs`, `node-build/driver/src/main.rs`

**Interfaces:**
- Produces: CLI `rd-dfabi wallet <config> --party P` ⇒ satu baris `wallet_json={"party":"P","rd":"<n>","dfabi":"<n>","items":[{"bundle_id","asset","direction":"in"|"out","amount","counterparty":"P"|null,"height"}]}`. Counterparty diisi dari memo/kunci yang dikenal di catatan audit hanya untuk BI; untuk bank: `in` dari dekripsi output (pengirim tidak diketahui ⇒ ambil dari catatan bundle milik sendiri bila ada, selain itu `null`), `out` dari note kembalian sendiri + penerima yang ia bayar.
- BI: `rd-dfabi wallet --party BI --audit` membaca `bi-auditor GET /records` (semua bundle).

- [ ] **Step 1: Test** `balance_excludes_spent_and_counts_each_note_once` (history fixture: 3 note milik A, 1 terpakai, satu output muncul di dua scan ⇒ saldo = jumlah 2 note unik).
- [ ] **Step 2:** FAIL ⇒ implement ⇒ PASS.
- [ ] **Step 3:** Commit `feat(driver): per-party balance and history from on-chain pool outputs`.

### Task 7: Auditor BI — daftar semua record

**Files:**
- Modify: `node-build/driver/src/auditor.rs`

**Interfaces:**
- Produces: `GET /records` ⇒ `[{bundle_id, leg, verdict, payer, recipient, asset, amount, height}]` (yang sudah ada: `GET /records/<bundle>`).

- [ ] **Step 1: Test** `records_lists_every_bundle_in_height_order`.
- [ ] **Step 2:** FAIL ⇒ implement ⇒ PASS ⇒ commit `feat(auditor): list all audit records for BI's history`.
- [ ] **Step 3:** Deploy: image baru di `iroha3/deploy/k8s-apps/bi-auditor.yaml`, rollout, `curl 127.0.0.1:38090/records` ⇒ 200.

## Fase C — Lensa

### Task 8: Adapter iroha3 — keenam flow lewat driver

**Files:**
- Modify: `frontend/server/src/adapters/iroha3-aps.ts` (`runPay`, `wallet`), `frontend/server/src/adapters/iroha3.ts` (routing flow, `balanceOf`, `history`, lens)
- Test: `frontend/server/test/iroha3-aps.test.ts`, `frontend/server/test/iroha3-history.test.ts`

**Interfaces:**
- Consumes: CLI Task 5/6 (`pay`, `dvp`, `wallet`), `bi-auditor GET /records` (Task 7).
- Produces: `runPay(run, c, p: {asset:'RD'|'DFABI'; from: PartyId; to: PartyId; amount: bigint}, onPhase) -> Promise<ApsResult>`; `wallet(run, c, party: PartyId) -> Promise<{rd: bigint; dfabi: bigint; items: WalletItem[]}>`; mapping flow ⇒ CLI sesuai tabel spec §4; `balanceOf(party, asset)` = `wallet(...)` (cache per height seperti scan sekarang); `history(party)` = `items`; lens tiap pihak = `privateLens` yang ada.

- [ ] **Step 1: Tests** (runner palsu): `rd-transfer calls pay with --asset rd`, `rd-issue pays from BI`, `dvp no longer passes --rd-funding`, `aps runs are serialized` (dua panggilan bersamaan ⇒ urutan start/finish tidak tumpang), `wallet_json parsed into balances`, `driver error surfaces scrubbed reason`.
- [ ] **Step 2:** `npx vitest run test/iroha3-aps.test.ts test/iroha3-history.test.ts` ⇒ FAIL; implement; ⇒ PASS; `npx vitest run` ⇒ semua PASS; `npx tsc --noEmit -p .` bersih.
- [ ] **Step 3:** Commit `feat(iroha3): every Lensa flow settles privately through APS; balances and history from the chain`.

### Task 9: Bootstrap state Lensa + keys

**Files:**
- Modify: `frontend/server/src/cli/bootstrap-iroha3.ts` (jalankan `keys new-note` untuk 4 pihak bila belum ada, `pool-init` sekali, tulis `aps.pools` ke `state/iroha3.json`)

- [ ] **Step 1: Test** `bootstrap writes pools once and never re-inits` (state berisi `aps.pools` ⇒ tidak memanggil `pool-init`).
- [ ] **Step 2:** FAIL ⇒ implement ⇒ PASS ⇒ commit `feat(iroha3): bootstrap note keys and the long-lived pools`.
- [ ] **Step 3:** Jalankan bootstrap di host, restart `lensa.service` (koordinasi dengan sesi lain lebih dulu).

## Fase D — Verifikasi dan laporan

### Task 10: Live end-to-end + cek kebocoran

**Files:**
- Modify: `frontend/server/test/live/iroha3.live.ts` (atau setara), `frontend/web/e2e/flows/flows.ts` bila langkah UI berubah

- [ ] **Step 1:** Live: `npx vitest run --config vitest.live.config.ts test/live/iroha3*.live.ts` (env `~/.config/lensa/lensa.env`) ⇒ PASS untuk 6 flow; tambah test `bank C lens sealed for every flow` (Torii bank-c `GET /v1/accounts/{C}/transactions` dan query aset ⇒ tidak ada nominal/pihak flow A↔B).
- [ ] **Step 2:** Playwright: `npx playwright test -c playwright.flows.config.ts --grep iroha3` ⇒ 6/6 PASS.
- [ ] **Step 3:** Commit `test(iroha3): live private flows and bank-C leakage check`.

### Task 11: Laporan

**Files:**
- Modify: `iroha3/reports/b-aps.md`, `iroha3/docs/superpowers/specs/2026-11-10-iroha3-aps-all-flows-design.md` (status gate)

- [ ] **Step 1:** Tabel per flow: waktu, bundle id, siapa melihat apa (A/B/C/BI), metadata publik; hasil G1a–G4; batasan spec §6; temuan spike (lane per bank tidak privat, bukti file:line).
- [ ] **Step 2:** Commit `docs(report): all Lensa flows private through APS`.
