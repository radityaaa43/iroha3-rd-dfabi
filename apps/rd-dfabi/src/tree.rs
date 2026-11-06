//! Depth-32 append-only note tree over a pool's full leaf list.
//!
//! Upstream only plans a two-leaf tree (`proof_managed_accumulator.rs:288`, `pub(crate)`), so the helper
//! carries its own. Hashing is a copy of `proof_managed_accumulator.rs:20-31,116-140`:
//!   empty leaf  = SHA256("iroha.privacy.proof-managed-note-tree.empty-leaf.v1")
//!   leaf        = SHA256("...leaf.v1" || be64(len(ns)) || ns || commitment)   ns = norito bytes of the pool namespace
//!   node(l,L,R) = SHA256("...node.v1" || l as u8 || L || R)                   l = level of the children
//!   empty[l+1]  = node(l, empty[l], empty[l])
//! Positions are the insertion order; the ledger wants origin commitments strictly increasing, so callers sort
//! the origin set before `append`. The namespace bytes come from the backend (they need norito); the
//! differential test against `plan_atomic_private_settlement_bootstrap_v1` runs in the `aps` build.

use sha2::{Digest, Sha256};

pub const DEPTH: usize = 32;
const EMPTY_LEAF: &[u8] = b"iroha.privacy.proof-managed-note-tree.empty-leaf.v1";
const LEAF: &[u8] = b"iroha.privacy.proof-managed-note-tree.leaf.v1";
const NODE: &[u8] = b"iroha.privacy.proof-managed-note-tree.node.v1";

pub type Node = [u8; 32];

fn node(level: u8, left: &Node, right: &Node) -> Node {
    let mut h = Sha256::new();
    h.update(NODE);
    h.update([level]);
    h.update(left);
    h.update(right);
    h.finalize().into()
}

/// empty[l] = root of an empty subtree whose leaves are l levels below; empty[DEPTH] = root of the empty tree.
fn empty_roots() -> [Node; DEPTH + 1] {
    let mut out = [[0u8; 32]; DEPTH + 1];
    out[0] = Sha256::digest(EMPTY_LEAF).into();
    for l in 0..DEPTH {
        out[l + 1] = node(l as u8, &out[l], &out[l]);
    }
    out
}

pub struct NoteTree {
    namespace: Vec<u8>,
    leaves: Vec<Node>,
}

impl NoteTree {
    pub fn new(namespace: Vec<u8>) -> Self {
        Self { namespace, leaves: Vec::new() }
    }

    /// Append one commitment; returns its position. Zero commitments and duplicates are refused like upstream.
    pub fn append(&mut self, commitment: [u8; 32]) -> Result<u32, String> {
        if commitment == [0u8; 32] {
            return Err("zero commitment".into());
        }
        let leaf = self.leaf(&commitment);
        if self.leaves.contains(&leaf) {
            return Err("duplicate commitment".into());
        }
        let pos = u32::try_from(self.leaves.len()).map_err(|_| "tree full".to_string())?;
        self.leaves.push(leaf);
        Ok(pos)
    }

    fn leaf(&self, commitment: &[u8; 32]) -> Node {
        let mut h = Sha256::new();
        h.update(LEAF);
        h.update((self.namespace.len() as u64).to_be_bytes());
        h.update(&self.namespace);
        h.update(commitment);
        h.finalize().into()
    }

    /// Root and, when `index` is given, its authentication path (sibling per level, bottom first).
    fn fold(&self, index: Option<usize>) -> (Node, Vec<Node>) {
        let empty = empty_roots();
        let mut cur = self.leaves.clone();
        let mut idx = index;
        let mut path = Vec::new();
        for l in 0..DEPTH {
            if let Some(i) = idx {
                path.push(cur.get(i ^ 1).copied().unwrap_or(empty[l]));
                idx = Some(i / 2);
            }
            cur = cur.chunks(2).map(|c| node(l as u8, &c[0], c.get(1).unwrap_or(&empty[l]))).collect();
        }
        (cur.first().copied().unwrap_or(empty[DEPTH]), path)
    }

