//! M1 commands that need no chain: keys init, pool activate (plan only), balances, doctor.
//! Each takes the store and a `Backend`, so the light build and the tests run without iroha.

use std::collections::{BTreeMap, BTreeSet};

use crate::{
    api::*,
    backend::{Backend, NoteMaterial, err},
    store::{NoteRecord, NoteState, PoolFile, Store, hex32, kdf, party_dir, unhex32},
    tree::NoteTree,
};

/// Upstream limit on initial commitments per pool (crates/iroha_data_model/src/privacy/credentials.rs:137).
pub const MAX_POOL_NOTES: usize = 4096;
const ALL_PARTIES: [Party; 4] = [Party::BI, Party::A, Party::B, Party::C];
const ALL_ASSETS: [Asset; 2] = [Asset::Rd, Asset::Dfabi];

fn io<T>(r: Result<T, String>) -> Result<T, ErrorBody> {
    r.map_err(|m| err("internal", m, false))
}

fn bad(msg: impl Into<String>) -> ErrorBody {
    err("bad_request", msg, false)
}

fn asset_name(a: Asset) -> &'static str {
    match a {
        Asset::Rd => "RD",
        Asset::Dfabi => "DFABI",
    }
}

// ---- keys init -------------------------------------------------------------------------------

pub fn keys_init(store: &Store, backend: &dyn Backend, req: KeysInitReq, seed: [u8; 32]) -> Result<KeysInitResp, ErrorBody> {
    let _lock = io(store.lock(&format!("wallet-{}", party_dir(req.party))))?;
    io(store.create_seed(req.party, req.force, seed)).map_err(|e| bad(e.message))?;
    // Receive slot 0: the key pair a payer can send a first note to. Later slots follow the same labels.
    let view_secret = kdf(&seed, "receive/0/view");
    let spend_secret = kdf(&seed, "receive/0/spend");
    Ok(KeysInitResp {
        party: req.party,
        wallet_dir: format!("wallets/{}", party_dir(req.party)),
        receive_view_key: backend.view_public(&view_secret).ok().map(|k| hex32(&k)),
        receive_authority: backend.authority(&spend_secret).ok().map(|k| hex32(&k)),
        // ponytail: BI auditor Ed25519 + hybrid X25519/ML-KEM-768 keys need iroha_crypto; added with the aps build.
        auditor_encryption_key: None,
    })
}

// ---- pool activate (plan only) ---------------------------------------------------------------

/// Everything the activation transaction and the wallets need, before anything is written or sent.
pub struct PoolDraft {
    pub asset: Asset,
    pub pool_id: [u8; 32],
    pub namespace: Vec<u8>,
    /// Origin commitments, strictly increasing (the ledger rejects any other order).
    pub leaves: Vec<[u8; 32]>,
    pub origin_root: [u8; 32],
    /// Owner of each note, aligned with `notes`.
    pub owners: Vec<Party>,
    pub notes: Vec<NoteRecord>,
}

fn parse_amount(s: &str) -> Result<u128, ErrorBody> {
    if s.is_empty() || !s.bytes().all(|b| b.is_ascii_digit()) {
        return Err(bad(format!("amount '{s}' is not a decimal integer")));
    }
    let v: u128 = s.parse().map_err(|_| bad(format!("amount '{s}' exceeds u128")))?;
    if v == 0 {
        return Err(bad("a zero-value note cannot be seeded"));
    }
    Ok(v)
}

