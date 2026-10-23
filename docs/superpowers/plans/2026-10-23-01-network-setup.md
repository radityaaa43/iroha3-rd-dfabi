# Setup Jaringan Iroha 3 (4 Party) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Jaringan Iroha 3 permissioned 4 validator (BI, Bank A, B, C) berjalan di namespace `iroha3` cluster ACK, di-build dan di-deploy lewat GitHub Actions, siap untuk APS (3 lane).

**Architecture:** Image dibangun dari source `071e281e` di runner GitHub dan di-push ke GHCR. Material kunci dan genesis dibuat di PC operator dengan `kagami` dari image itu, lalu masuk cluster sebagai Secret/ConfigMap (tidak pernah ke Git). Deploy dijalankan oleh self-hosted runner di dalam namespace `iroha3`, dengan ServiceAccount yang hanya berhak di namespace itu.

**Tech Stack:** Iroha 3 `iroha3d`/`kagami`/`iroha` @ `071e281e`, Docker BuildKit, GitHub Actions, GHCR, Kubernetes 1.33 (ACK), kustomize (bawaan `kubectl`), bash.

**Spec:** `docs/superpowers/specs/2026-10-23-iroha3-aps-rd-dfabi-design.md`

## Global Constraints

- Source Iroha: `hyperledger-iroha/iroha` @ `071e281e778c5928cab4d6e007b7ddc9b050df27`. Jangan pakai `main` atau `0010c5a7`.
- Image: `ghcr.io/radityaaa43/iroha3-rd-node:071e281e-stark`, feature `external-software-signer-bin,zk-stark`.
- Repo: `radityaaa43/iroha3-rd-dfabi`, private.
- Namespace: `iroha3`. Jangan menyentuh namespace lain (`iroha` adalah Iroha 2 yang sedang jalan).
- Party → StatefulSet: `bi`, `bank-a`, `bank-b`, `bank-c`. Port P2P `1337`, Torii `8080`.
- `P2P_PUBLIC_ADDRESS` = `<party>-0.<party>.iroha3.svc.cluster.local:1337`.
- Kunci privat (validator BLS, genesis, SoraNet transport, client) tidak boleh masuk Git, GitHub Secrets, log, atau image. `alibaba.yaml` tidak boleh di-commit.
- Kunci privat genesis tidak masuk cluster.
- Tidak boleh memakai `--seed`/`--seed-hex`, sample key upstream, atau `CHAIN` sample `00000000-…`.
- Telemetry profile `extended`. Jangan `developer`/`full`.
- `updateStrategy: OnDelete`. Ganti genesis/topologi hanya lewat wipe semua PVC peer secara terkoordinasi.
- kubectl di runner: `v1.33.13`. Runner image: `ghcr.io/actions/actions-runner:2.338.1`.
- Resource per peer: request `250m`/`1Gi`, limit `1500m`/`3Gi`. PVC `5Gi`, StorageClass `alicloud-essd-wffc`.

## Review Focus

- Pod restart dengan PVC lama tapi genesis baru → peer gagal replay. Deploy harus menolak genesis yang hash-nya beda dari yang tercatat di PVC (Task 6, cek `genesis-<hash8>` di label pod vs ConfigMap).
- Runner pod restart setelah token registrasi kedaluwarsa → runner harus tetap online tanpa token baru (Task 3, config runner di PVC).
- Node BI mati lalu hidup lagi → harus menyusul ke height dan hash yang sama dengan 3 bank (Task 7).
- Satu Secret peer terbaca pod party lain → pelanggaran pemisahan kunci. Setiap pod hanya me-mount Secret miliknya (Task 6, test `kubectl get sts -o json` memastikan tidak ada mount silang).
- Generate ulang material jaringan tanpa sengaja menimpa kunci yang sudah dipakai → script harus menolak bila `network/out/` sudah ada (Task 4).

---

### Task 1: Repo GitHub dan struktur awal

**Files:**
- Create: `README.md`
- Modify: `.gitignore` (tambah `network/out/`, `wallets/`)
- Existing: `build/build-image.sh`, `docs/superpowers/**`

