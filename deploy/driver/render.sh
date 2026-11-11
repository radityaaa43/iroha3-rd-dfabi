#!/usr/bin/env bash
# Print the S17 per-bank driver server manifests of one party (iroha3 PLAN S17, ARCHITECTURE-iroha3 10a, docs/server-mode.md):
# ConfigMap driver-config (public values only), Deployment driver, Service driver, NetworkPolicy driver-ingress. Writes nothing,
# calls no cluster, renders NO Secret: the bank creates Secret `<party>-keys` (<party>.seed, <party>.note, client.toml) itself with its
# own kubeconfig. The image is pinned by digest; the pod pulls it with the imagePullSecret `ghcr-pull` of the namespace.
#   deploy/driver/render.sh <bi|bank-a|bank-b|bank-c> <sha256:digest> <public-dir> [--audit-tls]
# --audit-tls also renders NetworkPolicy driver-egress (R17: DNS, the own party's Torii 8080, the gateways on 8443: same-cluster ones by namespace
# selector, the gateways of the OTHER cluster only as explicit --remote-gw-cidr <ip>/32 (their external LB addresses; repeatable)).
# --audit-tls (iroha3 S13 transport A): adds `[audit] min_approvals = 2` with the three gateway URLs (bi, bank-a, bank-b) and `[tls]` to
# rd-dfabi.toml, the Secret volume iroha3-client-cert (tls.crt, tls.key 0400, /tls/client) and the ConfigMap gateway-server-cas (the 4 PUBLIC
# <party>-server-ca.pem from <public-dir>/gateway-ca/, /tls/cas). Without it the output is unchanged.
# <public-dir> (network/public or ~/iroha3-new/public) holds chain_id, genesis.expected_hash (names ConfigMap genesis-<hash8>) and
# peers.json; it must hold no private material. bank-c (cluster 2) renders the same objects: no zone or node pin anywhere.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
usage() { echo "usage: render.sh bi|bank-a|bank-b|bank-c <sha256:<64 hex> image digest> <public-dir> [--audit-tls [--remote-gw-cidr <ipv4>/32]...]" >&2; exit 2; }
(( $# >= 3 )) || usage
party=$1 digest=$2 pub=$3; shift 3
tls="" remote=()
if (( $# )); then
  [[ $1 == --audit-tls ]] || usage
  tls=$1; shift
  while (( $# )); do
    [[ $1 == --remote-gw-cidr && $# -ge 2 ]] || usage
    [[ $2 =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/32$ ]] || { echo "render.sh: --remote-gw-cidr must be an IPv4 /32 (the external address of a gateway load balancer on the other cluster): got '$2'" >&2; exit 2; }
    remote+=("$2"); shift 2
  done
fi
case $party in bi | bank-a | bank-b | bank-c) ;; *) usage ;; esac
[[ $digest =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "render.sh: the image must be pinned by a digest (sha256:<64 lowercase hex>), not a tag: got '$digest'" >&2; exit 2; }
[[ -d $pub ]] || { echo "render.sh: public dir $pub not found" >&2; exit 2; }
for f in chain_id genesis.expected_hash peers.json; do [[ -f $pub/$f ]] || { echo "render.sh: $pub/$f is missing" >&2; exit 2; }; done
[[ -z $(find "$pub" \( -name '*.seed' -o -name '*.note' -o -name '*.hybrid' -o -name private.key \) -print -quit) ]] \
  || { echo "render.sh: $pub holds private material (*.seed, *.note, *.hybrid or private.key); public files only" >&2; exit 2; }
if [[ -n $tls ]]; then
  for q in bi bank-a bank-b bank-c; do [[ -f $pub/gateway-ca/$q-server-ca.pem ]] || { echo "render.sh: $pub/gateway-ca/$q-server-ca.pem is missing (public server CA of $q)" >&2; exit 2; }; done
  grep -l 'PRIVATE KEY' "$pub"/gateway-ca/*.pem >/dev/null 2>&1 && { echo "render.sh: $pub/gateway-ca holds a private key" >&2; exit 2; }
fi
exec python3 -I "$here/render.py" "$party" "$digest" "$pub" "$here/../../network" "$tls" "${remote[@]}"
