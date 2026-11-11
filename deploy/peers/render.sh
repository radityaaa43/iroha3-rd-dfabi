#!/usr/bin/env bash
# Print the peer manifests of one cluster-1 party: headless Service, StatefulSet, NetworkPolicies peers-p2p, peers-torii
# and the temporary torii-bootstrap. Writes nothing, calls no cluster.
#   deploy/peers/render.sh <bi|bank-a|bank-b> <genesis-hash8> <bank-c-external-cidr>
# bank-c is cluster 2 (S8: no PriorityClass, cluster-2 StorageClass): refused here.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
usage() { echo "usage: render.sh bi|bank-a|bank-b <genesis-hash8> <bank-c-cidr>" >&2; exit 2; }
(( $# == 3 )) || { [[ ${1:-} == bank-c ]] && { echo "render.sh: bank-c is on cluster 2 (S8), not rendered here" >&2; exit 2; }; usage; }
party=$1 hash8=$2 cidr=$3
case $party in
  bi | bank-a | bank-b) ;;
  bank-c) echo "render.sh: bank-c is on cluster 2 (S8), not rendered here" >&2; exit 2 ;;
  *) usage ;;
esac
[[ $hash8 =~ ^[0-9a-f]{8}$ ]] || { echo "render.sh: hash8 must be 8 lowercase hex chars" >&2; exit 2; }
[[ $cidr =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/32$ && $cidr != 0.0.0.0/32 ]] || { echo "render.sh: cidr must be a single IPv4 /32 like 203.0.113.10/32, never wider" >&2; exit 2; }
sed -e "s|@PARTY@|$party|g" -e "s|@GENESIS_HASH8@|$hash8|g" -e "s|@BANKC_LB_CIDR@|$cidr|g" "$here/peer.yaml.tpl"
