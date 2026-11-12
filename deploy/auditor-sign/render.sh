#!/usr/bin/env bash
# Print the in-namespace objects that give an AUDITOR its mTLS client leaf (S13 dependency D2; analyst P1 condition 4 + ruling OPTION C on the key: the key is made INSIDE a pod
# in the auditor's own namespace and never leaves it). Writes nothing, calls no cluster, renders NO Secret (the org creates the EMPTY Secret auditor-client-cert itself:
# `kubectl create secret generic auditor-client-cert -n rd-iroha3-<party>`, no data).
#   deploy/auditor-sign/render.sh keygen <bi|bank-a|bank-b> <tools-image@sha256:digest> --apiserver <ip>/32:<port> [--apiserver ...]
#       SA auditor-client-api + Role (get/update/patch on resourceNames [auditor-client-cert] ONLY) + RoleBinding + NetworkPolicy auditor-client-api-egress (egress = the given API server
#       addresses ONLY) + Job auditor-client-keygen: refuses a non-empty Secret, makes the EC P-256 key + CSR (CN=<party>-auditor) in the pod, patches ONLY tls.key into the Secret, prints ONLY the CSR.
#   deploy/auditor-sign/render.sh sign <bi|bank-a|bank-b> <sha256:<64 hex> driver image digest> <csr-file>
#       ConfigMap auditor-client-csr + Job auditor-client-sign (the org's OWN role CA Secret iroha3-role-ca, read-only 0400; prints ONLY the public cert) + NetworkPolicy auditor-client-sign-egress (deny-all).
#   deploy/auditor-sign/render.sh put <bi|bank-a|bank-b> <tools-image@sha256:digest> <cert-file>
#       ConfigMap auditor-client-crt (the PUBLIC cert) + Job auditor-client-put (same SA/Role/NetworkPolicy as keygen): patches ONLY tls.crt into the Secret. Then the org deletes Jobs, ConfigMaps,
#       Role, RoleBinding, SA, NetworkPolicy ("RBAC left: []"). The Role, RoleBinding and SA are R13 objects (operator, time-boxed, one-line log); the rest is party-admin.
# The CSR / certificate are checked HERE and again in the Job: valid signature, subject exactly CN=<party>-auditor, EC P-256, NO requested extensions; leaf = CA:FALSE, digitalSignature, clientAuth ONLY.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
usage() { echo "usage: render.sh keygen|put <bi|bank-a|bank-b> <tools-image@sha256:<64 hex>> (--apiserver <ip>/32:<port> ... | <cert-file>) | render.sh sign <bi|bank-a|bank-b> <sha256:<64 hex>> <csr-file>" >&2; exit 2; }
(( $# >= 4 )) || usage
stage=$1 party=$2 image=$3; shift 3
case $party in bi | bank-a | bank-b) ;; *) usage ;; esac
case $stage in
  sign)
    (( $# == 1 )) || usage
    csr=$1; digest=$image
    [[ $digest =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "render.sh: the image must be pinned by a digest (sha256:<64 lowercase hex>), not a tag: got '$digest'" >&2; exit 2; }
    [[ -f $csr ]] || { echo "render.sh: CSR file $csr not found" >&2; exit 2; }
    grep -q 'PRIVATE KEY' "$csr" && { echo "render.sh: $csr contains a private key: only the PUBLIC CSR goes in" >&2; exit 2; }
    grep -q 'BEGIN CERTIFICATE REQUEST' "$csr" || { echo "render.sh: $csr is not a PEM CSR" >&2; exit 2; }
    openssl req -in "$csr" -noout -verify >/dev/null 2>&1 || { echo "render.sh: the CSR signature does not verify (or the CSR is malformed)" >&2; exit 2; }
    [[ $(openssl req -in "$csr" -noout -subject -nameopt RFC2253 2>/dev/null) == "subject=CN=$party-auditor" ]] || { echo "render.sh: the CSR subject must be exactly CN=$party-auditor" >&2; exit 2; }
    txt=$(openssl req -in "$csr" -noout -text 2>/dev/null)
    [[ $txt == *"prime256v1"* && $txt == *"id-ecPublicKey"* ]] || { echo "render.sh: the CSR key must be EC P-256" >&2; exit 2; }
    [[ -z $(awk '/Requested Extensions:/{f=1;next} /Signature Algorithm/{f=0} f&&NF' <<<"$txt") ]] || { echo "render.sh: the CSR requests extensions (SAN/CA/...): none are allowed, the signer sets its own" >&2; exit 2; }
    exec python3 -I "$here/render.py" sign "$party" "$digest" "$csr" ;;
  keygen | put)
    [[ $image =~ @sha256:[0-9a-f]{64}$ ]] || { echo "render.sh: the tools image must be pinned by a digest (<repo>@sha256:<64 lowercase hex>), not a tag: got '$image'" >&2; exit 2; }
    if [[ $stage == keygen ]]; then
      api=()
      while (( $# )); do
        [[ $1 == --apiserver && -n ${2:-} ]] || usage
        [[ $2 =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/32:[0-9]{1,5}$ ]] || { echo "render.sh: --apiserver must be <ipv4>/32:<port> (got '$2')" >&2; exit 2; }
        api+=("$2"); shift 2
      done
      (( ${#api[@]} >= 1 )) || usage
      exec python3 -I "$here/render.py" keygen "$party" "$image" "${api[@]}"
    fi
    (( $# == 1 )) || usage
    crt=$1
    [[ -f $crt ]] || { echo "render.sh: certificate file $crt not found" >&2; exit 2; }
    grep -q 'PRIVATE KEY' "$crt" && { echo "render.sh: $crt contains a private key: only the PUBLIC certificate goes in" >&2; exit 2; }
    [[ $(grep -c 'BEGIN' "$crt") -eq 1 && $(grep -c 'BEGIN CERTIFICATE' "$crt") -eq 1 ]] || { echo "render.sh: $crt must hold exactly one certificate" >&2; exit 2; }
    [[ $(openssl x509 -in "$crt" -noout -subject -nameopt RFC2253 2>/dev/null) == "subject=CN=$party-auditor" ]] || { echo "render.sh: the certificate subject must be exactly CN=$party-auditor" >&2; exit 2; }
    ctxt=$(openssl x509 -in "$crt" -noout -text 2>/dev/null)
    [[ $ctxt == *"CA:FALSE"* && $ctxt == *"TLS Web Client Authentication"* && $ctxt != *"TLS Web Server Authentication"* ]] || { echo "render.sh: the certificate must be CA:FALSE with clientAuth only" >&2; exit 2; }
    exec python3 -I "$here/render.py" put "$party" "$image" "$crt" ;;
  *) usage ;;
esac