**Interfaces:**
- Produces: remote `origin` = `https://github.com/radityaaa43/iroha3-rd-dfabi`, branch `main`.

- [ ] **Step 1: Pastikan file rahasia tidak ter-stage**

Run: `git status --short --ignored | grep -E 'alibaba.yaml|\.docx'`
Expected: `!! alibaba.yaml` (ignored). File `.docx` milik user: tambahkan ke `.gitignore` kecuali user meminta di-commit.

- [ ] **Step 2: Tulis `README.md`** berisi tujuan PoC, link ke spec dan kedua plan, serta peringatan "kunci tidak pernah di Git".

- [ ] **Step 3: Commit dan buat repo**

```bash
git add .gitignore README.md build docs
git commit -m "chore: scaffold Iroha 3 RD/DFABI APS PoC repo"
gh repo create radityaaa43/iroha3-rd-dfabi --private --source . --remote origin --push
```

- [ ] **Step 4: Verifikasi**

Run: `gh repo view radityaaa43/iroha3-rd-dfabi --json visibility,defaultBranchRef --jq '.visibility+" "+.defaultBranchRef.name'`
Expected: `PRIVATE main`. Lalu `git ls-files | grep -c alibaba.yaml` → `0`.

---

### Task 2: Workflow build image di runner GitHub

**Files:**
- Create: `.github/workflows/build-image.yml`
- Modify: `build/build-image.sh` (terima `TAG` dari env; sudah menerima argumen ke-2)

**Interfaces:**
- Produces: image `ghcr.io/radityaaa43/iroha3-rd-node:071e281e-stark` dengan binary `/usr/local/bin/{iroha3d,iroha,kagami}`.

- [ ] **Step 1: Tulis workflow** dengan trigger `workflow_dispatch` dan `push` pada path `build/**`. Job `runs-on: ubuntu-latest`, `permissions: {contents: read, packages: write}`, `timeout-minutes: 340`. Langkah:
  1. Bebaskan disk (hapus `/usr/share/dotnet`, `/usr/local/lib/android`, `/opt/ghc`, `/opt/hostedtoolcache/CodeQL`; `docker system prune -af`). Catat `df -h /` sebelum/sesudah.
  2. Clone `hyperledger-iroha/iroha` dengan `git init` + `git fetch --depth 1 origin 071e281e778c5928cab4d6e007b7ddc9b050df27`.
  3. `docker/login-action` ke `ghcr.io` dengan `GITHUB_TOKEN`.
  4. `CARGO_BUILD_JOBS=4 build/build-image.sh <src> ghcr.io/radityaaa43/iroha3-rd-node:071e281e-stark`.
  5. Smoke: `docker run --rm --entrypoint iroha3d <image> --version` dan `--entrypoint kagami <image> --help`.
  6. `docker push`.

- [ ] **Step 2: Jalankan**

Run: `gh workflow run build-image.yml && gh run watch --exit-status`
Expected: sukses. Jika OOM (`signal: 9`/`Killed`), turunkan `CARGO_BUILD_JOBS` ke 2 dan ulang. Jika disk penuh, tambahkan penghapusan direktori lain yang terlihat besar di log `du`.

- [ ] **Step 3: Jadikan package public (langkah manual operator, sekali)**

