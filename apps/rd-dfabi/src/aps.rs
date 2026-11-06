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
use iroha_crypto::{Algorithm, Hash, HashOf, HybridKeyPair, KeyPair, PublicKey, SignatureOf};
use iroha_data_model::{
    NetworkId,
    account::AccountId,
    asset::AssetDefinitionId,
    nexus::{
        ATOMIC_PRIVATE_SETTLEMENT_VERSION_V1, AtomicPrivateSettlementV1, PrivateSettlementAuditAadV1,
        PrivateSettlementAuditEncryptionOpeningV1, PrivateSettlementAuditNoteOpeningV1, PrivateSettlementAuditOutputRoleV1,
        PrivateSettlementAuditOutputV1, PrivateSettlementAuditPayerAuthorizationBodyV1, PrivateSettlementAuditPayerAuthorizationV1,
        PrivateSettlementAuditPayerSignatureV1, PrivateSettlementAuditPlaintextV1, PrivateSettlementAuditPolicyBodyV1,
        PrivateSettlementAuditPolicyV1, PrivateSettlementAuditViewKeyAuthorizationBodyV1,
        PrivateSettlementAuditViewKeyAuthorizationV1, PrivateSettlementAuditViewKeySignatureV1, PrivateSettlementAuditorV1,
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
    domain::DomainId,
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

/// Synthetic `PrivateSettlementAuditPlaintextV1` for leg 0, canonically Norito-encoded, bound to `manifest`.
///
/// Why a typed plaintext: `private_settlement_audit_plaintext_commitment_v1` (iroha_core audit.rs:86-91) forwards to
/// iroha_data_model nexus/private_settlement.rs:188-201, which runs `norito::decode_canonical::<PrivateSettlementAuditPlaintextV1>`
/// and then `.validate()`; any failure (arbitrary bytes, non-canonical bytes, an invalid shape) is reported as
/// `CanonicalEncoding`, despite the doc comment at audit.rs:84. The seal re-runs the same commitment check (audit.rs:136).
///
/// Built in the upstream order (sidecar_store.rs:4268-4390): plaintext first, then the manifest commitments that
/// are derived from it (asset binding :4314, reimbursement terms :4316, bundle id :4318), then `plaintext.bundle_id`
/// (:4319), then the view-key (:4365) and payer (:4390) authorizations, whose bodies embed the final bundle id.
/// `validate()` checks authorization shape, not signatures (nexus/private_settlement.rs:779, :923, :1129), so the sponsor
/// output is signed by a throwaway stand-in key: this crate never holds the sponsor's private key.
/// The note openings are synthetic and not tied to the statement's encrypted outputs; nothing opens the capsule here.
fn probe_audit_plaintext(salt: &[u8; 32], manifest: &mut AtomicPrivateSettlementV1, nullifiers: &[PrivacyNullifierV1]) -> Result<Vec<u8>, ErrorBody> {
    const AMOUNT: u128 = 42;
    const REIMBURSEMENT: u128 = 5;
    let d = |label: &str| derived(salt, label);
    let h = |label: &str| Hash::new(d(label));
    let key = |label: &str| KeyPair::from_seed(d(label).to_vec(), Algorithm::Ed25519);
    let (payer, recipient, sponsor_stand_in) = (key("payer"), key("recipient"), key("sponsor-stand-in"));
    let (network_id, bundle_id, route) = (manifest.network_id, manifest.bundle_id, manifest.legs[0].route);

    // Placeholders so the struct exists; the real bodies embed the final bundle id and fixed slots, so they replace these below.
    let view_key_placeholder = |signer: &KeyPair| {
        PrivateSettlementAuditViewKeyAuthorizationV1::new(
            PrivateSettlementAuditViewKeyAuthorizationBodyV1 {
                version: ATOMIC_PRIVATE_SETTLEMENT_VERSION_V1,
                purpose: h("placeholder"),
                network_id,
                bundle_id,
                leg_ordinal: 0,
                route,
                output_ordinal: 0,
                role: PrivateSettlementAuditOutputRoleV1::SettlementRecipient,
                authorized_account: AccountId::new(signer.public_key().clone()),
                recipient_view_key: [0; 32],
                output_active: false,
                note_spending_authority: [0; 32],
                expiry_height: 0,
            },
            Vec::new(),
        )
    };
    // dummy slot when value == 0 (nexus/private_settlement.rs:1264 NoteOpening::validate)
    let opening = |label: &str, value: u128, commitment: [u8; 32]| -> Result<PrivateSettlementAuditNoteOpeningV1, ErrorBody> {
        let active = value != 0;
        Ok(PrivateSettlementAuditNoteOpeningV1 {
            active,
            commitment: PrivacyCommitmentV1::new(commitment),
            value,
            spending_authority: derive_note_authority_v1(&d(&format!("{label}-spend"))).map_err(dbg("note authority"))?,
            rho: d(&format!("{label}-rho")),
            blinding: d(&format!("{label}-blinding")),
            memo_digest: d(&format!("{label}-memo")),
            dummy_domain: (!active).then(|| h(&format!("{label}-dummy"))),
        })
    };

    // Fixed 2-in/3-out shape and balance (private_settlement.rs:1807-1900): inputs 47 + 0, outputs 42 + 0 + 5.
    let signers = [&recipient, &payer, &sponsor_stand_in];
    let roles = [
        PrivateSettlementAuditOutputRoleV1::SettlementRecipient,
        PrivateSettlementAuditOutputRoleV1::PayerChange,
        PrivateSettlementAuditOutputRoleV1::SponsorReimbursement,
    ];
    let mut outputs = Vec::with_capacity(roles.len());
    for (i, (role, value)) in roles.into_iter().zip([AMOUNT, 0, REIMBURSEMENT]).enumerate() {
        outputs.push(PrivateSettlementAuditOutputV1 {
            role,
            recipient_view_key: ivm_private_recipient_public_key_v1(&d(&format!("view-secret{i}"))).map_err(dbg("output view key"))?,
            view_key_authorization: view_key_placeholder(signers[i]),
            encryption_opening: PrivateSettlementAuditEncryptionOpeningV1 { ephemeral_secret: d(&format!("ephemeral-secret{i}")) },
            note: opening(&format!("out{i}"), value, d(&format!("commitment{i}")))?,
        });
    }
    let asset_definition_id = AssetDefinitionId::derive_from_components(
        DomainId::try_new("bank-a", "regulated").map_err(dbg("probe domain"))?,
        "cbdc".parse().map_err(dbg("probe asset name"))?,
    );
    let mut plaintext = PrivateSettlementAuditPlaintextV1 {
        version: ATOMIC_PRIVATE_SETTLEMENT_VERSION_V1,
        network_id,
        bundle_id,
        leg_ordinal: 0,
        route,
        pool_id: manifest.legs[0].pool_id,
        payer: AccountId::new(payer.public_key().clone()),
        payer_authorization: PrivateSettlementAuditPayerAuthorizationV1::new(
            PrivateSettlementAuditPayerAuthorizationBodyV1 {
                version: ATOMIC_PRIVATE_SETTLEMENT_VERSION_V1,
                purpose: h("placeholder"),
                network_id,
                bundle_id,
                leg_ordinal: 0,
                route,
                payer: AccountId::new(payer.public_key().clone()),
                expiry_height: 0,
                inputs: Vec::new(),
            },
            Vec::new(),
        ),
        recipient: AccountId::new(recipient.public_key().clone()),
        sponsor: manifest.sponsor.clone(),
        asset_definition_id,
        asset_binding_salt: d("asset-binding-salt"),
        amount: AMOUNT,
        sponsor_reimbursement_amount: REIMBURSEMENT,
        fee_intent_digest: manifest.fee_intent_digest,
        settlement_expiry_height: manifest.expiry_height,
        reimbursement_terms_salt: d("reimbursement-terms-salt"),
        memo: b"rd-dfabi availability-share probe".to_vec(),
        policy_references: Vec::new(),
        inputs: vec![opening("in0", AMOUNT + REIMBURSEMENT, d("in0-commitment"))?, opening("in1", 0, d("in1-commitment"))?],
        outputs,
    };

    // Manifest commitments derived from the plaintext, then the bundle id they feed (not payload/delta digests: bundle_id_material excludes them).
    manifest.legs[0].asset_binding_commitment = plaintext.asset_binding_commitment().map_err(dbg("asset binding commitment"))?;
    manifest.reimbursement_terms_commitment = plaintext.reimbursement_terms_commitment().map_err(dbg("reimbursement terms commitment"))?;
    manifest.bundle_id = manifest.computed_bundle_id().map_err(dbg("bundle id"))?;
    plaintext.bundle_id = manifest.bundle_id;

    for (i, signer) in signers.into_iter().enumerate() {
        let body = plaintext.output_view_key_authorization_body(i).map_err(dbg("view key authorization body"))?;
        let signature = SignatureOf::try_new(signer.private_key(), &body).map_err(dbg("view key authorization signature"))?;
        plaintext.outputs[i].view_key_authorization =
            PrivateSettlementAuditViewKeyAuthorizationV1::new(body, vec![PrivateSettlementAuditViewKeySignatureV1::new(signer.public_key().clone(), signature)]);
    }
    let body = plaintext.payer_authorization_body(nullifiers).map_err(dbg("payer authorization body"))?;
    let signature = SignatureOf::try_new(payer.private_key(), &body).map_err(dbg("payer authorization signature"))?;
    plaintext.payer_authorization =
        PrivateSettlementAuditPayerAuthorizationV1::new(body, vec![PrivateSettlementAuditPayerSignatureV1::new(payer.public_key().clone(), signature)]);

    plaintext.validate().map_err(dbg("audit plaintext"))?;
    norito::encode_canonical(&plaintext).map_err(dbg("audit plaintext encoding"))
}

/// Build the PrivateSettlementProvisionalLegMaterialV1 for leg 0 (dataspace `plan.tested`) and return its Norito JSON.
///
/// Mirrors the upstream fixture `provisional_material_fixture` (iroha_core/src/private_settlement/sidecar_store.rs:4102,
/// `sidecar_fixture_with_threshold_and_ordinal` :4129) with three differences: the audit plaintext is synthetic (the
/// validator never opens the capsule; the plaintext must still be a canonical, valid `PrivateSettlementAuditPlaintextV1`,
/// see `probe_audit_plaintext`), the proof is a 128-byte placeholder (the STARK is verified at prepare, not here), and the
/// committee is the live roster, not a seeded one.
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

    // Capsule: the plaintext is a synthetic but canonical audit plaintext; it also fixes the leg-0 asset binding, the
    // reimbursement terms and the bundle id on the manifest. Sealed to the auditor with the real hybrid KEM + XChaCha20-Poly1305.
    let nullifiers = vec![PrivacyNullifierV1::new(d("nullifier0")), PrivacyNullifierV1::new(d("nullifier1"))];
    let plaintext = probe_audit_plaintext(&plan.salt, &mut manifest, &nullifiers)?;
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
        // KiB16 as in sidecar_store.rs:4468 and wallet.rs:1521; the seal limit is the class minus the 8-byte frame header
        // (audit.rs:34, :269-272). The canonical plaintext (5 note openings, 4 signed authorizations) was not measured against
        // the 4096-byte class and upstream never seals one at KiB4 here; the 16384 class is in the shipped
        // capsule_padding_classes_bytes (iroha_config defaults.rs:3269) and in the handler's check (iroha_torii private_settlement.rs:1078).
        PrivateSettlementCapsulePaddingV1::KiB16,
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
        nullifiers: nullifiers.clone(),
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
    // The same check the handler runs last (iroha_torii/src/private_settlement.rs:1084), here before anything is sent.
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

/// Run by CI after the release build: `cargo test --release --locked -p rd-dfabi --features aps`.
/// Every key, hash and id below is generated from a fixed label inside this module; none exists outside the test run.
#[cfg(test)]
mod tests {
    use iroha_core::private_settlement::{PrivateSettlementAuditCryptoErrorV1, open_private_settlement_audit_capsule_v1};
    use iroha_data_model::block::BlockHeader;

    use super::*;
    use crate::probe::{AuditorPublic, RosterEntry, parse_lifecycle, sorted_roster};

    fn keypair(label: &str, algorithm: Algorithm) -> KeyPair {
        KeyPair::from_seed(derived(&[0x5E; 32], label).to_vec(), algorithm)
    }

    fn known_auditor() -> (AuditorPublic, HybridKeyPair) {
        let mut rng = iroha_crypto::rng_from_seed_slice(b"rd-dfabi synthetic test auditor");
        let hybrid = HybridKeyPair::generate(&mut rng).expect("hybrid key");
        let public = AuditorPublic {
            signing_public_key: keypair("auditor", Algorithm::Ed25519).public_key().to_string(),
            x25519: hybrid.public().x25519_bytes(),
            ml_kem_768: hybrid.public().kyber_bytes().to_vec(),
        };
        (public, hybrid)
    }

    /// Four BLS committee keys with real PoPs, a lifecycle for dataspaces 1 and 2, a synthetic network id and sponsor.
    fn synthetic_plan(auditor: Option<AuditorPublic>) -> Plan {
        let roster: Vec<RosterEntry> = (0..4)
            .map(|i| {
                let key = keypair(&format!("committee{i}"), Algorithm::BlsNormal);
                RosterEntry {
                    public_key: key.public_key().to_string(),
                    pop: iroha_crypto::bls_normal_pop_prove(key.private_key()).expect("PoP"),
                }
            })
            .collect();
        // Hash::from_str wants the least significant bit set, which Hash::new guarantees.
        let incarnation = |label: &str| {
            let hash = Hash::new(label.as_bytes());
            let bytes: &[u8] = hash.as_ref();
            hex::encode_upper(bytes)
        };
        let lifecycle = serde_json::json!({
            "lanes": [{"id": 1, "dataspace_id": 1}, {"id": 2, "dataspace_id": 2}],
            "incarnations": [
                {"lane_id": 1, "incarnation": incarnation("synthetic lane 1")},
                {"lane_id": 2, "incarnation": incarnation("synthetic lane 2")}
            ]
        })
        .to_string();
        Plan {
            network_id: NetworkId::from_genesis_hash(HashOf::<BlockHeader>::from_untyped_unchecked(Hash::new(b"synthetic genesis"))).to_string(),
            sponsor_public_key: keypair("sponsor", Algorithm::Ed25519).public_key().to_string(),
            context_height: 34,
            expiry_blocks: 7000,
            retention_blocks: 1_100_000,
            roster: sorted_roster(roster).expect("roster"),
            tested: parse_lifecycle(&lifecycle, 1).expect("lane 1"),
            other: parse_lifecycle(&lifecycle, 2).expect("lane 2"),
            auditor,
            chain_discriminant: None,
            salt: [7; 32],
        }
    }

    /// Builds through the real entry point (which runs material.validate() and the JSON round trip) and parses the output again.
    fn material_of(plan: &Plan) -> PrivateSettlementProvisionalLegMaterialV1 {
        let json = availability_share_material(plan).expect("material builds");
        crate::probe::check_material_shape(&json).expect("nine fields");
        norito::json::from_str(&json).expect("material parses")
    }

    #[test]
    fn material_with_a_throwaway_auditor_validates_and_round_trips() {
        let material = material_of(&synthetic_plan(None));
        material.validate().expect("material validates");
        material.manifest.validate_provisional().expect("provisional manifest");
        assert_eq!(material.audit_capsule.padding.plaintext_bytes(), PrivateSettlementCapsulePaddingV1::KiB16.plaintext_bytes());
        assert_eq!(material.audit_capsule.aad.plaintext_commitment, material.statement.audit_plaintext_commitment);
        assert_eq!(material.manifest.legs[0].audit_policy_digest, material.audit_policy.policy_digest);
        assert_eq!(material.committee_authority.validators.len(), 4);
    }

    #[test]
    fn capsule_opens_to_the_canonical_plaintext_bound_to_the_manifest() {
        let (auditor, hybrid) = known_auditor();
        let material = material_of(&synthetic_plan(Some(auditor)));
        let auditor_id = material.audit_policy.body.auditors[0].auditor_id.clone();
        let opened = open_private_settlement_audit_capsule_v1(&material.audit_capsule, &material.audit_policy, &auditor_id, hybrid.secret())
            .expect("the governed auditor opens the capsule");
        // The commitment function decodes a typed plaintext (nexus/private_settlement.rs:188-201); the statement carries its result.
        assert_eq!(private_settlement_audit_plaintext_commitment_v1(&opened).expect("commitment"), material.statement.audit_plaintext_commitment);
        let plaintext: PrivateSettlementAuditPlaintextV1 = norito::decode_canonical(&opened).expect("canonical plaintext");
        assert_eq!(norito::encode_canonical(&plaintext).expect("re-encode").as_slice(), opened.as_slice());
        assert_eq!(plaintext.commitment().expect("commitment"), material.statement.audit_plaintext_commitment);
        // validate_against_manifest wants final certificate digests (settlement_validation.rs:165); bundle id and commitments ignore them.
        let mut manifest = material.manifest.clone();
        for leg in &mut manifest.legs {
            leg.availability_certificate_digest = Hash::new(b"certificate stand-in");
        }
        plaintext.validate_against_manifest(&manifest).expect("plaintext matches the manifest leg");
        assert_eq!(plaintext.bundle_id, material.manifest.bundle_id);
    }

    /// The bug that produced `plaintext commitment: CanonicalEncoding`: a text marker is not a canonical audit plaintext.
    #[test]
    fn commitment_rejects_bytes_that_are_not_a_canonical_audit_plaintext() {
        let result = private_settlement_audit_plaintext_commitment_v1(b"rd-dfabi availability-share probe 0011223344556677");
        assert!(matches!(result, Err(PrivateSettlementAuditCryptoErrorV1::CanonicalEncoding)));
    }
}