    pub fn root(&self) -> Node {
        self.fold(None).0
    }

    /// Path for the leaf at `index`; errors when out of range.
    pub fn path(&self, index: usize) -> Result<[Node; DEPTH], String> {
        if index >= self.leaves.len() {
            return Err("leaf index out of range".into());
        }
        let (_, path) = self.fold(Some(index));
        Ok(path.try_into().expect("DEPTH siblings"))
    }

    /// Check a path the way a verifier would: fold the leaf up and compare with `root`.
    pub fn verify(&self, commitment: &[u8; 32], index: usize, path: &[Node; DEPTH], root: &Node) -> bool {
        let mut acc = self.leaf(commitment);
        let mut i = index;
        for (l, sib) in path.iter().enumerate() {
            acc = if i % 2 == 0 { node(l as u8, &acc, sib) } else { node(l as u8, sib, &acc) };
            i /= 2;
        }
        &acc == root
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn c(n: u8) -> [u8; 32] {
        let mut x = [0u8; 32];
        x[0] = n;
        x[31] = 7;
        x
    }

    fn tree(n: u8) -> NoteTree {
        let mut t = NoteTree::new(b"ns-test".to_vec());
        for i in 1..=n {
            t.append(c(i)).unwrap();
        }
        t
    }

    #[test]
    fn every_path_folds_to_the_root() {
        for n in [1u8, 2, 3, 5, 8, 33] {
            let t = tree(n);
            let root = t.root();
            for i in 0..n as usize {
                let p = t.path(i).unwrap();
                assert!(t.verify(&c(i as u8 + 1), i, &p, &root), "n={n} i={i}");
                assert!(!t.verify(&c(99), i, &p, &root), "wrong leaf must fail");
            }
        }
    }

    #[test]
    fn two_leaf_shape_matches_the_upstream_planner() {
        // plan_two_leaf_proof_managed_transition_v1: path[0] = other leaf, path[l>0] = empty[l].
        let t = tree(2);
        let e = empty_roots();
        let p0 = t.path(0).unwrap();
        let p1 = t.path(1).unwrap();
        assert_eq!(p0[0], t.leaf(&c(2)));
        assert_eq!(p1[0], t.leaf(&c(1)));
        for l in 1..DEPTH {
            assert_eq!(p0[l], e[l]);
            assert_eq!(p1[l], e[l]);
        }
    }

    #[test]
    fn root_depends_on_order_namespace_and_content() {
        let a = tree(3).root();
        let mut swapped = NoteTree::new(b"ns-test".to_vec());
        for i in [2u8, 1, 3] {
            swapped.append(c(i)).unwrap();
        }
        assert_ne!(a, swapped.root());
        let mut other_ns = NoteTree::new(b"ns-other".to_vec());
        for i in 1..=3u8 {
            other_ns.append(c(i)).unwrap();
        }
        assert_ne!(a, other_ns.root());
        assert_ne!(tree(2).root(), tree(3).root());
        assert_eq!(NoteTree::new(vec![]).root(), empty_roots()[DEPTH]);
    }

    #[test]
    fn incremental_append_equals_batch_and_old_paths_go_stale() {
        let mut t = tree(2);
        let old_root = t.root();
        let old_path = t.path(0).unwrap();
        t.append(c(3)).unwrap();
        assert_eq!(t.root(), tree(3).root());
        // a path taken before the append no longer proves membership under the new root
        assert!(!t.verify(&c(1), 0, &old_path, &t.root()));
        assert!(t.verify(&c(1), 0, &old_path, &old_root));
    }

    #[test]
    fn rejects_zero_duplicate_and_out_of_range() {
        let mut t = tree(1);
        assert!(t.append([0; 32]).is_err());
        assert!(t.append(c(1)).is_err());
        assert!(t.path(1).is_err());
    }
}