GitHub → Packages → `iroha3-rd-node` → Package settings → Change visibility → Public. REST API tidak menyediakan perubahan visibility.
Verifikasi: `docker logout ghcr.io; docker pull ghcr.io/radityaaa43/iroha3-rd-node:071e281e-stark` sukses tanpa login.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/build-image.yml build/build-image.sh
git commit -m "ci: build Iroha 3 node image from 071e281e on GitHub runners"
git push
```

---

### Task 3: Self-hosted runner di namespace `iroha3`

**Files:**
- Create: `deploy/runner/rbac.yaml` (ServiceAccount `gha-runner`, Role `gha-deployer`, RoleBinding)
- Create: `deploy/runner/runner.yaml` (StatefulSet `gha-runner`, 1 replika, PVC `runner-state` 1Gi)
- Create: `deploy/runner/install.sh` (dijalankan operator dari PC, memakai `alibaba.yaml` lokal)
- Create: `.github/workflows/runner-check.yml`

**Interfaces:**
- Produces: runner online dengan label `self-hosted,linux,iroha3`; ServiceAccount `system:serviceaccount:iroha3:gha-runner`.

- [ ] **Step 1: Role `gha-deployer`** (namespace `iroha3` saja): `get,list,watch,create,update,patch,delete` pada `statefulsets`, `services`, `configmaps`, `persistentvolumeclaims`, `networkpolicies`, `jobs`, `deployments`, `pods`, `pods/log`; `create` pada `pods/exec`; `get,list` pada `secrets`. Tanpa ClusterRole.

- [ ] **Step 2: `runner.yaml`.** Image `ghcr.io/actions/actions-runner:2.338.1`, `serviceAccountName: gha-runner`, securityContext non-root (uid 1001), request `100m`/`256Mi`, limit `1`/`1Gi`. Entrypoint: jika `/state/.runner` belum ada, `./config.sh --unattended --url https://github.com/radityaaa43/iroha3-rd-dfabi --token "$RUNNER_TOKEN" --name iroha3-incluster --labels iroha3 --replace`, lalu salin `.runner`, `.credentials`, `.credentials_rsaparams` ke `/state`. Jika sudah ada, salin balik dari `/state`. Lalu `./run.sh`. `RUNNER_TOKEN` dari Secret `gha-runner-registration` (hanya dipakai saat registrasi pertama).

- [ ] **Step 3: `install.sh`.** Langkah: `gh api -X POST repos/radityaaa43/iroha3-rd-dfabi/actions/runners/registration-token --jq .token` → `kubectl create secret generic gha-runner-registration --from-literal=RUNNER_TOKEN=… -n iroha3 --dry-run=client -o yaml | kubectl apply -f -` → `kubectl apply -f deploy/runner/`. Wajib `KUBECONFIG=./alibaba.yaml` dan menolak jalan bila context bukan cluster ACK (cek `server: https://172.24.11.196:6443`).

- [ ] **Step 4: Verifikasi RBAC**

```bash
SA=system:serviceaccount:iroha3:gha-runner
kubectl auth can-i create statefulsets -n iroha3 --as=$SA   # yes
kubectl auth can-i create statefulsets -n iroha  --as=$SA   # no
kubectl auth can-i create secrets      -n iroha3 --as=$SA   # no
```

- [ ] **Step 5: Verifikasi runner**

Run: `gh api repos/radityaaa43/iroha3-rd-dfabi/actions/runners --jq '.runners[]|.name+" "+.status'` → `iroha3-incluster online`.
Lalu hapus pod (`kubectl delete pod gha-runner-0 -n iroha3`), tunggu, ulangi query → tetap `online` (tanpa token baru).
`runner-check.yml` (`runs-on: [self-hosted, iroha3]`) menjalankan `kubectl get pods -n iroha3` dengan kubectl `v1.33.13` → sukses.

- [ ] **Step 6: Commit**

```bash
git add deploy/runner .github/workflows/runner-check.yml
git commit -m "ci: in-cluster GitHub runner scoped to namespace iroha3"
git push
```

---

### Task 4: Generate material jaringan (PC operator)

**Files:**
- Create: `network/generate.sh`
- Create: `network/check.sh`
- Create (commit): `network/public/{genesis.signed.nrt,genesis.public_key,genesis.expected_hash,peers.json,chain_id}`
- Create (gitignored): `network/out/**`

**Interfaces:**
- Consumes: image Task 2.
- Produces: `network/public/peers.json` = `[{"party":"bi","public_key":"ea0130…","pop_hex":"0x…"}, …]` urut `bi, bank-a, bank-b, bank-c`; `network/out/<party>/peer.toml`; `network/out/<party>/client.toml`; `network/out/genesis/` (kunci genesis, dipindah ke custody offline setelah selesai).

