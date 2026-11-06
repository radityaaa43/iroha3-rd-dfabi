//! Crypto that only upstream can do bit-exactly. `NoAps` is what the light build has; the `aps` build
//! (M1b, after M0b) supplies the real one:
//!   view_public   = ivm_private_recipient_public_key_v1   iroha_core/.../ivm_private_note/wallet.rs:143
//!   authority     = derive_note_authority_v1               .../ivm_private_note/relation.rs:966
//!   commitment    = derive_note_commitment_v1              .../ivm_private_note/relation.rs (called at wallet.rs:476)
//!   pool_namespace= norito::to_bytes(PrivacyNamespaceV1::new(IrohaIvmPrivateNoteStarkV1,
//!                     PoolProgram{pool_id, program_id: atomic_private_settlement_program_id_v1()}))   wallet.rs:760-770

use crate::api::ErrorBody;

pub struct NoteMaterial {
    pub value: u128,
    pub authority: [u8; 32],
    pub rho: [u8; 32],
    pub blinding: [u8; 32],
    pub memo_digest: [u8; 32],
}

pub trait Backend {
    fn view_public(&self, secret: &[u8; 32]) -> Result<[u8; 32], ErrorBody>;
    fn authority(&self, spend_secret: &[u8; 32]) -> Result<[u8; 32], ErrorBody>;
    fn commitment(&self, note: &NoteMaterial) -> Result<[u8; 32], ErrorBody>;
    fn pool_namespace(&self, pool_id: &[u8; 32]) -> Result<Vec<u8>, ErrorBody>;
}

pub fn err(code: &str, message: impl Into<String>, retryable: bool) -> ErrorBody {
    ErrorBody { code: code.into(), message: message.into(), retryable }
}

/// Light build: every call says the aps build is needed.
pub struct NoAps;

fn missing<T>() -> Result<T, ErrorBody> {
    Err(err("aps_not_built", "this operation needs the iroha crypto: build rd-dfabi with --features aps", false))
}

impl Backend for NoAps {
    fn view_public(&self, _: &[u8; 32]) -> Result<[u8; 32], ErrorBody> {
        missing()
    }
    fn authority(&self, _: &[u8; 32]) -> Result<[u8; 32], ErrorBody> {
        missing()
    }
    fn commitment(&self, _: &NoteMaterial) -> Result<[u8; 32], ErrorBody> {
        missing()
    }
    fn pool_namespace(&self, _: &[u8; 32]) -> Result<Vec<u8>, ErrorBody> {
        missing()
    }
}

/// Deterministic stand-in for tests only: same shape, no claim to match upstream hashes.
#[cfg(test)]
pub struct FakeBackend;

#[cfg(test)]
impl Backend for FakeBackend {
    fn view_public(&self, s: &[u8; 32]) -> Result<[u8; 32], ErrorBody> {
        Ok(h(b"view", &[s]))
    }
    fn authority(&self, s: &[u8; 32]) -> Result<[u8; 32], ErrorBody> {
        Ok(h(b"auth", &[s]))
    }
    fn commitment(&self, n: &NoteMaterial) -> Result<[u8; 32], ErrorBody> {
        Ok(h(b"commit", &[&n.value.to_be_bytes(), &n.authority, &n.rho, &n.blinding, &n.memo_digest]))
    }
    fn pool_namespace(&self, pool_id: &[u8; 32]) -> Result<Vec<u8>, ErrorBody> {
        Ok([b"fake-ns".as_slice(), pool_id].concat())
    }
}

#[cfg(test)]
fn h(tag: &[u8], parts: &[&[u8]]) -> [u8; 32] {
    use sha2::{Digest, Sha256};
    let mut x = Sha256::new();
    x.update(tag);
    for p in parts {
        x.update(p);
    }
    x.finalize().into()
}
