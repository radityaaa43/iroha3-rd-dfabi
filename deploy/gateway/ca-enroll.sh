#!/usr/bin/env bash
# Gateway PKI of ONE org (iroha3 PLAN S14; analyst Q19 = the Fabric-X pattern; lead decision 2026-11-12: each org's role CA is generated
# and held in the org's OWN namespace, its key never leaves). Run by the org with its OWN party kubeconfig (KUBECTL, default kubectl).
#   deploy/gateway/ca-enroll.sh init  <bi|bank-a|bank-b|bank-c> <workdir>
#   deploy/gateway/ca-enroll.sh lensa-ca <bi|bank-a|bank-b|bank-c> <workdir>
#   deploy/gateway/ca-enroll.sh trust <bi|bank-a|bank-b|bank-c> <workdir> <pem>...
# init: makes (EC P-256) (1) the ROLE CA `iroha3-<party>-role-ca` (self-signed root) and the party's client identity leaf CN=<party>,
# EKU clientAuth, signed DIRECTLY by that CA; (2) the SERVER CA `iroha3-<party>-server-ca` and the gateway server cert
# (CN/SAN gateway.rd-iroha3-<party>.svc[.cluster.local], EKU serverAuth). Verifies both chains with openssl, then creates four Secrets in
# rd-iroha3-<party> by plain `kubectl create` (never apply: party-admin has no secrets get): gateway-server (tls.crt tls.key),
# iroha3-role-ca (ca.crt ca.key), iroha3-server-ca (ca.crt ca.key), iroha3-client-cert (tls.crt tls.key). The two public CA PEMs stay in
# <workdir>/public/ (their sha256 is printed) for besu (role CA, by name) and for pinning clients (server CA); every private file is
# shredded after the Secrets exist. A failed create leaves the work dir for a retry: fix, re-run `init` on a NEW work dir or finish by hand.
# lensa-ca (W2, orchestrator option 2): makes ONE separate Iroha Lensa client CA `iroha3-<party>-lensa-ca` (EC P-256, self-signed, CA:TRUE, pathlen 0), distinct
# from the role CA and from any Paladin CA, and creates ONLY Secret iroha3-lensa-ca (ca.crt ca.key) in rd-iroha3-<party> by plain `kubectl create`. The key
# exists only in /dev/shm while the Secret is made, then is shredded; the public PEM stays in <workdir>/public/<party>-lensa-ca.pem (sha256 printed) for the
# gateway trust bundle (`trust`) and for besu. Client certs (CN=lensa) are signed later IN the namespace by the lensa-sign Job, never here.
# trust: creates Secret gateway-client-ca (ca.crt = bundle of PUBLIC PEMs: this node's Lensa CA + the role CA of every party allowed to
# call this gateway); refuses a PEM that contains a private key.
# Private files only under /dev/shm and a mode-700 work dir (CA_ENROLL_ALLOW_DISK=1 only for the offline test). Prints no key.
set -euo pipefail
usage() { echo "usage: ca-enroll.sh init|lensa-ca <bi|bank-a|bank-b|bank-c> <workdir> | ca-enroll.sh trust <bi|bank-a|bank-b|bank-c> <workdir> <pem>..." >&2; exit 2; }
die() { echo "ca-enroll.sh: $*" >&2; exit 2; }
(( $# >= 3 )) || usage
cmd=$1 party=$2 W=$3; shift 3
case $party in bi | bank-a | bank-b | bank-c) ;; *) usage ;; esac
case $cmd in init | lensa-ca) (( $# == 0 )) || usage ;; trust) (( $# >= 1 )) || usage ;; *) usage ;; esac
ns=rd-iroha3-$party
KUBECTL=${KUBECTL:-kubectl}
[[ -d $W ]] || die "work dir $W not found"
W=$(cd "$W" && pwd -P)
[[ -n ${CA_ENROLL_ALLOW_DISK:-} || $W == /dev/shm/* ]] || die "the work dir must be under /dev/shm (private keys never touch disk)"
[[ $(stat -c %a "$W") == 700 ]] || die "the work dir must have mode 700 (is $(stat -c %a "$W"))"
umask 077
mk() { "$KUBECTL" create secret generic "$1" -n "$ns" "${@:2}" >/dev/null; echo "ca-enroll.sh: Secret $1 created in $ns (values not printed)"; }

if [[ $cmd == trust ]]; then
  : > "$W/client-ca.bundle"
  for pem in "$@"; do
    [[ -f $pem ]] || die "$pem not found"
    grep -q 'PRIVATE KEY' "$pem" && die "$pem contains a private key: only public CA PEMs go into the trust bundle"
    grep -q 'BEGIN CERTIFICATE' "$pem" || die "$pem is not a certificate PEM"
    cat "$pem" >> "$W/client-ca.bundle"
  done
  mk gateway-client-ca --from-file=ca.crt="$W/client-ca.bundle"
  rm -f "$W/client-ca.bundle"
  exit 0
fi

[[ ! -e $W/public ]] || die "$W/public already exists: use a fresh work dir"
mkdir "$W/public"
if [[ $cmd == lensa-ca ]]; then
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -keyout "$W/lensa-ca.key" -out "$W/lensa-ca.crt" -days 3650 -subj "/CN=iroha3-$party-lensa-ca" \
    -addext "basicConstraints=critical,CA:TRUE,pathlen:0" -addext "keyUsage=critical,keyCertSign,cRLSign" 2>/dev/null
  openssl verify -CAfile "$W/lensa-ca.crt" "$W/lensa-ca.crt" >/dev/null || die "the Lensa CA does not verify against itself"
  cp "$W/lensa-ca.crt" "$W/public/$party-lensa-ca.pem"
  mk iroha3-lensa-ca --from-file=ca.crt="$W/lensa-ca.crt" --from-file=ca.key="$W/lensa-ca.key"
  shred -u "$W/lensa-ca.key"; rm -f "$W"/*.crt "$W"/*.srl
  echo "ca-enroll.sh: public PEM in $W/public (sha256):"
  ( cd "$W/public" && sha256sum "./$party-lensa-ca.pem" )
  exit 0
fi
ec=(-newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes)
host=gateway.$ns.svc
# 1. role CA + client identity leaf, signed directly by the CA
openssl req -x509 "${ec[@]}" -keyout "$W/role-ca.key" -out "$W/role-ca.crt" -days 3650 -subj "/CN=iroha3-$party-role-ca" \
  -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" 2>/dev/null
openssl req -new "${ec[@]}" -keyout "$W/client.key" -out "$W/client.csr" -subj "/CN=$party" 2>/dev/null
printf 'basicConstraints=CA:FALSE\nkeyUsage=digitalSignature\nextendedKeyUsage=clientAuth\n' > "$W/client.ext"
openssl x509 -req -in "$W/client.csr" -CA "$W/role-ca.crt" -CAkey "$W/role-ca.key" -CAcreateserial -out "$W/client.crt" -days 365 -extfile "$W/client.ext" 2>/dev/null
openssl verify -CAfile "$W/role-ca.crt" -purpose sslclient "$W/client.crt" >/dev/null || die "client leaf does not verify against the role CA"
# 2. server CA + gateway server cert
openssl req -x509 "${ec[@]}" -keyout "$W/server-ca.key" -out "$W/server-ca.crt" -days 3650 -subj "/CN=iroha3-$party-server-ca" \
  -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" 2>/dev/null
openssl req -new "${ec[@]}" -keyout "$W/server.key" -out "$W/server.csr" -subj "/CN=$host" 2>/dev/null
printf 'basicConstraints=CA:FALSE\nkeyUsage=digitalSignature\nextendedKeyUsage=serverAuth\nsubjectAltName=DNS:%s,DNS:%s.cluster.local\n' "$host" "$host" > "$W/server.ext"
openssl x509 -req -in "$W/server.csr" -CA "$W/server-ca.crt" -CAkey "$W/server-ca.key" -CAcreateserial -out "$W/server.crt" -days 365 -extfile "$W/server.ext" 2>/dev/null
openssl verify -CAfile "$W/server-ca.crt" -purpose sslserver -verify_hostname "$host" "$W/server.crt" >/dev/null || die "server cert does not verify against the server CA"
# 3. public PEMs for besu / pinning clients, then the four Secrets
cp "$W/role-ca.crt" "$W/public/$party-role-ca.pem"; cp "$W/server-ca.crt" "$W/public/$party-server-ca.pem"
mk gateway-server --from-file=tls.crt="$W/server.crt" --from-file=tls.key="$W/server.key"
mk iroha3-role-ca --from-file=ca.crt="$W/role-ca.crt" --from-file=ca.key="$W/role-ca.key"
mk iroha3-server-ca --from-file=ca.crt="$W/server-ca.crt" --from-file=ca.key="$W/server-ca.key"
mk iroha3-client-cert --from-file=tls.crt="$W/client.crt" --from-file=tls.key="$W/client.key"
# 4. shred every private file; only public/ stays
for f in "$W"/*.key; do shred -u "$f"; done
rm -f "$W"/*.srl "$W"/*.csr "$W"/*.ext "$W"/*.crt
echo "ca-enroll.sh: public PEMs in $W/public (sha256):"
( cd "$W/public" && sha256sum ./*.pem )