- [ ] **Step 1: Tulis `network/check.sh`** (gagal = exit ≠ 0) yang memeriksa:
  - `peers.json` berisi tepat 4 entri, party sesuai urutan, setiap `public_key` diawali `ea0130`, setiap `pop_hex` tidak kosong, tidak ada duplikat.
  - `genesis.expected_hash` satu baris, diakhiri LF, cocok regex `^hash:[0-9A-F]{63}[13579BDF]#[0-9A-F]{4}$`.
  - `genesis.public_key` diawali `ed0120`.
  - `chain_id` bukan `00000000-0000-0000-0000-000000000000`.
  - Tidak ada string `private_key` di `network/public/`.

- [ ] **Step 2: Jalankan `network/check.sh`** → Expected: FAIL (file belum ada).

- [ ] **Step 3: Tulis `network/generate.sh`.** Menolak jalan bila `network/out/` sudah ada. Di dalam container image:
  `kagami localnet --peers 4 --consensus-mode permissioned --chain-id "$(uuidgen)" --out-dir /work/out`
  (tanpa `--seed`). Peta `peer0→bi`, `peer1→bank-a`, `peer2→bank-b`, `peer3→bank-c`. Salin file publik ke `network/public/`, bangun `peers.json` dari config peer. Set mode `0600` untuk semua file privat. Cetak instruksi: pindahkan kunci privat genesis keluar dari repo.

- [ ] **Step 4: Jalankan generate lalu check**

Run: `network/generate.sh && network/check.sh`
Expected: PASS. `git status --short network/` hanya menampilkan `network/public/**` dan script.

- [ ] **Step 5: Commit**

```bash
git add network/generate.sh network/check.sh network/public
git commit -m "feat(network): generate 4-party permissioned genesis bundle"
git push
```

---

### Task 5: Upload Secret dan ConfigMap genesis

**Files:**
- Create: `deploy/secrets.sh` (operator, dari PC)

**Interfaces:**
- Consumes: `network/out/<party>/peer.toml`, `network/public/*`.
- Produces: Secret `peer-<party>` (key `peer.toml`), Secret `client-<party>` (key `client.toml`), ConfigMap `genesis-<hash8>` (immutable; `genesis.signed.nrt` sebagai binaryData, `genesis.public_key`, `genesis.expected_hash`). `<hash8>` = 8 karakter pertama setelah `hash:` di `genesis.expected_hash`, huruf kecil.

- [ ] **Step 1: Tulis script** dengan `kubectl create … --dry-run=client -o yaml | kubectl apply -f -` untuk Secret, dan `immutable: true` untuk ConfigMap. Context dicek sama seperti Task 3. Cetak nama ConfigMap.

- [ ] **Step 2: Verifikasi**

```bash
kubectl get secret -n iroha3 peer-bi peer-bank-a peer-bank-b peer-bank-c client-bi
kubectl get cm -n iroha3 -l app.kubernetes.io/part-of=iroha3-rd -o jsonpath='{.items[*].immutable}'   # true
```

- [ ] **Step 3: Commit** `deploy/secrets.sh` dengan pesan `feat(deploy): load per-party secrets and immutable genesis`.

---

### Task 6: Manifest 4 peer dan workflow deploy

**Files:**
- Create: `deploy/k8s/base/{statefulset.yaml,service.yaml,kustomization.yaml}`
- Create: `deploy/k8s/parties/{bi,bank-a,bank-b,bank-c}/kustomization.yaml`
- Create: `deploy/k8s/networkpolicy.yaml`
- Create: `deploy/k8s/kustomization.yaml`
- Create: `.github/workflows/deploy.yml`
- Create: `scripts/check-manifests.sh`

**Interfaces:**
- Consumes: Secret/ConfigMap Task 5, image Task 2.
- Produces: StatefulSet `<party>`, headless Service `<party>` (port `p2p` 1337, `api` 8080), label `app.kubernetes.io/part-of=iroha3-rd`, `iroha3-rd/party=<party>`, `iroha3-rd/genesis=<hash8>`.

- [ ] **Step 1: Tulis `scripts/check-manifests.sh`** yang menjalankan `kubectl kustomize deploy/k8s` lalu gagal bila:
  - jumlah StatefulSet ≠ 4;
  - ada StatefulSet yang me-mount Secret `peer-*` milik party lain;
  - image bukan `ghcr.io/radityaaa43/iroha3-rd-node:071e281e-stark`;
  - `updateStrategy.type` ≠ `OnDelete`;
  - ada env yang namanya mengandung `PRIVATE_KEY` dengan `value:` literal;
  - `TELEMETRY_PROFILE` ≠ `extended`.