/// Pure: derive every origin note from the owners' seeds, sort by commitment, build the origin tree.
pub fn build_pool(store: &Store, backend: &dyn Backend, plan: &PoolPlan, pool_id: [u8; 32]) -> Result<PoolDraft, ErrorBody> {
    let total: usize = plan.holders.iter().map(|h| h.notes.len()).sum();
    if total == 0 || total > MAX_POOL_NOTES {
        return Err(bad(format!("{} pool needs 1..={MAX_POOL_NOTES} initial notes, got {total}", asset_name(plan.asset))));
    }
    let mut seen = BTreeSet::new();
    let namespace = backend.pool_namespace(&pool_id)?;
    let pool_hex = hex32(&pool_id);
    let mut rows: Vec<([u8; 32], Party, NoteRecord)> = Vec::with_capacity(total);
    let mut index = 0usize;
    for holder in &plan.holders {
        if !seen.insert(holder.party) {
            return Err(bad(format!("holder {} listed twice in the {} plan", party_dir(holder.party), asset_name(plan.asset))));
        }
        let seed = io(store.seed(holder.party)).map_err(|e| err("no_such_wallet", e.message, false))?;
        for value in &holder.notes {
            let value = parse_amount(value)?;
            // The pool id is in the label, so a re-seeded chain never reuses note secrets.
            let label = format!("note/{}/{}/{}", asset_name(plan.asset), pool_hex, index);
            index += 1;
            let spend = kdf(&seed, &format!("{label}/spend"));
            let material = NoteMaterial {
                value,
                authority: backend.authority(&spend)?,
                rho: kdf(&seed, &format!("{label}/rho")),
                blinding: kdf(&seed, &format!("{label}/blinding")),
                memo_digest: kdf(&seed, &format!("{label}/memo")),
            };
            let commitment = backend.commitment(&material)?;
            rows.push((
                commitment,
                holder.party,
                NoteRecord {
                    asset: plan.asset,
                    pool: pool_hex.clone(),
                    commitment: hex32(&commitment),
                    value: value.to_string(),
                    label,
                    state: NoteState::PendingActivation,
                    bundle: None,
                },
            ));
        }
    }
    rows.sort_by(|a, b| a.0.cmp(&b.0));
    let mut tree = NoteTree::new(namespace.clone());
    for (c, _, _) in &rows {
        tree.append(*c).map_err(|m| err("internal", format!("origin set: {m}"), false))?;
    }
    Ok(PoolDraft {
        asset: plan.asset,
        pool_id,
        namespace,
        leaves: rows.iter().map(|r| r.0).collect(),
        origin_root: tree.root(),
        owners: rows.iter().map(|r| r.1).collect(),
        notes: rows.into_iter().map(|r| r.2).collect(),
    })
}

/// M1 builds and reports the plan. Submission (governance key, `ActivatePrivateSettlementPoolV1`) is the aps build:
/// a non-dry run is refused so a half-wired helper can never send a transaction or write wallet state.
pub fn pool_activate(store: &Store, backend: &dyn Backend, req: &PoolActivateReq, mut new_pool_id: impl FnMut() -> [u8; 32]) -> Result<PoolActivateResp, ErrorBody> {
    if !req.dry_run {
        return Err(err("not_implemented", "pool activate submits with the aps build; M1 only supports dry_run", false));
    }
    if req.plans.is_empty() {
        return Err(bad("no pool plans"));
    }
    let mut assets = BTreeSet::new();
    let mut pools = Vec::new();
    for plan in &req.plans {
        if !assets.insert(plan.asset) {
            return Err(bad(format!("{} planned twice", asset_name(plan.asset))));
        }
        if let Some(p) = io(store.pool(plan.asset))? {
            if p.status == "active" {
                return Err(bad(format!("{} pool already active; supply is fixed at activation, a new pool needs a new chain", asset_name(plan.asset))));
            }
        }
        let d = build_pool(store, backend, plan, new_pool_id())?;
        pools.push(PoolInfo {
            asset: d.asset,
            pool_id: hex32(&d.pool_id),
            route: None,
            asset_binding_commitment: None,
            origin_root: hex32(&d.origin_root),
            notes: d.notes.len() as u32,
            tx_hash: None,
            block: None,
        });
    }
    Ok(PoolActivateResp { pools, dry_run: true })
}

// ---- balances --------------------------------------------------------------------------------

/// Sum of `Unspent` notes only. Pending, planned and spent notes never count (a crash mid-bundle must not show money).
pub fn balances(store: &Store, req: &BalancesReq) -> Result<BalancesResp, ErrorBody> {
    let parties: Vec<Party> = req.party.map(|p| vec![p]).unwrap_or_else(|| ALL_PARTIES.to_vec());
    let mut out = Vec::new();
    for party in parties {
        let mut by_asset: BTreeMap<Asset, (u128, u32, u128)> = ALL_ASSETS.iter().map(|a| (*a, (0, 0, 0))).collect();
        for n in io(store.notes(party))? {
            if n.state != NoteState::Unspent {
                continue;
            }
            let v: u128 = n.value.parse().map_err(|_| err("internal", format!("note {} has a bad value", n.commitment), false))?;
            let e = by_asset.entry(n.asset).or_default();
            e.0 = e.0.checked_add(v).ok_or_else(|| err("internal", "balance exceeds u128", false))?;
            e.1 += 1;
            e.2 = e.2.max(v);
        }
        for (asset, (total, notes, largest)) in by_asset {
            out.push(Balance { party, asset, total: total.to_string(), notes, largest_note: largest.to_string() });
        }
    }
    Ok(BalancesResp { balances: out })
}

