//! Real implementation, compiled only with `--features aps` (pulls iroha_core, zk-stark; hours in CI).
//! Module plan (see design doc section 3 for the upstream file:line behind every item):
//!   store  - wallet seed, note store (pending -> confirmed), pool ledger, audit store; 0600 files, atomic rename
//!   tree   - depth-32 note tree over a pool's full leaf list (upstream accumulator is pub(crate))
//!   pool   - GovernedLeg, funding notes, ActivatePrivateSettlementPoolV1
//!   dvp    - prepare legs, prove, availability, upload, audit, prepare, register, commit, finalize
//!   audit  - seal/open capsule, approve, audit store
//!   torii  - signed GETs for status/receipt/lifecycle/capabilities
//! Live now: `ApsBackend` (the four crypto calls) and the probe material builder.
//!
//! Written against upstream 071e281e WITHOUT a local compile (the host must not build iroha_core); the CI build
//! of this crate is the first type check. Every upstream call below names the file:line it was copied from.

use std::str::FromStr;

use iroha_core::{
    privacy_engines::{
        atomic_private_settlement::atomic_private_settlement_program_id_v1,
        ivm_private_note::{
            PrivateNotePlaintextV1, derive_note_authority_v1, derive_note_commitment_v1, ivm_private_recipient_public_key_v1,
        },
    },
    private_settlement::{private_settlement_audit_plaintext_commitment_v1, seal_private_settlement_audit_capsule_v1},
};
use iroha_crypto::{Algorithm, Hash, HashOf, HybridKeyPair, KeyPair, PublicKey};
use iroha_data_model::{
    NetworkId,
    account::AccountId,
    nexus::{
        ATOMIC_PRIVATE_SETTLEMENT_VERSION_V1, AtomicPrivateSettlementV1, PrivateSettlementAuditAadV1,
        PrivateSettlementAuditPolicyBodyV1, PrivateSettlementAuditPolicyV1, PrivateSettlementAuditorV1,
        PrivateSettlementCapsulePaddingV1, PrivateSettlementCommitteeAuthorityV1, PrivateSettlementDeltaV1,
        PrivateSettlementHybridPublicKeyV1, PrivateSettlementLegCommitmentV1, PrivateSettlementProofProfileV1,
        PrivateSettlementProofStatementV1, PrivateSettlementProvisionalLegMaterialV1, PrivateSettlementRouteV1,
        PrivateSettlementSidecarAvailabilityBodyV1, private_settlement_proof_digest_v1,
    },
    privacy::{
        PRIVACY_IVM_PRIVATE_ENCRYPTED_OUTPUT_BYTES_V1, PrivacyCommitmentV1, PrivacyEncryptedOutputV1, PrivacyEncryptionKeyV1,
        PrivacyNamespaceScopeV1, PrivacyNamespaceV1, PrivacyNullifierV1, PrivacyPoolIdV1, PrivacyPoolProgramNamespaceV1,
        PrivacyProtocolIdV1, PrivacyRecipientIdV1, PrivacyRootV1,
    },
    transaction::FeePaymentIntent,
};
use iroha_model_base::{
    peer::PeerId,
    topology::{DataSpaceId, LaneId},
};

use crate::{
    api::ErrorBody,
    backend::{Backend, NoteMaterial, err},
    probe::{LaneRoute, Plan, derived},
};

pub const UPSTREAM_REV: &str = "071e281e778c5928cab4d6e007b7ddc9b050df27";

/// Any upstream error becomes an `internal` ErrorBody that names the step and carries the upstream Debug text.
/// Upstream errors are redacted types (no keys inside), so this cannot leak material.
fn dbg<E: std::fmt::Debug>(step: &'static str) -> impl FnOnce(E) -> ErrorBody {
    move |e| err("internal", format!("{step}: {e:?}"), false)
}

fn bad(m: impl Into<String>) -> ErrorBody {
    err("bad_request", m, false)
}

/// The four crypto calls the light build cannot make. Each is a one-line forward to the function in the module doc of backend.rs.
pub struct ApsBackend;

