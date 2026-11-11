#!/usr/bin/env bash
# Print the S14 gateway manifests (Envoy + OPA) of one party (iroha3 PLAN S14, ARCHITECTURE-iroha3 DELTA 13, pattern of the
# Fabric-X gateway rd-fabric-x#37 569675c). Writes nothing, calls no cluster, reads no key, renders NO Secret.
#   deploy/gateway/render.sh <bi|bank-a|bank-b|bank-c> --envoy-image <repo@sha256:..> --opa-image <repo@sha256:..> \
#       --opa-config <file> [--cluster 1|2] [--lb-acl acl-xxxx --lb-range <ipv4>/32 ...]
# Objects in ns rd-iroha3-<party>: ConfigMaps gateway-envoy and gateway-opa, Deployment gateway (envoy + opa), Service gateway
# (ClusterIP 8443), NetworkPolicy gateway-ingress (TCP 8443, no `from`: mTLS + OPA are the control), and the Lensa/peer path:
# cluster 1 (bi, bank-a, bank-b) Service gateway-ext (NodePort), cluster 2 (bank-c) Service gateway-lb (LoadBalancer, ONLY with an
# existing ACL: --lb-acl and --lb-range are required there; on cluster 1 they are optional (both or none) and ADD gateway-lb next to the
# NodePort Service, for the clients of the other cluster (PLAN S14: one external listener per namespace).
# The Secrets `gateway-server` (tls.crt, tls.key) and `gateway-client-ca` (ca.crt) are created OUTSIDE the render, by the party.
# --opa-config is the party's OPA config with PUBLIC bundle-signing keys only (a PRIVATE KEY string is refused); it also carries the
# `plugins.envoy_ext_authz_grpc` block, which is kept as given.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
usage() {
  echo "usage: render.sh bi|bank-a|bank-b|bank-c --envoy-image <repo@sha256:64 hex> --opa-image <repo@sha256:64 hex> --opa-config <file> [--cluster 1|2] [--lb-acl acl-xxxx --lb-range <ipv4>/32 ...]" >&2
  exit 2
}
die() { echo "render.sh: $*" >&2; exit 2; }
(( $# >= 1 )) || usage
party=$1; shift
case $party in bi | bank-a | bank-b | bank-c) ;; *) usage ;; esac
envoy="" opa="" cfg="" cluster="" acl="" ranges=()
while (( $# )); do
  case $1 in
    --envoy-image) envoy=${2:-}; shift 2 ;;
    --opa-image) opa=${2:-}; shift 2 ;;
    --opa-config) cfg=${2:-}; shift 2 ;;
    --cluster) cluster=${2:-}; shift 2 ;;
    --lb-acl) acl=${2:-}; shift 2 ;;
    --lb-range) ranges+=("${2:-}"); shift 2 ;;
    *) usage ;;
  esac
done
digest='^[a-z0-9][a-z0-9./_-]*@sha256:[0-9a-f]{64}$'
[[ $envoy =~ $digest ]] || die "--envoy-image must be pinned by a digest (repo@sha256:<64 lowercase hex>), not a tag: got '$envoy'"
[[ $opa =~ $digest ]] || die "--opa-image must be pinned by a digest (repo@sha256:<64 lowercase hex>), not a tag: got '$opa'"
[[ -f $cfg ]] || die "--opa-config $cfg not found"
grep -q 'PRIVATE KEY' "$cfg" && die "$cfg holds a private key (PRIVATE KEY); the OPA config of the render carries public keys only"
[[ -z $cluster ]] && { [[ $party == bank-c ]] && cluster=2 || cluster=1; }
case $cluster in 1 | 2) ;; *) die "--cluster must be 1 or 2" ;; esac
if [[ $party == bank-c ]]; then [[ $cluster == 2 ]] || die "bank-c runs on cluster 2: --cluster 2"; else [[ $cluster == 1 ]] || die "$party runs on cluster 1: no --cluster 2"; fi
if [[ $cluster == 2 ]]; then
  [[ -n $acl ]] || die "cluster 2 needs --lb-acl (an EXISTING Alibaba ACL id): no load balancer without an ACL"
  (( ${#ranges[@]} )) || die "cluster 2 needs at least one --lb-range <ipv4>/32"
else
  # cluster 1: the NodePort Service always; the cross-cluster LB (ACL-first) only when BOTH --lb-acl and --lb-range are given
  [[ -z $acl || ${#ranges[@]} -gt 0 ]] || die "--lb-acl needs at least one --lb-range <ipv4>/32"
  [[ -n $acl || ${#ranges[@]} -eq 0 ]] || die "--lb-range needs --lb-acl (an EXISTING Alibaba ACL id): no load balancer without an ACL"
fi
[[ -z $acl || $acl =~ ^acl-[a-z0-9]+$ ]] || die "--lb-acl '$acl' is not an Alibaba ACL id (acl-<lowercase alnum>)"
for r in "${ranges[@]}"; do [[ $r =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/32$ ]] || die "--lb-range '$r' must be <ipv4>/32"; done
exec python3 -I "$here/render.py" "$party" "$cluster" "$envoy" "$opa" "$cfg" "$acl" "${ranges[@]}"