// ---- doctor ----------------------------------------------------------------------------------

fn check(name: impl Into<String>, ok: bool, detail: impl Into<String>) -> DoctorCheck {
    DoctorCheck { name: name.into(), ok, detail: detail.into() }
}

/// Local consistency only. Chain reads (height, capability, committee authorities, sponsor XOR) arrive with the aps build.
pub fn doctor(store: &Store) -> Result<DoctorResp, ErrorBody> {
    let mut checks = vec![check("home_mode", store.root_mode() == Some(0o700), format!("{:o}", store.root_mode().unwrap_or(0)))];
    for p in ALL_PARTIES {
        let name = format!("wallet_{}", party_dir(p));
        if store.has_seed(p) {
            let mode = store.seed_mode(p).unwrap_or(0);
            checks.push(check(name, mode == 0o600, format!("seed.key mode {mode:o}")));
        } else {
            checks.push(check(name, false, "no wallet"));
        }
    }
    for asset in ALL_ASSETS {
        let name = format!("pool_{}", asset_name(asset).to_lowercase());
        match io(store.pool(asset))? {
            None => checks.push(check(name, false, "no pool file")),
            Some(f) => checks.push(pool_check(name, &f)),
        }
    }
    checks.push(check("chain_reads", false, "not implemented: needs the aps build"));
    Ok(DoctorResp { height: None, aps_active: None, checks })
}