impl Backend for ApsBackend {
    // iroha_core/src/privacy_engines/ivm_private_note/wallet.rs:143
    fn view_public(&self, secret: &[u8; 32]) -> Result<[u8; 32], ErrorBody> {
        ivm_private_recipient_public_key_v1(secret).map_err(dbg("view_public"))
    }

    // iroha_core/src/privacy_engines/ivm_private_note/relation.rs:966
    fn authority(&self, spend_secret: &[u8; 32]) -> Result<[u8; 32], ErrorBody> {
        derive_note_authority_v1(spend_secret).map_err(dbg("authority"))
    }

    // relation.rs:385 (PrivateNotePlaintextV1::new rejects zero value, authority, rho and blinding) and relation.rs:980
    fn commitment(&self, note: &NoteMaterial) -> Result<[u8; 32], ErrorBody> {
        let plain = PrivateNotePlaintextV1::new(note.value, note.authority, note.rho, note.blinding, note.memo_digest)
            .map_err(dbg("note plaintext"))?;
        let commitment = derive_note_commitment_v1(&plain).map_err(dbg("note commitment"))?;
        Ok(*commitment.as_bytes())
    }

    // atomic_private_settlement/wallet.rs:760-770 builds the same namespace; proof_managed_accumulator.rs:125 encodes it with norito::to_bytes
    fn pool_namespace(&self, pool_id: &[u8; 32]) -> Result<Vec<u8>, ErrorBody> {
        let namespace = PrivacyNamespaceV1::new(
            PrivacyProtocolIdV1::IrohaIvmPrivateNoteStarkV1,
            PrivacyNamespaceScopeV1::PoolProgram(PrivacyPoolProgramNamespaceV1 {
                pool_id: PrivacyPoolIdV1::new(*pool_id),
                program_id: atomic_private_settlement_program_id_v1().map_err(dbg("program id"))?,
            }),
        );
        norito::to_bytes(&namespace).map_err(dbg("namespace encoding"))
    }
}

fn route_of(lane: &LaneRoute) -> Result<PrivateSettlementRouteV1, ErrorBody> {
    Ok(PrivateSettlementRouteV1 {
        dataspace_id: DataSpaceId::new(lane.dataspace_id),
        lane_id: LaneId::new(lane.lane_id),
        lane_incarnation: Hash::from_str(&lane.incarnation).map_err(|e| bad(format!("lane incarnation: {e:?}")))?,
    })
}

/// The auditor of the probe capsule: the supplied public key, or a throwaway whose private halves are dropped here.
fn auditor_of(plan: &Plan) -> Result<PrivateSettlementAuditorV1, ErrorBody> {
    if let Some(a) = &plan.auditor {
        let signing_key: PublicKey = a.signing_public_key.parse().map_err(|e| bad(format!("auditor signing key: {e:?}")))?;
        return Ok(PrivateSettlementAuditorV1 {
            auditor_id: AccountId::new(signing_key.clone()),
            signing_key,
            encryption_key: PrivateSettlementHybridPublicKeyV1 { x25519: a.x25519, ml_kem_768: a.ml_kem_768.clone() },
        });
    }
    let fresh = |what: &'static str| crate::store::random32().map_err(|m| err("internal", format!("{what}: {m}"), false));
    // from_seed: iroha_crypto/src/lib.rs:536; rng_from_seed_slice: iroha_crypto/src/rng.rs:71; HybridKeyPair::generate: hybrid.rs:357
    let signing = KeyPair::from_seed(fresh("auditor seed")?.to_vec(), Algorithm::Ed25519);
    let mut rng = iroha_crypto::rng_from_seed_slice(&fresh("auditor hybrid seed")?);
    let hybrid = HybridKeyPair::generate(&mut rng).map_err(dbg("auditor hybrid key"))?;
    Ok(PrivateSettlementAuditorV1 {
        auditor_id: AccountId::new(signing.public_key().clone()),
        signing_key: signing.public_key().clone(),
        encryption_key: PrivateSettlementHybridPublicKeyV1::from_hybrid(hybrid.public()),
    })
}