- [ ] **Step 2: Jalankan** → Expected: FAIL (manifest belum ada).

- [ ] **Step 3: Tulis manifest.** Base StatefulSet: `serviceName: <party>`, `replicas: 1`, `updateStrategy: OnDelete`, `podManagementPolicy: Parallel`. Container `iroha3d`:
  - Args config: `--config /config/peer.toml` (Secret `peer-<party>`, `defaultMode: 0400`). Genesis dari ConfigMap `genesis-<hash8>` di `/genesis`, env `GENESIS=/genesis/genesis.signed.nrt`, `GENESIS_EXPECTED_HASH_FILE=/genesis/genesis.expected_hash`, `GENESIS_PUBLIC_KEY` dibaca dari file yang sama.
  - Env: `P2P_ADDRESS=0.0.0.0:1337`, `API_ADDRESS=0.0.0.0:8080`, `P2P_PUBLIC_ADDRESS` sesuai Global Constraints, `TELEMETRY_PROFILE=extended`.
  - Probes: liveness `GET /livez`, readiness `GET /readyz`, startup `exec` `test "$(curl -fsS localhost:8080/status/blocks)" -gt 0` (failureThreshold 60, period 5s).
  - securityContext uid/gid/fsGroup `1001`, `allowPrivilegeEscalation: false`, drop `ALL`. PVC `data` di `/storage`.
  - Overlay per party: `nameSuffix`/patch nama, label party, nama Secret.
  - NetworkPolicy: ingress `1337` hanya dari pod `app.kubernetes.io/part-of=iroha3-rd`; `8080` hanya dari pod di namespace `iroha3`.

  `deploy.yml`: `runs-on: [self-hosted, iroha3]`, trigger `workflow_dispatch` dan `push` path `deploy/k8s/**`. Langkah: unduh kubectl `v1.33.13`, `scripts/check-manifests.sh`, `kubectl apply -k deploy/k8s`, tunggu 4 pod Ready (`kubectl wait --for=condition=Ready pod -l app.kubernetes.io/part-of=iroha3-rd -n iroha3 --timeout=15m`).

- [ ] **Step 4: Jalankan check** → PASS.

- [ ] **Step 5: Commit, push, deploy**

```bash
git add deploy/k8s scripts/check-manifests.sh .github/workflows/deploy.yml
git commit -m "feat(deploy): 4-party Iroha 3 StatefulSets with in-cluster deploy workflow"
git push && gh run watch --exit-status $(gh run list -w deploy.yml -L1 --json databaseId --jq '.[0].databaseId')
```

Expected: 4 pod `Running 1/1` di `iroha3`. Pod lain di namespace lain tidak berubah.

---

### Task 7: Smoke test dan gate G1 (BI node mati)

**Files:**
- Create: `scripts/smoke.sh`
- Create: `.github/workflows/smoke.yml`
- Create: `reports/g1-network.md`

**Interfaces:**
- Consumes: Service `<party>:8080`, Secret `client-bi`.
- Produces: laporan G1 berisi height, block hash, dan hasil per langkah.

- [ ] **Step 1: Tulis `scripts/smoke.sh`** (jalan di runner, memakai `kubectl exec`/Job dengan image node):
  1. Keempat `/status` menunjukkan `blocks` > 0 dan hash blok terakhir sama.
  2. Submit satu tx publik dari `client-bi` (mis. `iroha --config client.toml ledger domain …` register domain `smoke<epoch>`) → committed.
  3. `kubectl scale sts bi --replicas=0`; submit tx dari `client-bank-a` → committed oleh 3 validator.
  4. `kubectl scale sts bi --replicas=1`; tunggu `bi` Ready; height dan hash `bi` sama dengan `bank-a` dalam ≤ 120 s.
  Gagal = exit ≠ 0 dengan pesan langkah yang gagal.