fn pool_check(name: String, f: &PoolFile) -> DoctorCheck {
    let Ok(ns) = hex::decode(&f.namespace_hex) else { return check(name, false, "namespace_hex is not hex") };
    let mut tree = NoteTree::new(ns);
    for l in &f.leaves {
        match unhex32(l).and_then(|c| tree.append(c)) {
            Ok(_) => {}
            Err(m) => return check(name, false, format!("leaf rejected: {m}")),
        }
    }
    let ok = hex32(&tree.root()) == f.head_root;
    check(name, ok, format!("{} leaves, status {}, root {}", f.leaves.len(), f.status, if ok { "matches" } else { "DIFFERS from head_root" }))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        backend::{FakeBackend, NoAps},
        store::{cleanup, test_home},
    };

    fn setup(tag: &str) -> (std::path::PathBuf, Store) {
        let home = test_home(tag);
        let s = Store::open(&home).unwrap();
        for (i, p) in ALL_PARTIES.iter().enumerate() {
            keys_init(&s, &FakeBackend, KeysInitReq { party: *p, force: false }, [i as u8 + 1; 32]).unwrap();
        }
        (home, s)
    }

    fn plan() -> PoolActivateReq {
        let h = |p, n: &[&str]| PoolHolder { party: p, notes: n.iter().map(|s| s.to_string()).collect() };
        PoolActivateReq {
            plans: vec![
                PoolPlan { asset: Asset::Rd, holders: vec![h(Party::BI, &["10000", "10000"]), h(Party::A, &["1000", "1000"]), h(Party::B, &["1000", "1000"])] },
                PoolPlan { asset: Asset::Dfabi, holders: vec![h(Party::B, &["100", "100"]), h(Party::C, &["100", "100"])] },
            ],
            governance_client_config: "not-read-in-m1".into(),
            dry_run: true,
        }
    }

    #[test]
    fn keys_init_creates_seed_and_reports_public_slot_when_backend_exists() {
        let home = test_home("keys");
        let s = Store::open(&home).unwrap();
        let r = keys_init(&s, &FakeBackend, KeysInitReq { party: Party::A, force: false }, [9; 32]).unwrap();
        assert!(r.receive_view_key.is_some() && r.receive_authority.is_some());
        assert_eq!(r.wallet_dir, "wallets/a");
        assert_eq!(s.seed_mode(Party::A), Some(0o600));
        // the seed never appears in the response
        assert!(!serde_json::to_string(&r).unwrap().contains(&hex::encode([9u8; 32])));
        let again = keys_init(&s, &FakeBackend, KeysInitReq { party: Party::A, force: false }, [8; 32]).unwrap_err();
        assert_eq!(again.code, "bad_request");
        assert_eq!(s.seed(Party::A).unwrap(), [9; 32], "failed re-init must not touch the seed");
        cleanup(&home);
    }

    #[test]
    fn keys_init_without_backend_still_makes_the_wallet_and_nulls_the_public_fields() {
        let home = test_home("keys-noaps");
        let s = Store::open(&home).unwrap();
        let r = keys_init(&s, &NoAps, KeysInitReq { party: Party::C, force: false }, [5; 32]).unwrap();
        assert!(r.receive_view_key.is_none() && r.receive_authority.is_none());
        assert!(s.has_seed(Party::C));
        cleanup(&home);
    }

    #[test]
    fn pool_plan_sorts_origin_set_counts_notes_and_is_reproducible() {
        let (home, s) = setup("pool");
        let ids = [[0xA1; 32], [0xA2; 32]];
        let mut n = 0;
        let mut next = || {
            n += 1;
            ids[n - 1]
        };
        let r = pool_activate(&s, &FakeBackend, &plan(), &mut next).unwrap();
        assert!(r.dry_run);
        assert_eq!(r.pools.iter().map(|p| p.notes).collect::<Vec<_>>(), vec![6, 4]);
        // same seeds, same pool id => same origin root; different pool id => different root and different note secrets
        let again = build_pool(&s, &FakeBackend, &plan().plans[0], [0xA1; 32]).unwrap();
        assert_eq!(hex32(&again.origin_root), r.pools[0].origin_root);
        let other = build_pool(&s, &FakeBackend, &plan().plans[0], [0xB1; 32]).unwrap();
        assert_ne!(other.origin_root, again.origin_root);
        assert!(again.leaves.windows(2).all(|w| w[0] < w[1]), "ledger needs strictly increasing origin commitments");
        assert_eq!(again.owners.len(), again.notes.len());
        // dry-run writes nothing
        assert!(s.pool(Asset::Rd).unwrap().is_none());
        assert!(s.notes(Party::A).unwrap().is_empty());
        cleanup(&home);
    }

    #[test]
    fn pool_plan_rejects_bad_requests_and_real_submission() {
        let (home, s) = setup("pool-bad");
        let id = || [1; 32];
        let mut p = plan();
        p.dry_run = false;
        assert_eq!(pool_activate(&s, &FakeBackend, &p, id).unwrap_err().code, "not_implemented");
        let mut p = plan();
        p.plans[0].holders[0].notes = vec!["0".into()];
        assert_eq!(pool_activate(&s, &FakeBackend, &p, id).unwrap_err().code, "bad_request");
        let mut p = plan();
        p.plans[0].holders[0].notes = vec!["1.5".into()];
        assert_eq!(pool_activate(&s, &FakeBackend, &p, id).unwrap_err().code, "bad_request");
        let mut p = plan();
        p.plans[0].holders.push(PoolHolder { party: Party::A, notes: vec!["1".into()] });
        assert_eq!(pool_activate(&s, &FakeBackend, &p, id).unwrap_err().code, "bad_request");
        let mut p = plan();
        p.plans[1].asset = Asset::Rd;
        assert_eq!(pool_activate(&s, &FakeBackend, &p, id).unwrap_err().code, "bad_request");
        let mut p = plan();
        p.plans[0].holders[0].notes = vec!["1".into(); MAX_POOL_NOTES];
        assert_eq!(pool_activate(&s, &FakeBackend, &p, id).unwrap_err().code, "bad_request", "total over the limit");
        assert_eq!(pool_activate(&s, &FakeBackend, &PoolActivateReq { plans: vec![], ..plan() }, id).unwrap_err().code, "bad_request");
        // u128 overflow
        let mut p = plan();
        p.plans[0].holders[0].notes = vec!["340282366920938463463374607431768211456".into()];
        assert_eq!(pool_activate(&s, &FakeBackend, &p, id).unwrap_err().code, "bad_request");
        // holder without wallet
        let home2 = test_home("pool-nowallet");
        let s2 = Store::open(&home2).unwrap();
        assert_eq!(pool_activate(&s2, &FakeBackend, &plan(), id).unwrap_err().code, "no_such_wallet");
        // light build
        assert_eq!(pool_activate(&s, &NoAps, &plan(), id).unwrap_err().code, "aps_not_built");
        cleanup(&home);
        cleanup(&home2);
    }

    #[test]
    fn active_pool_cannot_be_replanned() {
        let (home, s) = setup("pool-active");
        let d = build_pool(&s, &FakeBackend, &plan().plans[0], [3; 32]).unwrap();
        s.put_pool(&PoolFile {
            asset: Asset::Rd,
            pool_id: hex32(&d.pool_id),
            namespace_hex: hex::encode(&d.namespace),
            status: "active".into(),
            leaves: d.leaves.iter().map(hex32).collect(),
            head_root: hex32(&d.origin_root),
            head_epoch: 1,
        })
        .unwrap();
        let e = pool_activate(&s, &FakeBackend, &plan(), || [4; 32]).unwrap_err();
        assert!(e.message.contains("already active"));
        // doctor sees a consistent pool file, and flags a tampered root
        let ok = doctor(&s).unwrap();
        assert!(ok.checks.iter().any(|c| c.name == "pool_rd" && c.ok), "{:?}", ok.checks);
        let mut f = s.pool(Asset::Rd).unwrap().unwrap();
        f.head_root = "00".repeat(32);
        s.put_pool(&f).unwrap();
        assert!(doctor(&s).unwrap().checks.iter().any(|c| c.name == "pool_rd" && !c.ok));
        cleanup(&home);
    }

    #[test]
    fn balances_count_only_unspent_notes() {
        let (home, s) = setup("bal");
        let d = build_pool(&s, &FakeBackend, &plan().plans[0], [7; 32]).unwrap();
        for (o, n) in d.owners.iter().zip(&d.notes) {
            s.put_note(*o, n).unwrap();
        }
        let get = |r: &BalancesResp, p: Party, a: Asset| r.balances.iter().find(|b| b.party == p && b.asset == a).cloned().unwrap_or_else(|| panic!("missing row"));
        let r = balances(&s, &BalancesReq { party: None }).unwrap();
        assert_eq!(r.balances.len(), 8, "4 parties x 2 assets, always");
        assert_eq!(get(&r, Party::A, Asset::Rd).total, "0", "planned notes do not count");
        // activation seen: A's two 1000 notes become spendable
        for n in s.notes(Party::A).unwrap() {
            s.set_note_state(Party::A, &n.commitment, NoteState::Unspent, None).unwrap();
        }
        let r = balances(&s, &BalancesReq { party: Some(Party::A) }).unwrap();
        assert_eq!(r.balances.len(), 2);
        let a = get(&r, Party::A, Asset::Rd);
        assert_eq!((a.total.as_str(), a.notes, a.largest_note.as_str()), ("2000", 2, "1000"));
        // one note goes pending (crash mid-bundle): it leaves the balance
        let first = s.notes(Party::A).unwrap().remove(0);
        s.set_note_state(Party::A, &first.commitment, NoteState::Pending, Some("ff".repeat(32))).unwrap();
        let a = get(&balances(&s, &BalancesReq { party: Some(Party::A) }).unwrap(), Party::A, Asset::Rd);
        assert_eq!((a.total.as_str(), a.notes), ("1000", 1));
        assert_eq!(get(&balances(&s, &BalancesReq { party: Some(Party::A) }).unwrap(), Party::A, Asset::Dfabi).total, "0");
        cleanup(&home);
    }

    #[test]
    fn doctor_reports_missing_pieces_and_never_claims_chain_state() {
        let home = test_home("doctor");
        let s = Store::open(&home).unwrap();
        let r = doctor(&s).unwrap();
        assert_eq!((r.height, r.aps_active), (None, None));
        let ok = |n: &str| r.checks.iter().find(|c| c.name == n).map(|c| c.ok);
        assert_eq!(ok("home_mode"), Some(true));
        assert_eq!(ok("wallet_bi"), Some(false));
        assert_eq!(ok("pool_rd"), Some(false));
        assert_eq!(ok("chain_reads"), Some(false));
        cleanup(&home);
    }
}
