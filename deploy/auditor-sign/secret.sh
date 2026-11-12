#!/usr/bin/env bash
# Org-side: after the signing Job printed the PUBLIC certificate, create Secret auditor-client-cert (tls.crt, tls.key) in rd-iroha3-<party> by plain `kubectl create` (never apply)
# with the org's own kubeconfig (KUBECTL), then shred the private key. Refuses a certificate that does not match the key, is not CN=<party>-auditor, is a CA or lacks clientAuth.
#   deploy/auditor-sign/secret.sh <bi|bank-a|bank-b> <workdir> <cert.pem>
set -euo pipefail
usage() { echo "usage: secret.sh bi|bank-a|bank-b <workdir> <cert.pem>" >&2; exit 2; }
die() { echo "secret.sh: $*" >&2; exit 2; }
(( $# == 3 )) || usage
party=$1 W=$2 crt=$3
case $party in bi | bank-a | bank-b) ;; *) usage ;; esac
KUBECTL=${KUBECTL:-kubectl}
[[ -f $W/tls.key && -f $crt ]] || die "needs <workdir>/tls.key and the certificate file"
W=$(cd "$W" && pwd -P)
[[ -n ${AUDITOR_SIGN_ALLOW_DISK:-} || $W == /dev/shm/* ]] || die "the work dir must be under /dev/shm"
[[ $(grep -c 'BEGIN' "$crt") -eq 1 && $(grep -c 'BEGIN CERTIFICATE' "$crt") -eq 1 ]] || die "$crt must hold exactly one certificate and nothing else"
[[ $(openssl x509 -in "$crt" -noout -subject -nameopt RFC2253) == "subject=CN=$party-auditor" ]] || die "the certificate subject must be exactly CN=$party-auditor"
txt=$(openssl x509 -in "$crt" -noout -text)
[[ $txt == *"CA:FALSE"* && $txt == *"TLS Web Client Authentication"* && $txt != *"TLS Web Server Authentication"* ]] || die "the certificate must be CA:FALSE with clientAuth only"
[[ $(openssl x509 -in "$crt" -noout -pubkey | sha256sum) == "$(openssl pkey -in "$W/tls.key" -pubout | sha256sum)" ]] || die "the certificate does not match the key"
"$KUBECTL" create secret generic auditor-client-cert -n "rd-iroha3-$party" --from-file=tls.crt="$crt" --from-file=tls.key="$W/tls.key" >/dev/null
echo "secret.sh: Secret auditor-client-cert created in rd-iroha3-$party (values not printed)"
chmod 600 "$W/tls.key"; shred -u "$W/tls.key"
