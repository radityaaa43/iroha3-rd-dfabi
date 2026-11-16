# Iroha 3 APS Official Conformance Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the iroha3 APS deployment conform to the official iroha-docs APS page and upstream `071e281e`: four pools in two neutrally named dataspaces, same-asset companion legs with randomized placement, a neutral sponsor with spendable reimbursement, a restart-safe coordinator, then a reset chain qualified with measured evidence.

**Architecture:** The driver (repo `radityaaa43/iroha3-rd-node-build`, crate `driver/`) moves from a fixed `{rd, dfabi}` pool pair to a pool index keyed by `(lane, asset)`. The coordinator plans each bundle from the payers' per-pool capacities, runs the upstream `recover_or_*` coordinator calls with a durable non-secret in-flight store, and signs as a separate sponsor account. The network repo (`radityaaa43/iroha3-rd-dfabi`) gets a neutral genesis, sponsor key material and retires the per-trade pool path. Lensa (`radityaaa43/rd-lensa-frontend`) reads the new pool index. Ops scripts in `~/agent-texts/iroha/` run the gates, reset and qualification behind three user GO points.

**Tech Stack:** Rust (driver, upstream iroha client `crates/iroha/src/client/private_settlement.rs`), Python renderers/checkers, jq genesis, Kubernetes (ACK, two clusters), TypeScript (Lensa server), vitest, cargo test via `driver/build.sh test` / CI `driver-test.yml`.