- [ ] **Step 2: Jalankan** `gh workflow run smoke.yml && gh run watch --exit-status` → PASS.

- [ ] **Step 3: Tulis `reports/g1-network.md`** (commit image digest, genesis hash, hasil 4 langkah, waktu catch-up) dan commit:

```bash
git add scripts/smoke.sh .github/workflows/smoke.yml reports/g1-network.md
git commit -m "test(network): G1 smoke and BI-node-down liveness"
git push
```

---

### Task 8: Topologi multi-lane untuk APS (gate G1b)

**Files:**
- Create: `network/nexus.toml` (overlay config, disalin ke setiap `peer.toml`)
- Modify: `network/generate.sh` (flag `--aps`: merge `nexus.toml`, tambah instruksi genesis lane validator, sign ulang)
- Modify: `network/check.sh` (cek 3 lane)
- Create: `scripts/wipe-network.sh` (hapus 4 StatefulSet dan PVC `data-*` di `iroha3`; minta konfirmasi `yes`)
- Create: `reports/g1b-multilane.md`

**Interfaces:**
- Produces: lane 0 `universal` (dataspace id 0, public), lane 1 `ds-rd` (dataspace id 1, restricted), lane 2 `ds-dfabi` (dataspace id 2, restricted); setiap dataspace `fault_tolerance = 1`; keempat validator aktif di ketiga lane; `[zk.stark] enabled = true`; `[nexus.atomic_private_settlement] enabled = true`, `activation_height` = height genesis + `minimum_activation_notice_blocks`.

- [ ] **Step 1: Tulis `nexus.toml`** mengikuti `localnet_builder` di `integration_tests/tests/nexus/atomic_private_settlement_localnet.rs` @ `071e281e` (key: `nexus.lane_count`, `nexus.lane_catalog`, `nexus.dataspace_catalog`, `nexus.routing_policy`, `nexus.staking.{public_validator_mode,restricted_validator_mode}="stake_elected"`, `nexus.staking.{stake_asset_id,stake_escrow_account_id,slash_sink_account_id,max_validators=4}`, `zk.stark.enabled`, `nexus.atomic_private_settlement.*`). Nilai timeout dan sidecar memakai default shipped (`audit/prepare/commit_timeout_blocks = 1200`, `max_expiry_blocks = 7200`), kecuali `minimum_activation_notice_blocks` yang dikecilkan ke `10` untuk PoC (dicatat di laporan).

- [ ] **Step 2: Tambah ke genesis** (`generate.sh --aps`): register stake asset, stake per validator, `RegisterPublicLaneValidator` + `ActivatePublicLaneValidator` untuk lane 1 dan 2 (lane 0 sudah di-bootstrap `kagami localnet` permissioned, PR #5627), dengan pola yang sama seperti `genesis_post_topology` di test tersebut. Lalu `kagami genesis validate` dan sign ulang dengan `--expected-hash-out`.

- [ ] **Step 3: Perluas `check.sh`** → gagal bila `nexus.toml` tidak punya tepat 3 lane / dataspace id `0,1,2`. Jalankan → FAIL sebelum Step 1–2, PASS sesudahnya.

- [ ] **Step 4: Wipe dan redeploy.** `scripts/wipe-network.sh` (operator mengetik `yes`), `deploy/secrets.sh`, jalankan `deploy.yml`.

- [ ] **Step 5: Verifikasi gate**

Untuk setiap lane 0/1/2: query status lane di Torii (`iroha` CLI atau `/v1/...` lane endpoint yang tersedia di `/openapi.json`) → 4 validator aktif dan block height naik. Ulangi `scripts/smoke.sh`.
Expected: PASS. **Jika peer gagal start atau lane tidak punya 4 validator aktif: hentikan, tulis error persis di `reports/g1b-multilane.md`, dan laporkan ke user.** Ini konfigurasi yang belum diuji upstream. Plan use case tidak boleh dimulai sebelum G1b PASS.

- [ ] **Step 6: Commit**

```bash
git add network deploy scripts/wipe-network.sh reports/g1b-multilane.md
git commit -m "feat(network): 3-lane Nexus topology with APS enabled (G1b)"
git push
```