/// Build the PrivateSettlementProvisionalLegMaterialV1 for leg 0 (dataspace `plan.tested`) and return its Norito JSON.
///
/// Mirrors the upstream fixture `provisional_material_fixture` (iroha_core/src/private_settlement/sidecar_store.rs:4102,
/// `sidecar_fixture_with_threshold_and_ordinal` :4129) with three differences: the audit plaintext is a fixed probe string
/// (the validator never opens the capsule, it only checks the plaintext commitment), the proof is a 128-byte placeholder
/// (the STARK is verified at prepare, not here), and the committee is the live roster, not a seeded one.
pub fn availability_share_material(plan: &Plan) -> Result<String, ErrorBody> {
    // AccountId JSON and Display use the process-wide discriminant (iroha_data_model/src/account/address.rs:42).
    if let Some(d) = plan.chain_discriminant {
        iroha_data_model::account::address::set_chain_discriminant(d);
    }
    let network_id = NetworkId::from_str(&plan.network_id).map_err(|e| bad(format!("network id: {}", e.reason())))?;
    let sponsor_key: PublicKey = plan.sponsor_public_key.parse().map_err(|e| bad(format!("sponsor public key: {e:?}")))?;
    let context = plan.context_height;
    let expiry = context.checked_add(plan.expiry_blocks).ok_or_else(|| bad("expiry height overflows"))?;
    let retention = context.checked_add(plan.retention_blocks).ok_or_else(|| bad("retention height overflows"))?;
    if retention < expiry {
        return Err(bad("--retention-blocks must be at least --expiry-blocks (material validation needs retention >= expiry)"));
    }

    let d = |label: &str| derived(&plan.salt, label);
    let h = |label: &str| Hash::new(d(label));
    let zero = Hash::prehashed([0; Hash::LENGTH]);

    // Routes: the manifest orders legs by route (dataspace id first), the tested leg is ordinal 0.
    let route0 = route_of(&plan.tested)?;
    let route1 = route_of(&plan.other)?;

    // Committee: PeerId order is authoritative (protocol.rs:189 requires resolved.validators() == authority.validators).
    let mut roster = Vec::with_capacity(plan.roster.len());
    for entry in &plan.roster {
        let key: PublicKey = entry.public_key.parse().map_err(|e| bad(format!("roster public key: {e:?}")))?;
        roster.push((PeerId::from(key), entry.pop.clone()));
    }
    roster.sort_by(|a, b| a.0.cmp(&b.0));
    for (index, (peer, pop)) in roster.iter().enumerate() {
        // Same call as protocol.rs:validate_authority_cryptography_v1; fails here instead of as an opaque 400.
        if iroha_crypto::bls_normal_pop_verify(peer.public_key(), pop).is_err() {
            return Err(bad(format!("roster entry {index} (in PeerId order): its PoP does not verify against its BLS key")));
        }
    }
    let (validators, validator_pops): (Vec<PeerId>, Vec<Vec<u8>>) = roster.into_iter().unzip();
    let authority = PrivateSettlementCommitteeAuthorityV1 {
        route: route0,
        validator_set_hash: HashOf::new(&validators),
        validators,
        validator_pops,
    };
    authority.validate().map_err(dbg("committee authority shape"))?;
    let authority_digest = authority.digest().map_err(dbg("authority digest"))?;

    // Audit policy: one auditor, one approval (>= default_min_auditor_approvals), active from block 1, never retired.
    let policy = PrivateSettlementAuditPolicyV1::new(PrivateSettlementAuditPolicyBodyV1 {
        version: ATOMIC_PRIVATE_SETTLEMENT_VERSION_V1,
        dataspace_id: route0.dataspace_id,
        policy_id: h("policy-id"),
        revision: 1,
        key_epoch: 1,
        activation_height: 1,
        retirement_height: None,
        min_approvals: 1,
        auditors: vec![auditor_of(plan)?],
    })
    .map_err(dbg("audit policy"))?;

    // Manifest skeleton. Payload and delta digests of both legs are placeholders until the material exists.
    let leg = |ordinal: u8, route: PrivateSettlementRouteV1, tag: &str, policy_digest: Hash| PrivateSettlementLegCommitmentV1 {
        ordinal,
        route,
        pool_id: PrivacyPoolIdV1::new(d(&format!("pool{tag}"))),
        asset_binding_commitment: h(&format!("asset{tag}")),
        audit_policy_digest: policy_digest,
        payload_digest: h(&format!("payload-placeholder{tag}")),
        availability_certificate_digest: zero,
        delta_digest: h(&format!("delta-placeholder{tag}")),
    };
    let mut manifest = AtomicPrivateSettlementV1 {
        version: ATOMIC_PRIVATE_SETTLEMENT_VERSION_V1,
        network_id,
        bundle_id: h("bundle-placeholder"),
        authority_context_height: context,
        expiry_height: expiry,
        sponsor: AccountId::new(sponsor_key),
        public_fee_intent: FeePaymentIntent::authority(Vec::new(), None),
        fee_intent_digest: h("fee-placeholder"),
        reimbursement_terms_commitment: h("reimbursement-terms"),
        reimbursement_leg_ordinal: 0,
        legs: vec![leg(0, route0, "0", policy.policy_digest), leg(1, route1, "1", h("policy-digest1"))],
    };
    manifest.fee_intent_digest = manifest.computed_fee_intent_digest().map_err(dbg("fee intent digest"))?;
    manifest.bundle_id = manifest.computed_bundle_id().map_err(dbg("bundle id"))?;

    // Capsule: the plaintext is a probe marker, sealed to the auditor with the real hybrid KEM + XChaCha20-Poly1305.
    let plaintext = format!("rd-dfabi availability-share probe {}", hex::encode(&d("plaintext")[..8])).into_bytes();
    let plaintext_commitment = private_settlement_audit_plaintext_commitment_v1(&plaintext).map_err(dbg("plaintext commitment"))?;
    let capsule = seal_private_settlement_audit_capsule_v1(
        &plaintext,
        PrivateSettlementAuditAadV1 {
            network_id: manifest.network_id,
            bundle_id: manifest.bundle_id,
            leg_ordinal: 0,
            route: route0,
            authority_digest,
            authority_context_height: context,
            audit_policy_digest: policy.policy_digest,
            audit_key_epoch: policy.body.key_epoch,
            plaintext_commitment,
        },
        PrivateSettlementCapsulePaddingV1::KiB4,
        &policy,
    )
    .map_err(dbg("seal audit capsule"))?;
    let capsule_digest = capsule.digest().map_err(dbg("capsule digest"))?;

    // Statement and delta: fixed 2-in/3-out shape with derived (not real) roots, nullifiers and commitments.
    let encrypted_outputs: Vec<PrivacyEncryptedOutputV1> = (0_u8..3)
        .map(|i| {
            let mut ciphertext = vec![0x80 + i; PRIVACY_IVM_PRIVATE_ENCRYPTED_OUTPUT_BYTES_V1];
            ciphertext[..4].copy_from_slice(b"IPNE");
            PrivacyEncryptedOutputV1 {
                recipient: PrivacyRecipientIdV1::new(d(&format!("recipient{i}"))),
                ephemeral_public_key: PrivacyEncryptionKeyV1::new(d(&format!("ephemeral{i}"))),
                commitment: PrivacyCommitmentV1::new(d(&format!("commitment{i}"))),
                ciphertext,
            }
        })
        .collect();
    let profile = PrivateSettlementProofProfileV1::IvmPrivateNoteFixed2In3Out;
    let statement = PrivateSettlementProofStatementV1 {
        version: ATOMIC_PRIVATE_SETTLEMENT_VERSION_V1,
        profile,
        proof_profile_digest: profile.digest(),
        network_id: manifest.network_id,
        bundle_id: manifest.bundle_id,
        leg_ordinal: 0,
        route: route0,
        authority_context_height: context,
        pool_id: manifest.legs[0].pool_id,
        asset_binding_commitment: manifest.legs[0].asset_binding_commitment,
        old_root: PrivacyRootV1::new(d("root-old")),
        new_root: PrivacyRootV1::new(d("root-new")),
        old_epoch: 1,
        new_epoch: 2,
        nullifiers: vec![PrivacyNullifierV1::new(d("nullifier0")), PrivacyNullifierV1::new(d("nullifier1"))],
        output_commitments: encrypted_outputs.iter().map(|o| o.commitment).collect(),
        encrypted_outputs: encrypted_outputs.clone(),
        audit_plaintext_commitment: plaintext_commitment,
        audit_input_commitment: d("audit-input"),
        audit_capsule_digest: capsule_digest,
        audit_policy_digest: policy.policy_digest,
        audit_key_epoch: policy.body.key_epoch,
        fee_intent_digest: manifest.fee_intent_digest,
        reimbursement_terms_commitment: manifest.reimbursement_terms_commitment,
        reimbursement_leg_ordinal: manifest.reimbursement_leg_ordinal,
        expiry_height: expiry,
    };
    statement.validate().map_err(dbg("statement"))?;
    let proof = vec![0xA5_u8; 128]; // placeholder: the STARK is verified at prepare, never by the availability handler
    let delta = PrivateSettlementDeltaV1 {
        version: ATOMIC_PRIVATE_SETTLEMENT_VERSION_V1,
        bundle_id: statement.bundle_id,
        leg_ordinal: 0,
        route: route0,
        pool_id: statement.pool_id,
        asset_binding_commitment: statement.asset_binding_commitment,
        old_root: statement.old_root,
        new_root: statement.new_root,
        old_epoch: statement.old_epoch,
        new_epoch: statement.new_epoch,
        nullifiers: statement.nullifiers.clone(),
        output_commitments: statement.output_commitments.clone(),
        encrypted_outputs,
        statement_digest: statement.digest().map_err(dbg("statement digest"))?,
        proof_digest: private_settlement_proof_digest_v1(&proof),
        capsule_digest,
        audit_policy_digest: policy.policy_digest,
        audit_key_epoch: policy.body.key_epoch,
    };

    // Content-address the material, then write the digests back into the manifest (sidecar_store.rs:4189-4205, wallet.rs:379-460).
    let mut material = PrivateSettlementProvisionalLegMaterialV1 {
        version: ATOMIC_PRIVATE_SETTLEMENT_VERSION_V1,
        manifest: manifest.clone(),
        audit_policy: policy,
        committee_authority: authority,
        statement,
        proof,
        delta,
        audit_capsule: capsule,
        availability_body: PrivateSettlementSidecarAvailabilityBodyV1 {
            version: ATOMIC_PRIVATE_SETTLEMENT_VERSION_V1,
            network_id: manifest.network_id,
            bundle_id: manifest.bundle_id,
            leg_ordinal: 0,
            route: route0,
            authority_digest,
            authority_context_height: context,
            payload_digest: Hash::prehashed([1; Hash::LENGTH]),
            payload_bytes: 1,
            retention_until_height: retention,
        },
    };
    let payload_digest = material.payload_digest().map_err(dbg("payload digest"))?;
    let payload_bytes = u32::try_from(material.sidecar_material_bytes_len().map_err(dbg("payload length"))?)
        .map_err(|_| bad("sidecar material does not fit u32"))?;
    let delta_digest = material.delta.digest().map_err(dbg("delta digest"))?;
    material.availability_body.payload_digest = payload_digest;
    material.availability_body.payload_bytes = payload_bytes;
    manifest.legs[0].payload_digest = payload_digest;
    manifest.legs[0].delta_digest = delta_digest;
    manifest.validate_provisional().map_err(dbg("provisional manifest"))?;
    material.manifest = manifest;
    // The same check the handler runs last (iroha_torii/src/private_settlement.rs:1085), here before anything is sent.
    material.validate().map_err(dbg("material validation"))?;

    // What the CLI will read (iroha_cli/src/nexus.rs:306 parses with norito::json) must give back the same value.
    let json = norito::json::to_json(&material).map_err(dbg("material serialisation"))?;
    let back: PrivateSettlementProvisionalLegMaterialV1 = norito::json::from_str(&json).map_err(dbg("material re-parse"))?;
    back.validate().map_err(dbg("re-parsed material validation"))?;
    if back != material {
        return Err(err("internal", "material does not survive a JSON round trip", false));
    }
    Ok(json)
}
