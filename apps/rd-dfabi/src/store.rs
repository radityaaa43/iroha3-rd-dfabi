//! File store under `--home` (design section 4). Directories 0700, files 0600, every write is
//! temp file + fsync + rename + directory fsync, so a crash leaves the old file or the new one, never half.
//!
//!   wallets/<p>/seed.key          32 random bytes; every note secret is KDF(seed, label), so notes are rebuildable
//!   wallets/<p>/notes/<commit>.json
//!   pools/<asset>.json            public pool ledger (leaves in tree order, head root)
//!   locks/<name>.lock             flock; hold it for a whole command that mutates state

use std::{
    fs::{self, DirBuilder, File, OpenOptions},
    io::{Read, Write},
    os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt},
    path::{Path, PathBuf},
};

use fs2::FileExt;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use crate::api::{Amount, Asset, Hex32, Party};

pub type Res<T> = Result<T, String>;

pub fn party_dir(p: Party) -> &'static str {
    match p {
        Party::BI => "bi",
        Party::A => "a",
        Party::B => "b",
        Party::C => "c",
    }
}

pub fn asset_file(a: Asset) -> &'static str {
    match a {
        Asset::Rd => "rd",
        Asset::Dfabi => "dfabi",
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum NoteState {
    /// Origin note of a planned pool; becomes `Unspent` when the activation is seen on chain.
    PendingActivation,
    Unspent,
    /// Input of an in-flight bundle, or output of a bundle that is not final yet. Never counted.
    Pending,
    Spent,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct NoteRecord {
    pub asset: Asset,
    pub pool: Hex32,
    pub commitment: Hex32,
    pub value: Amount,
    /// KDF label prefix of the note secrets; the secrets themselves are never stored.
    pub label: String,
    pub state: NoteState,
    pub bundle: Option<Hex32>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct PoolFile {
    pub asset: Asset,
    pub pool_id: Hex32,
    /// norito bytes of the pool namespace, hex; fixes how leaves are hashed.
    pub namespace_hex: String,
    /// planned | active
    pub status: String,
    /// Commitments in tree order (origin set sorted ascending, then every finalized output in statement order).
    pub leaves: Vec<Hex32>,
    pub head_root: Hex32,
    pub head_epoch: u64,
}

pub struct Store {
    root: PathBuf,
}

pub struct LockGuard(File);
impl Drop for LockGuard {
    fn drop(&mut self) {
        let _ = self.0.unlock();
    }
}

pub fn random32() -> Res<[u8; 32]> {
    let mut b = [0u8; 32];
    File::open("/dev/urandom").and_then(|mut f| f.read_exact(&mut b)).map_err(|e| format!("read /dev/urandom: {e}"))?;
    Ok(b)
}

/// Domain-separated KDF from the wallet seed. The seed is uniformly random, so one hash is enough (no HKDF needed).
pub fn kdf(seed: &[u8; 32], label: &str) -> [u8; 32] {
    let mut h = Sha256::new();
    h.update(b"rd-dfabi/kdf/v1\0");
    h.update(seed);
    h.update(label.as_bytes());
    h.finalize().into()
}

pub fn hex32(b: &[u8; 32]) -> Hex32 {
    hex::encode(b)
}

pub fn unhex32(s: &str) -> Res<[u8; 32]> {
    let v = hex::decode(s).map_err(|e| format!("bad hex: {e}"))?;
    v.try_into().map_err(|_| "expected 32 bytes".to_string())
}

fn mkdir(p: &Path) -> Res<()> {
    DirBuilder::new().recursive(true).mode(0o700).create(p).map_err(|e| format!("mkdir {}: {e}", p.display()))
}

impl Store {
    /// Creates the root and the fixed subdirectories (0700). Fails on an existing root that is group/world accessible.
    pub fn open(root: &Path) -> Res<Self> {
        mkdir(root)?;
        let mode = fs::metadata(root).map_err(|e| e.to_string())?.mode() & 0o777;
        if mode & 0o077 != 0 {
            return Err(format!("{} has mode {:o}, expected 0700", root.display(), mode));
        }
        for d in ["wallets", "pools", "locks"] {
            mkdir(&root.join(d))?;
        }
        Ok(Self { root: root.to_path_buf() })
    }

    fn write_atomic(&self, path: &Path, bytes: &[u8]) -> Res<()> {
        let dir = path.parent().ok_or("no parent")?;
        mkdir(dir)?;
        let tmp = dir.join(format!(".{}.tmp", path.file_name().and_then(|n| n.to_str()).unwrap_or("x")));
        let _ = fs::remove_file(&tmp);
        let mut f = OpenOptions::new().write(true).create_new(true).mode(0o600).open(&tmp).map_err(|e| format!("create {}: {e}", tmp.display()))?;
        f.write_all(bytes).and_then(|_| f.sync_all()).map_err(|e| format!("write {}: {e}", tmp.display()))?;
        fs::rename(&tmp, path).map_err(|e| format!("rename to {}: {e}", path.display()))?;
        File::open(dir).and_then(|d| d.sync_all()).map_err(|e| format!("fsync dir: {e}"))
    }

    pub fn lock(&self, name: &str) -> Res<LockGuard> {
        let f = OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(false)
            .mode(0o600)
            .open(self.root.join("locks").join(format!("{name}.lock")))
            .map_err(|e| e.to_string())?;
        f.try_lock_exclusive().map_err(|_| format!("lock {name} is held by another rd-dfabi run"))?;
        Ok(LockGuard(f))
    }

    fn wallet(&self, p: Party) -> PathBuf {
        self.root.join("wallets").join(party_dir(p))
    }

    pub fn has_seed(&self, p: Party) -> bool {
        self.wallet(p).join("seed.key").exists()
    }

    pub fn seed(&self, p: Party) -> Res<[u8; 32]> {
        let b = fs::read(self.wallet(p).join("seed.key")).map_err(|_| format!("no wallet for {}", party_dir(p)))?;
        b.try_into().map_err(|_| "seed.key is not 32 bytes".to_string())
    }

    /// Writes a new seed. Refuses to replace one unless `force`, and never replaces one that still has live notes.
    pub fn create_seed(&self, p: Party, force: bool, seed: [u8; 32]) -> Res<()> {
        if self.has_seed(p) {
            if !force {
                return Err("wallet already exists (use force)".into());
            }
            if self.notes(p)?.iter().any(|n| matches!(n.state, NoteState::Unspent | NoteState::Pending | NoteState::PendingActivation)) {
                return Err("wallet still holds notes; refusing to replace its seed".into());
            }
        }
        self.write_atomic(&self.wallet(p).join("seed.key"), &seed)
    }

    pub fn put_note(&self, p: Party, n: &NoteRecord) -> Res<()> {
        let bytes = serde_json::to_vec_pretty(n).map_err(|e| e.to_string())?;
        self.write_atomic(&self.wallet(p).join("notes").join(format!("{}.json", n.commitment)), &bytes)
    }

    pub fn notes(&self, p: Party) -> Res<Vec<NoteRecord>> {
        let dir = self.wallet(p).join("notes");
        let Ok(rd) = fs::read_dir(&dir) else { return Ok(vec![]) };
        let mut out = Vec::new();
        for e in rd {
            let path = e.map_err(|e| e.to_string())?.path();
            if path.extension().and_then(|x| x.to_str()) != Some("json") {
                continue;
            }
            let raw = fs::read(&path).map_err(|e| format!("read {}: {e}", path.display()))?;
            out.push(serde_json::from_slice(&raw).map_err(|e| format!("{}: {e}", path.display()))?);
        }
        out.sort_by(|a: &NoteRecord, b| a.commitment.cmp(&b.commitment));
        Ok(out)
    }

    pub fn set_note_state(&self, p: Party, commitment: &str, state: NoteState, bundle: Option<Hex32>) -> Res<()> {
        let mut n = self.notes(p)?.into_iter().find(|n| n.commitment == commitment).ok_or("no such note")?;
        n.state = state;
        n.bundle = bundle;
        self.put_note(p, &n)
    }

    pub fn put_pool(&self, f: &PoolFile) -> Res<()> {
        let bytes = serde_json::to_vec_pretty(f).map_err(|e| e.to_string())?;
        self.write_atomic(&self.root.join("pools").join(format!("{}.json", asset_file(f.asset))), &bytes)
    }

    pub fn pool(&self, a: Asset) -> Res<Option<PoolFile>> {
        match fs::read(self.root.join("pools").join(format!("{}.json", asset_file(a)))) {
            Ok(raw) => Ok(Some(serde_json::from_slice(&raw).map_err(|e| e.to_string())?)),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
            Err(e) => Err(e.to_string()),
        }
    }

    pub fn seed_mode(&self, p: Party) -> Option<u32> {
        fs::metadata(self.wallet(p).join("seed.key")).ok().map(|m| m.mode() & 0o777)
    }

    pub fn root_mode(&self) -> Option<u32> {
        fs::metadata(&self.root).ok().map(|m| m.mode() & 0o777)
    }
}

/// Unique scratch dir for a test; the caller removes it with `cleanup`.
#[cfg(test)]
pub fn test_home(tag: &str) -> PathBuf {
    let p = std::env::temp_dir().join(format!("rd-dfabi-test-{}-{}", std::process::id(), tag));
    cleanup(&p);
    p
}

#[cfg(test)]
pub fn cleanup(p: &Path) {
    let _ = fs::remove_dir_all(p);
}

#[cfg(test)]
mod tests {
    use super::*;

    fn note(commit: &str, state: NoteState) -> NoteRecord {
        NoteRecord { asset: Asset::Rd, pool: "aa".repeat(32), commitment: commit.into(), value: "10".into(), label: "l".into(), state, bundle: None }
    }

    #[test]
    fn modes_and_atomic_write_leave_no_temp_file() {
        let home = test_home("modes");
        let s = Store::open(&home).unwrap();
        s.create_seed(Party::A, false, [7; 32]).unwrap();
        assert_eq!(s.root_mode(), Some(0o700));
        assert_eq!(s.seed_mode(Party::A), Some(0o600));
        assert_eq!(s.seed(Party::A).unwrap(), [7; 32]);
        let names: Vec<_> = fs::read_dir(home.join("wallets/a")).unwrap().map(|e| e.unwrap().file_name()).collect();
        assert_eq!(names.len(), 1, "only seed.key, got {names:?}");
        // a loose root is refused
        fs::set_permissions(&home, std::os::unix::fs::PermissionsExt::from_mode(0o755)).unwrap();
        assert!(Store::open(&home).is_err());
        cleanup(&home);
    }

    #[test]
    fn seed_replace_rules() {
        let home = test_home("seed");
        let s = Store::open(&home).unwrap();
        s.create_seed(Party::B, false, [1; 32]).unwrap();
        assert!(s.create_seed(Party::B, false, [2; 32]).is_err(), "no silent overwrite");
        s.create_seed(Party::B, true, [2; 32]).unwrap();
        s.put_note(Party::B, &note(&"01".repeat(32), NoteState::Unspent)).unwrap();
        assert!(s.create_seed(Party::B, true, [3; 32]).is_err(), "live notes block replacement");
        assert_eq!(s.seed(Party::B).unwrap(), [2; 32]);
        s.set_note_state(Party::B, &"01".repeat(32), NoteState::Spent, None).unwrap();
        s.create_seed(Party::B, true, [3; 32]).unwrap();
        cleanup(&home);
    }

    #[test]
    fn notes_roundtrip_and_pool_roundtrip() {
        let home = test_home("notes");
        let s = Store::open(&home).unwrap();
        let n = note(&"02".repeat(32), NoteState::PendingActivation);
        s.put_note(Party::C, &n).unwrap();
        assert_eq!(s.notes(Party::C).unwrap(), vec![n]);
        assert!(s.notes(Party::A).unwrap().is_empty());
        let p = PoolFile {
            asset: Asset::Dfabi,
            pool_id: "bb".repeat(32),
            namespace_hex: "00".into(),
            status: "planned".into(),
            leaves: vec![],
            head_root: "cc".repeat(32),
            head_epoch: 1,
        };
        s.put_pool(&p).unwrap();
        assert_eq!(s.pool(Asset::Dfabi).unwrap(), Some(p));
        assert_eq!(s.pool(Asset::Rd).unwrap(), None);
        cleanup(&home);
    }

    #[test]
    fn lock_is_exclusive() {
        let home = test_home("lock");
        let s = Store::open(&home).unwrap();
        let g = s.lock("pool-rd").unwrap();
        assert!(s.lock("pool-rd").is_err());
        drop(g);
        s.lock("pool-rd").unwrap();
        cleanup(&home);
    }

    #[test]
    fn kdf_separates_labels_and_seeds() {
        assert_ne!(kdf(&[1; 32], "a"), kdf(&[1; 32], "b"));
        assert_ne!(kdf(&[1; 32], "a"), kdf(&[2; 32], "a"));
        assert_eq!(kdf(&[1; 32], "a"), kdf(&[1; 32], "a"));
    }
}
