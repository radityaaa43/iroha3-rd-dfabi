#!/usr/bin/env bash
# Print the in-namespace SIGNING Job of the Iroha Lensa client cert (W2, orchestrator option 2; fabric s14-sign pattern). Writes nothing, calls no cluster, renders NO Secret.
#   deploy/lensa-sign/render.sh <bi|bank-a|bank-b|bank-c> <sha256:<64 hex> driver image digest> <csr-file>
# Objects in rd-iroha3-<party>: ConfigMap lensa-csr (the PUBLIC CSR made by the Lensa side; its private key never reaches here), Job lensa-sign (mounts Secret
# iroha3-lensa-ca read-only 0400, checks the CSR, signs with its OWN extension file, prints ONLY the public certificate to its log) and NetworkPolicy
# lensa-sign-egress (deny-all egress: the pod holds the CA key and needs no network). The CSR is checked HERE and again inside the Job: signature valid, subject
# exactly CN=lensa, EC P-256, NO requested extensions (no SAN, no CA:TRUE). The render refuses a file that also contains a private key.
# Creating the Job needs the named time-boxed Role s14-lensa-sign (R13); see the W2 text.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
usage() { echo "usage: render.sh bi|bank-a|bank-b|bank-c <sha256:<64 hex> image digest> <csr-file>" >&2; exit 2; }
(( $# == 3 )) || usage
party=$1 digest=$2 csr=$3
case $party in bi | bank-a | bank-b | bank-c) ;; *) usage ;; esac
[[ $digest =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "render.sh: the image must be pinned by a digest (sha256:<64 lowercase hex>), not a tag: got '$digest'" >&2; exit 2; }
[[ -f $csr ]] || { echo "render.sh: CSR file $csr not found" >&2; exit 2; }
grep -q 'PRIVATE KEY' "$csr" && { echo "render.sh: $csr contains a private key: only the PUBLIC CSR goes in" >&2; exit 2; }
grep -q 'BEGIN CERTIFICATE REQUEST' "$csr" || { echo "render.sh: $csr is not a PEM CSR" >&2; exit 2; }
openssl req -in "$csr" -noout -verify >/dev/null 2>&1 || { echo "render.sh: the CSR signature does not verify (or the CSR is malformed)" >&2; exit 2; }
[[ $(openssl req -in "$csr" -noout -subject -nameopt RFC2253 2>/dev/null) == "subject=CN=lensa" ]] || { echo "render.sh: the CSR subject must be exactly CN=lensa" >&2; exit 2; }
txt=$(openssl req -in "$csr" -noout -text 2>/dev/null)
[[ $txt == *"prime256v1"* && $txt == *"id-ecPublicKey"* ]] || { echo "render.sh: the CSR key must be EC P-256" >&2; exit 2; }
# a plain CSR prints an EMPTY "Requested Extensions:" header; any line between it and the signature algorithm is a requested extension
[[ -z $(awk '/Requested Extensions:/{f=1;next} /Signature Algorithm/{f=0} f&&NF' <<<"$txt") ]] || { echo "render.sh: the CSR requests extensions (SAN/CA/...): none are allowed, the signer sets its own" >&2; exit 2; }
exec python3 -I "$here/render.py" "$party" "$digest" "$csr"