**Spec:** `docs/superpowers/specs/2026-11-16-iroha3-aps-official-conformance-design.md` (approved 2026-11-16, PR #95).

## Global Constraints

- Upstream iroha commit stays `071e281e`; node image, peer keys, topology and `block_cadence_ms = 1000` unchanged.
- Dataspace aliases `ds-1`, `ds-2`; lanes `lane-1`, `lane-2`; descriptions "private settlement dataspace 1" / "... 2". No `rd`, `dfabi`, `rupiah` in any public catalog, routing, manifest metadata or description.
- `[nexus.atomic_private_settlement]`: `activation_height = 11`, `minimum_activation_notice_blocks = 10`, `max_expiry_blocks = 7200`, the three timeouts `1200` (unchanged).
- Four pools: (lane 1, RD), (lane 1, DFABI), (lane 2, RD), (lane 2, DFABI); one activation transaction per dataspace, instruction order and dataspace order randomized; same auditor set (BI only, `min_approvals = 1`) for all pools.
- `reimbursement_leg_ordinal = 0`; reimbursement = 1 unit of leg 0's asset; leg 0 is always the lower lane (canonical order).
- Companion leg = same asset as the main leg, BI → BI, amount 1, in the other dataspace. Amount 0 legs are forbidden upstream.
- Sponsor = dedicated account `sponsor` with its own seed and note key; never the BI wallet, governance, validator or auditor key.
- Durable coordinator state holds no witness, seed, note key or plaintext amount/party/asset.
- Never reintroduce a global lock held across a leg proof or settle (node-build #43); own proofs stay serialized by `prove_lock` (node-build #42).
- User GO required before Task 11 (gates), Task 12 (snapshot + reset) and Task 14 (Lensa roll). Gate failure = stop and report, no automatic fallback.
- Retired at reset: Job `aps-run`, Deployments `auditor` in `rd-iroha3-bank-a` and `rd-iroha3-bank-b`. Their keys and `audit-store` PVCs are kept.

## Review Focus

1. A single-asset payment no single pool covers but both pools together do: split into two real legs, finalized, exact deltas (Task 3 test `split_when_no_single_pool_covers`, Task 11 gate step).
2. Coordinator killed between Prepare registration and Commit: on restart it resumes the same bundle to final, submits no second carrier (Task 6 test `resume_after_registration_submits_one_carrier`, Task 11 G3).
3. Leg 0 carries DFABI: payer is charged 1 DFABI reimbursement, auditor approves, sponsor can spend it (Task 3 test `reimbursement_follows_leg0_asset`, Task 11 G1).
4. A new `/aps/submit` arrives while a resumed bundle is in flight: it waits on `submit_lock`, both finish (Task 6 test `submit_waits_for_resumed_bundle`).
5. Old `pools.json` (`{rd, dfabi}` shape) on the live chain loads and its history, wallet and carriers still show (Task 1 test `legacy_pool_file_loads`).

---

## Part A — Driver (repo `iroha3-rd-node-build`, branch `feat/aps-conformance`)

### Task 1: Pool index keyed by (lane, asset)

**Files:**
- Modify: `driver/src/pools.rs:53-200` (`Asset`, `PoolRecord`, `PoolFile`, `kept`, `fill_heights`, `merge_finalized`, `finalized`)
- Test: `driver/src/pools.rs` (`#[cfg(test)] mod tests`)

**Interfaces:**
- Produces:
  - `#[derive(Serialize, Deserialize, Clone, Copy, PartialEq, Eq, Debug, Hash, PartialOrd, Ord)] #[serde(rename_all = "lowercase")] pub enum Asset { Rd, Dfabi }` (`Asset::name()` becomes `pub`).
  - `#[derive(Serialize, Deserialize, Clone, Copy, PartialEq, Eq, Debug, Hash, PartialOrd, Ord)] pub struct PoolKey { pub lane: u32, pub asset: Asset }`
  - `#[derive(Serialize, Deserialize, Clone)] pub struct PoolEntry { pub lane: u32, pub asset: Asset, #[serde(flatten)] pub record: PoolRecord }`
  - `pub struct PoolFile { pub pools: Vec<PoolEntry>, pub carriers: BTreeMap<String, String> }` with `#[serde(default)]` on `carriers` as today.
  - `PoolFile::get(&self, key: PoolKey) -> Result<&PoolRecord>`; `PoolFile::keys(&self, asset: Asset) -> Vec<PoolKey>` (sorted by lane); `PoolFile::finalized(&self, asset: Asset) -> Vec<BundleRef>` (union over that asset's pools, ledger order by height); `merge_finalized(&mut self, key: PoolKey, ids, heights)`.
  - `PoolFile::load(path)` accepts the legacy shape `{"rd": PoolRecord, "dfabi": PoolRecord, "carriers"?}` and converts it with `lane = cfg-independent mapping recorded in the record's route` — parse lane from `PoolRecord.route` (it is the encoded `PrivateSettlementRouteV1`; take `lane_id`). `save` always writes the v2 shape `{"version": 2, "pools": [...], "carriers": {...}}`.

- [ ] **Step 1: Write failing tests** `legacy_pool_file_loads` (legacy JSON with two records → `keys(Asset::Rd) == [PoolKey{lane:1, asset:Rd}]`, `keys(Asset::Dfabi) == [PoolKey{lane:2, asset:Dfabi}]`, carriers preserved, `finalized(Rd)` = legacy rd bundles), `four_pools_roundtrip` (save then load 4 entries, equal), `finalized_unions_pools_by_height` (two RD pools, bundles interleaved by height).
- [ ] **Step 2:** `driver/build.sh test` → the three tests fail to compile/run.
- [ ] **Step 3:** Implement the types and conversions; replace every `pools.rd` / `pools.dfabi` / `PoolFile::get(asset)` call in `pools.rs`, `aps_real.rs`, `aps.rs` with `get(key)` where a key is known, and with `keys(asset)` loops where all pools of an asset are meant (wallet, history, kept heights).
- [ ] **Step 4:** `driver/build.sh test` → all tests pass (existing 194 + new).
- [ ] **Step 5:** Commit `feat(driver): pool index keyed by (lane, asset), legacy pools.json loads`.

### Task 2: Pool activation per dataspace (`pool-add`, new `pool-init`)

**Files:**
- Modify: `driver/src/pools.rs:345-388` (`pool_init`), `driver/src/main.rs` (CLI)
- Test: `driver/src/pools.rs` tests

**Interfaces:**
- Consumes: Task 1 `PoolKey`, `PoolEntry`, `PoolFile`.
- Produces:
  - `pub fn pool_add(cfg: &Config, lane: u32, reserves: &[(Asset, u128)], rng: &mut impl rand::Rng) -> Result<Vec<PoolKey>>` — ONE transaction with one `ActivatePrivateSettlementPoolV1` per reserve, instruction order shuffled with `rng`, signed by `cfg.acting_sponsor()` (today = the BI governance key; Task 5 switches this call to `Config::governance()`); writes the origin note per pool to `key_dir/bi.origin-<lane>-<asset>.note` (legacy `bi.origin-<asset>.note` still read for lane-legacy pools); appends `PoolEntry`s under the pools-file lock. Refuses a key already present.
  - `pub fn pool_init(cfg: &Config, plan: &[(u32, Vec<(Asset, u128)>)], rng) -> Result<()>` — requires no pools file; calls `pool_add` per lane in shuffled lane order.
  - CLI: `rd-dfabi pool-add <config> --lane <n> [--rd <amount>] [--dfabi <amount>]` and `rd-dfabi pool-init <config> --lane 1 --rd A --dfabi B --lane 2 --rd C --dfabi D`.
  - Pure helper for testing: `fn activation_order(reserves: &[(Asset, u128)], rng) -> Vec<(Asset, u128)>`.

- [ ] **Step 1: Failing tests** `activation_order_is_shuffled` (seeded `StdRng` 0..64 → both orders of `[(Rd,5),(Dfabi,7)]` occur), `pool_add_refuses_existing_key` (pools file with (1,Rd), add (1,Rd) → error before any network call; use a `Config` whose torii is unreachable to prove no call is made).
- [ ] **Step 2:** run tests → fail.
- [ ] **Step 3:** implement; keep the existing "one transaction per pool" comment's reason in the doc comment: one transaction must stay inside ONE dataspace (cross-dataspace activation in one tx hangs on this cluster, `aps.rs:275-278`).
- [ ] **Step 4:** tests pass.
- [ ] **Step 5:** Commit `feat(driver): pool-add activates several pools of one dataspace in one shuffled transaction`.

### Task 3: Capacity endpoint and bundle planner

**Files:**
- Create: `driver/src/plan.rs`
- Modify: `driver/src/aps_http.rs` (`parse_submit` returns a request, not legs; new `POST /aps/capacity`; `LegCtx`, `LegReq` carry `lane` and `asset`), `driver/src/aps_real.rs` (`capacity`), `driver/src/main.rs` (`mod plan`)
- Test: `driver/src/plan.rs` tests, `driver/src/aps_http.rs` tests

**Interfaces:**
- Produces in `plan.rs`:
  - `pub enum Request { Pay { asset: Asset, from: String, to: String, amount: u128, intent: String }, Dvp { buyer: String, seller: String, rd: u128, dfabi: u128, intent_rd: String, intent_dfabi: String } }`
  - `#[derive(Clone, Copy, Default, Serialize, Deserialize)] pub struct Capacity { pub two_notes: u128, pub total: u128 }` — `two_notes` = the largest amount one leg can spend from that pool = (sum of the two largest unspent notes, or the single note if only one) − 1, because `wallet::pick_notes` needs a note/pair strictly greater than the amount (change output); 0 when the pool holds no note. `total` = all unspent.
  - `pub struct PlannedLeg { pub key: PoolKey, pub payer: Option<String>, pub recipient: Option<String>, pub amount: u128, pub intent: Option<String> }` (`None` payer/recipient = coordinator BI, as today's companion).
  - `pub fn plan(req: &Request, lanes: [u32; 2], cap: &dyn Fn(Option<&str>, PoolKey) -> Capacity, rng: &mut impl rand::Rng) -> Result<[PlannedLeg; 2], PlanError>`; output sorted by lane ascending; `PlanError::Insufficient(String)` maps to HTTP 422 with message `no pool arrangement covers the payment` (no amounts in the message).
- Produces in `aps_http.rs`:
  - `POST /aps/capacity` body `{"asset":"rd"|"dfabi"}` → 200 `{"pools":[{"lane":1,"two_notes":"…","total":"…"}, …]}` for the driver's own party; refused (403) unless the caller is the coordinator (enforced by the gateway policy, Task 9; the driver handler serves only its own wallet).
  - `ApsBackend::capacity(&self, asset: Asset) -> Result<Vec<(u32, Capacity)>>`.
  - `LegCtx` gains `lane: u32, asset: String`; `LegReq` gains `lane: u32, asset: String`.

Planner rules (the spec values, R = 1 reimbursement charged to the payer of the lane-1 leg):
```
Pay X from P to Q amount a:
  single(L): main (L,X) P→Q a ; companion (L',X) BI→BI 1 ; feasible if
             cap(P,(L,X)).two_notes >= a + R*[L==lanes[0]] and cap(BI,(L',X)).two_notes >= 1 + R*[L'==lanes[0]]
  if P is BI (issuance): among feasible L prefer smaller cap(Q,(L,X)).total, ties random; else uniform random among feasible.
  if none feasible: split: a1 = min(cap(P,(l0,X)).two_notes - R, a - 1), a2 = a - a1;
             feasible if a1 >= 1, a2 >= 1, a2 <= cap(P,(l1,X)).two_notes → legs (l0,X) P→Q a1 and (l1,X) P→Q a2 (both carry P's intent)
  else Insufficient.
Dvp buyer B seller S rd r dfabi d:
  option(L): RD leg (L,RD) B→S r, DFABI leg (L',DFABI) S→B d; feasible if
             cap(B,(L,RD)).two_notes >= r + R*[L==lanes[0]] and cap(S,(L',DFABI)).two_notes >= d + R*[L'==lanes[0]]
  uniform random among feasible; else Insufficient.
```
Intent consumption for a split pay: the payer's single intent covers the total `a`; the payer's `/aps/leg` handler accepts two legs for one intent when their amounts sum to the intent amount (store remaining amount in `IntentStore`).

- [ ] **Step 1: Failing tests in `plan.rs`:** `single_leg_with_same_asset_companion` (companion asset == main asset, payer/recipient None, amount 1, legs sorted by lane), `issuance_prefers_recipients_smaller_pool`, `split_when_no_single_pool_covers` (P caps 6 and 5, a = 9 → amounts 5 on lane 1 and 4 on lane 2), `reimbursement_follows_leg0_asset` (DFABI pay forced onto lane 1 by caps → leg 0 asset Dfabi and payer needs a+1), `dvp_picks_only_feasible_arrangement`, `insufficient_names_no_amount` (error text has no digits), `placement_is_random` (equal caps, seeded rng 0..64 → both lanes chosen for the main leg).
- [ ] **Step 2: Failing tests in `aps_http.rs`:** `capacity_answers_per_pool`, `split_intent_covers_two_legs` (one intent amount 9, legs 5 then 4 accepted, a third leg refused 403), existing route tests updated to the 422 message.
- [ ] **Step 3:** run → fail.
- [ ] **Step 4:** implement `plan.rs`; `coordinate()` asks `/aps/capacity` of each non-BI party it needs (payer; recipient too for issuance) and the backend for BI, calls `plan`, then proceeds with the planned legs (addresses, sponsor outputs, parallel proofs exactly as today). `begin_bundle` takes the two `PoolKey`s (Task 4).
- [ ] **Step 5:** tests pass.
- [ ] **Step 6:** Commit `feat(driver): plan bundles from per-pool capacities; same-asset companion, random placement, split payments`.

### Task 4: Backend over planned pools

**Files:**
- Modify: `driver/src/pools.rs` (`begin_bundle`, `settle_bundle`, `prove_split_leg`, `run_bundle`, `pay`, `dvp`, `wallet_json`, `record_end`), `driver/src/aps_real.rs` (`begin_bundle`, `prove_leg`, `settle`, `bundles`, `wallet`), `driver/src/aps.rs:1086-1160` (`proof_manifest` reimbursement terms from leg 0's pool)
- Test: `driver/src/aps_real.rs` tests, `driver/src/pools.rs` tests

**Interfaces:**
- Consumes: Task 1 index, Task 3 `PlannedLeg`, `LegReq.lane/asset`.
- Produces:
  - `pub(crate) fn begin_bundle(cfg: &Config, keys: [PoolKey; 2]) -> Result<BundleStart>` (keys sorted by lane; `BundleStart.legs` also carries the key).
  - `pub(crate) fn settle_bundle(cfg: &Config, keys: [PoolKey; 2], manifest, prepared) -> Result<Option<(String, u64)>>`.
  - `pub(crate) fn prove_split_leg(cfg: &Config, payer: &str, key: PoolKey, leg: &SplitLeg) -> Result<…>`; reimbursement `SPONSOR_REIMBURSEMENT` applies when `leg.ordinal == 0` regardless of asset.
  - `wallet_json` aggregates per asset across pools: `balances.rd = Σ RD pools`, items keep one row per (bundle, asset) with `carrier_tx`, and a row's `fee` = `"1"` when the party paid leg 0 of that bundle (any asset).
  - CLI `pay`/`dvp` call `plan::plan` with locally computed capacities (BI-only CLI), then `run_bundle(cfg, planned, …)`.
- [ ] **Step 1: Failing tests:** `begin_bundle_uses_given_pools` (fake pools file with 4 entries; manifest legs' pool ids equal the two keys' pool ids in lane order), `wallet_sums_pools_per_asset` (two RD pools with notes 3 and 4 → `balances.rd == "7"`), `fee_marks_leg0_payer_any_asset`.
- [ ] **Step 2:** run → fail. **Step 3:** implement. **Step 4:** pass (all suites).
- [ ] **Step 5:** Commit `feat(driver): bundles, proofs, wallet and history over any two planned pools`.

### Task 5: Neutral sponsor

**Files:**
- Modify: `driver/src/config.rs:60-72,200-217` (`ApsConfig`, `acting_sponsor`, new `governance`), `driver/src/aps_real.rs:100-108` (`sponsor_output`), `driver/src/pools.rs` (`pool_add`/`pool_init`/`abort_bundle` signer), `driver/src/main.rs` (`wallet sponsor`)
- Test: `driver/src/config.rs` tests, `driver/src/aps_real.rs` tests

**Interfaces:**
- Produces:
  - `ApsConfig.sponsor: Option<SponsorConfig>` with `#[derive(Clone, Debug, Deserialize)] pub struct SponsorConfig { pub name: String, pub dir: PathBuf }` (TOML `[aps.sponsor] name = "sponsor"`, `dir = "/keys-sponsor"`). The dir holds `sponsor.seed`, `sponsor.note` and `client.toml` (generated by the existing `rd-dfabi keys client-toml` = `client_toml::write(dir, "sponsor", …)`, which always names the file `client.toml`, hence a separate dir from BI's keys).
  - `Config::acting_sponsor()` → client/key from `<dir>/client.toml` when `sponsor` is set, else today's behaviour (gate-compat on the old chain before the key exists). `Config::sponsor_note_keys()` reads `<dir>/<name>.note`.
  - `Config::governance() -> Result<(Client, KeyPair)>` = today's `sponsor(&self.party)`; used only by `pool_add`, `pool_init`.
  - `sponsor_output` builds the reimbursement output key from `cfg.sponsor_note_keys()?.one_time(&bundle, &pool, 2)` (not `NoteKeys::random()`); `pool_add`/`pool_init` switch from `acting_sponsor()` to `governance()`.
  - `rd-dfabi wallet <config> sponsor` lists the sponsor's reimbursement notes.
- [ ] **Step 1: Failing tests:** `acting_sponsor_uses_sponsor_section`, `governance_stays_party_key`, `reimbursement_output_belongs_to_sponsor` (open the output with the sponsor note keys succeeds; with BI's fails).
- [ ] **Step 2–4:** fail → implement → pass.
- [ ] **Step 5:** Commit `feat(driver): dedicated sponsor account; reimbursement spendable by the sponsor`.

### Task 6: Restart-safe coordinator, upstream upload, governed limits, receipt checks

**Files:**
- Create: `driver/src/inflight.rs`
- Modify: `driver/src/aps.rs:360-470` (upload, prepare, register, commit), `:633-635` (`max_carrier_bytes`), `:653-687` (`wait_receipt`), `driver/src/pools.rs:257-275` (receipt cache), `driver/src/server.rs:181-195` (resume at start), `driver/src/aps_http.rs` (`submit` holds `submit_lock` during resume)
- Test: `driver/src/inflight.rs` tests, `driver/src/aps_http.rs` tests

**Interfaces:**
- Produces:
  - `inflight.rs`: `#[derive(Serialize, Deserialize)] pub struct Inflight { pub bundle_id: String, pub keys: [PoolKey; 2], pub manifest: String /* enc */, pub prepared: Vec<String> /* enc AtomicPrivateSettlementPreparedLegV1 */, pub phase: Phase }`, `pub enum Phase { Proved, Uploaded, Registered, Committed }`; `pub fn save(dir: &Path, f: &Inflight) -> Result<()>` (temp + rename), `pub fn load_all(dir: &Path) -> Result<Vec<Inflight>>`, `pub fn remove(dir: &Path, id: &str) -> Result<()>`. Directory: `<pools_file parent>/inflight/`.
  - `pub(crate) fn resume(cfg: &Config, f: Inflight) -> Result<Option<(String, u64)>>` in `pools.rs`: reads the public bundle status; terminal → record end; else continues from `f.phase` using only node-held certificates.
  - `ApsBackend::resume_all(&self) -> Result<()>`; `server::run` spawns it in a thread that holds `Aps::submit_lock` until done (the HTTP listener starts immediately so `/healthz` answers).
- Behaviour pinned by the spec:
  - Upload via upstream `certify_and_upload_private_settlement_legs_v1` (client:2527).
  - Prepare via `recover_or_prepare_private_settlement_bundle_v1` (client:1870); Commit via `recover_or_commit_private_settlement_bundle_v1` (client:2138); never build a certificate from local files.
  - `max_carrier_bytes`: upstream says the caller must pass "the active governed limit obtained for the target deployment" (client:2283); the node reads it from `[nexus.atomic_private_settlement] max_carrier_bytes` (`iroha_config` actual.rs:2645) and Torii exposes no read for it. So add `ApsConfig.max_carrier_bytes: Option<u64>`; Task 9's renderer copies the peer config value (or the upstream default when the peer config omits it); the driver refuses to start the coordinator if it is absent or 0. Replace the V1-constant use at `aps.rs:633-635`.
  - `wait_receipt` also checks `receipt.manifest == manifest` (error `receipt manifest differs`).
  - Receipt cache: a cached receipt is used only if its bundle id and finalized height equal the pools-file record; otherwise refetch and overwrite.
  - Committee: grep `crates/iroha/src/client` for a method returning the lane roster at `authority_context_height`. If one exists, build the committee from it and keep `peers.json` for URLs only; if none exists, keep `peers.json` and record "committee from peers.json, validators re-check against state" as a residual in the Task 13 report.
  - Persist `Inflight` after each phase transition; delete after the end is recorded.
- [ ] **Step 1: Failing tests:** `inflight_roundtrip_has_no_secrets` (serialized JSON contains none of: seed hex, note key hex, the amount as decimal, account ids), `resume_after_registration_submits_one_carrier` (fake chain: status Registered, carrier count after resume == 1), `submit_waits_for_resumed_bundle` (resume holding lock 300 ms; a submit started at 50 ms finishes after it), `receipt_with_other_manifest_is_rejected`.
- [ ] **Step 2–4:** fail → implement (fakes extend `testkit::FakeBackend`) → pass.
- [ ] **Step 5:** Commit `feat(driver): restart-safe coordinator (recover_or_prepare, durable in-flight store), upstream upload, governed carrier limit, receipt checks`.

### Task 7: Release driver image

- [ ] **Step 1:** `gh pr create` from `feat/aps-conformance` with RED/GREEN commits per task; wait for `driver-test` green (expect up to ~65 min on an upstream recompile).
- [ ] **Step 2:** Merge, `gh workflow run build-driver.yml --ref main`, read the digest from the "Digest (pin by digest, never by tag)" step (`digest=sha256:…`). Record it as **D18**.

## Part B — Network and deploy (repo `iroha3-rd-dfabi`, branch `feat/aps-conformance-net`)

### Task 8: Neutral genesis and sponsor account

**Files:**
- Modify: `network/nexus.toml:30-60` (aliases `ds-1`/`ds-2`, lanes `lane-1`/`lane-2`, neutral descriptions; `manifest_hash` unchanged), `network/genesis-rd-dfabi.jq` (register `sponsor` account from `public/sponsor.pub`, transfer XOR for fees, grant `CanReadRestrictedDataspace` on dataspaces 1 and 2 only if Task 11 G2 says so — parameter `$sponsor_read` boolean), `network/generate.sh` and `network/check.sh` (alias names, sponsor key input, assert no `rd|dfabi|rupiah` in catalog/routing/descriptions), `network/keygen-party.sh` (`sponsor` party: seed + note key, operator PC only)
- Test: `network/check.sh` (existing harness) + new assertion lines

**Interfaces:**
- Produces: `public/sponsor.pub`, Secret `sponsor-keys` (keys `sponsor.seed`, `sponsor.note`, `client.toml`) in `rd-iroha3-bi` created by `deploy/secrets.sh sponsor`; mounted read-only at `/keys-sponsor` in the BI driver only.
- [ ] **Step 1:** add check.sh assertions (no asset words in public catalog; sponsor account registered and funded; four pools are NOT in genesis — activation needs height ≥ 11). Run → fail.
- [ ] **Step 2:** implement; run `network/check.sh` → pass. **Step 3:** Commit.

### Task 9: Driver render, gateway policy, retirement

**Files:**
- Modify: `deploy/driver/render.py` (mount `sponsor-keys` at `/keys-sponsor` into the BI driver only; `[aps.sponsor]` section; `[aps] max_carrier_bytes` copied from the rendered peer config; `[lanes]` 1/2 unchanged), `scripts/check-driver.py` (assert sponsor mount on bi only), `deploy/gateway/policy/iroha3.rego` + `data.json` (row 20: `POST /aps/capacity`, caller bi, every node) + `deploy/gateway/policy/test/iroha3_test.rego`, `deploy/aps-run/render.py` and `deploy/auditor/render.py` (header `RETIRED 2026-11-16`, renderer exits non-zero for bank-a/bank-b), `deploy/pool-init/render.py` (new CLI shape from Task 2)
- [ ] **Step 1:** opa test for row 20 (bi allowed, bank-a 403, lensa 403) and check-driver assertion → fail.
- [ ] **Step 2:** implement → `opa test deploy/gateway/policy` and `scripts/test-driver.sh` pass.
- [ ] **Step 3:** Commit; PR for Tasks 8–9; CI green; merge. Record merge SHA as **RC2**.

## Part C — Lensa (repo `rd-lensa-frontend`, branch `feat/iroha3-pool-index`)

### Task 10: Lensa reads the pool index v2

**Files:**
- Modify: `server/src/adapters/iroha3.ts:477-483` (`poolHeights` unions `pools[].bundles`, still accepts legacy `rd/dfabi`), fee display (fee on the leg-0 payer row of either asset), lens labels for outsiders "Pool 1 (ds-1)" / "Pool 2 (ds-2)" without asset names (spec 4.6)
- Test: `server/test/iroha3-*.test.ts`
- [ ] **Step 1:** failing tests `pool heights come from every pool (v2 file)`, `legacy pools.json still yields heights`, `outsider lens names no asset`. **Step 2:** fail. **Step 3:** implement. **Step 4:** `npx vitest run` all pass, `tsc --noEmit` clean. **Step 5:** PR, CI, merge, `gh workflow run publish.yml --ref main`; record digest **L1** (not rolled yet).

## Part D — Live (ops scripts in `~/agent-texts/iroha/`)

### Task 11: Gates G1–G4 on the current chain — **user GO #1 first**

- [ ] **Step 1:** Ask the user for GO naming: driver roll to D18 on 4 parties (`d2.sh`, `RC=RC2`), register account `sponsor` + fund XOR on the live chain, `pool-add --lane 2 --rd 1000000 --dfabi 1` (one tx; the second DFABI pool on lane 2 is a throw-away to test multi-instruction activation), `pool-add --lane 1 --dfabi 1000`, and ≤ 8 test bundles.
- [ ] **Step 2:** Tell besu/fabricx sessions that iroha3 writes via Lensa are unavailable until Step 3 ends (with only the legacy pools, a same-asset companion has no pool in the other dataspace and the planner answers 422). Roll D18 (legacy pools.json must load: `GET /aps/wallet` for 4 parties equals pre-roll balances).
- [ ] **Step 3 (G4):** run the lane-2 `pool-add` (RD + throw-away DFABI, one tx) and the lane-1 `pool-add` (DFABI); pass = the lane-2 pools active in ONE block, every party's planner sees 4 indexed pools.
- [ ] **Step 4 (G1):** rd-issue BI→A 10 (planner should pick lane 2 for A), rd-transfer A→C 3 with main leg forced onto lane 2 (cap) and companion RD BI→BI on lane 1, a DFABI pay whose leg 0 is DFABI; pass = final, exact deltas (reimbursement 1 in leg-0 asset), auditor approved. Then a split pay (A holds RD in both pools, amount > each pool) → two real legs, final.
- [ ] **Step 5 (G2):** with `[aps.sponsor]` live, one bundle; record whether status polling with the sponsor key needs `CanReadRestrictedDataspace` (look for 403/404 on bundle status/receipt). Set `$sponsor_read` for Task 12 accordingly (PR if it changes).
- [ ] **Step 6 (G3):** start a pay, `kubectl delete pod` the BI driver when its log shows `prepare registered` (and once more at upload); pass = after restart the same bundle id finalizes, one carrier, no second bundle, balances exact.
- [ ] **Step 7:** Report gate results to the user. Any failure → stop.

### Task 12: Snapshot and reset — **user GO #2 first**

- [ ] **Step 1:** GO text names: scale peers/drivers/auditors to 0; `VolumeSnapshot` (class `alibabacloud-disk-snapshot`) of every PVC in `rd-iroha3-{bi,bank-a,bank-b}` (cluster 1) and `rd-iroha3-bank-c` (cluster 2); wipe peer state; new genesis (RC2, `$sponsor_read`); delete Job `aps-run`, Deployments `auditor` in bank-a/bank-b (keep their Secrets and `audit-store` PVCs); `pool-init` 4 pools; funding.
- [ ] **Step 2:** take snapshots; wait `readyToUse=true` for all; record names in `~/agent-texts/iroha/rollback/reset-<UTC>/snapshots.txt`.
- [ ] **Step 3:** run the reset (extend `netreset.sh` → `netreset2.sh`: new genesis, same keys), wait 4/4 peers at the same height ≥ 12.
- [ ] **Step 4:** delete the retired objects; roll BI auditor and 4 drivers (D18, RC2); wipe driver `pools-v2` PVC content except keys.
- [ ] **Step 5:** `pool-init --lane 1 --rd 500000000 --dfabi 500000 --lane 2 --rd 500000000 --dfabi 500000` (spec 7: 50/50 split of the current 1e9 RD / 1e6 DFABI reserves); pass = four pools, two transactions, randomized order logged.
- [ ] **Step 6:** fund banks back to the 2026-11-16 12:40Z balances rounded (A 1.9M RD/118 DFABI, B 1.8M/210, C 2.7M/282) via issuance through `/aps/submit` (planner balances pools); verify `/aps/wallet` per party.

### Task 13: Qualification on the new chain

**Files:**
- Create: `~/agent-texts/iroha/qual.py` (direct driver calls through the party gateways, as `live-aps.py`), `~/agent-texts/iroha/canary.sh`, repo `reports/aps-qualification-2026-11.md`
- [ ] **Step 1:** latency: per flow (rd-issue, rd-transfer, dfabi-transfer, dvp, award) 5 warm-up + 30 measured bundles, sequential. Amounts sized so the Task 12 balances cover all 35 runs without top-up (spec 4.7): rd-issue 1000 RD to rotating banks, rd-transfer 10 RD and dfabi-transfer 1 DFABI alternating direction A→B / B→A, dvp and award rd 1000 / dfabi 1 alternating buyer and seller (Lensa's fixed 1,000,000 RD per DFABI unit is not used here; qual.py calls the drivers directly); record submit→final ms, CPU/memory (`kubectl top`), proof and receipt bytes; compute p50/p95/p99 and a bootstrap 95% CI; balances checked after each flow.
- [ ] **Step 2:** restart/fault: validator restart (1 of 4, rolling, `peerroll.sh` rules: all 4 healthy first, never two down) mid-bundle; coordinator restart at upload/Prepare/Commit; bank driver restart while proving. Pass = every bundle final or cleanly aborted/expired, 4-party balances consistent.
- [ ] **Step 3:** canary: one bundle with amount 7777777 and the canary flag; `canary.sh` greps logs of every pod in the 4 namespaces, public Torii bundle/receipt JSON, block JSON at that height, and the Lensa outsider lens for `7777777`, the payer/recipient account ids and the words RD/DFABI; pass = zero hits outside the payer's and recipient's own drivers and the BI auditor.
- [ ] **Step 4:** write the report (commit ids, D18, RC2, hardware: node type and limits, raw samples as CSV next to it); list the external gates not run (spec 5) and residuals (Task 6 committee note if any). Commit to `iroha3-rd-dfabi`.

### Task 14: Lensa on the new chain — **user GO #3 first**

- [ ] **Step 1:** GO text names: Lensa image L1 and the new `iroha3.json` state; coordinate the Lensa lock with besu/fabricx sessions.
- [ ] **Step 2:** roll Lensa; `lensa-e2e.py write` for all enabled flows + `read`; Playwright `iroha3.flows.spec.ts` against the public URL. Pass = all flows final, read checks pass, outsider lens shows no asset name.
- [ ] **Step 3:** update memory and the design doc status; tell the other sessions "done".
