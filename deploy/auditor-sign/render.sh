#!/usr/bin/env bash
# Print the in-namespace SIGNING Job of an AUDITOR client leaf (S13 dependency D2; analyst P1 condition 4; lensa-sign pattern). Writes nothing, calls no cluster, renders NO Secret.
#   deploy/auditor-sign/render.sh <bi|bank-a|bank-b> <sha256:<64 hex> driver image digest> <csr-file>
# The auditor's client key is made by the org in its OWN namespace session (deploy/auditor-sign/keygen.sh, /dev/shm only); only the PUBLIC CSR comes here. Objects in rd-iroha3-<party>:
# ConfigMap auditor-client-csr, Job auditor-client-sign (mounts the org's OWN role CA Secret iroha3-role-ca read-only 0400, re-checks the CSR, signs with its OWN extension file,
# prints ONLY the public certificate) and NetworkPolicy auditor-client-sign-egress (deny-all egress: the pod holds the CA key and needs no network). CSR checked HERE and again in the
# Job: valid signature, subject exactly CN=<party>-auditor, EC P-256, NO requested extensions. Leaf = CA:FALSE, keyUsage digitalSignature, EKU clientAuth ONLY.
# Creating the Job needs a named time-boxed Role (R13) granted by the operator through lead, with a one-line log and "RBAC left" quoted afterwards.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
usage() { echo "usage: render.sh bi|bank-a|bank-b <sha256:<64 hex> image digest> <csr-file>" >&2; exit 2; }
(( $# == 3 )) || usage
party=$1 digest=$2 csr=$3
case $party in bi | bank-a | bank-b) ;; *) usage ;; esac
[[ $digest =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "render.sh: the image must be pinned by a digest (sha256:<64 lowercase hex>), not a tag: got '$digest'" >&2; exit 2; }
[[ -f $csr ]] || { echo "render.sh: CSR file $csr not found" >&2; exit 2; }
grep -q 'PRIVATE KEY' "$csr" && { echo "render.sh: $csr contains a private key: only the PUBLIC CSR goes in" >&2; exit 2; }
grep -q 'BEGIN CERTIFICATE REQUEST' "$csr" || { echo "render.sh: $csr is not a PEM CSR" >&2; exit 2; }
openssl req -in "$csr" -noout -verify >/dev/null 2>&1 || { echo "render.sh: the CSR signature does not verify (or the CSR is malformed)" >&2; exit 2; }
[[ $(openssl req -in "$csr" -noout -subject -nameopt RFC2253 2>/dev/null) == "subject=CN=$party-auditor" ]] || { echo "render.sh: the CSR subject must be exactly CN=$party-auditor" >&2; exit 2; }
txt=$(openssl req -in "$csr" -noout -text 2>/dev/null)
[[ $txt == *"prime256v1"* && $txt == *"id-ecPublicKey"* ]] || { echo "render.sh: the CSR key must be EC P-256" >&2; exit 2; }
[[ -z $(awk '/Requested Extensions:/{f=1;next} /Signature Algorithm/{f=0} f&&NF' <<<"$txt") ]] || { echo "render.sh: the CSR requests extensions (SAN/CA/...): none are allowed, the signer sets its own" >&2; exit 2; }
exec python3 -I "$here/render.py" "$party" "$digest" "$csr"
