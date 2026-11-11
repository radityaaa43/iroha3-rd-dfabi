#!/usr/bin/env bash
# Print the peer manifests of one cluster-1 party: headless Service, StatefulSet, NetworkPolicies peers-p2p, peers-torii
# and the temporary torii-bootstrap. Writes nothing, calls no cluster.
#   deploy/peers/render.sh [--clb-health-cidr 100.64.0.0/10] <bi|bank-a|bank-b> <genesis-hash8> <bank-c-external-cidr>      cluster 1
#   deploy/peers/render.sh [--clb-health-cidr 100.64.0.0/10] --cluster 2 bank-c <genesis-hash8> <cluster-1-egress-cidr>   cluster 2 (S8)
# --clb-health-cidr (opt-in, only that value) adds one ipBlock to peers-p2p: Alibaba CLB health checks and forwarding come
# from 100.64.0.0/10. Apply it ONLY after a whitelist ACL is attached to the listener; without one it opens 1337 to the internet.
# bank-c is cluster 2 and needs --cluster 2 (S8): no PriorityClass (it is cluster-scoped and not ours on cluster 2), no cluster-1 node
# exclusion, StorageClass `fabricx-essd` (WaitForFirstConsumer, reclaim Retain; a class of the fabricx team that we only USE: read its
# provisioner, volumeBindingMode and reclaimPolicy before the apply, never create or edit it). `alicloud-essd` on cluster 2 is Immediate.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
clb=""
if [[ ${1:-} == --clb-health-cidr ]]; then
  [[ ${2:-} == 100.64.0.0/10 ]] || { echo "render.sh: --clb-health-cidr accepts only 100.64.0.0/10" >&2; exit 2; }
  clb=1; shift 2
fi
c2=""
if [[ ${1:-} == --cluster ]]; then
  [[ ${2:-} == 2 ]] || { echo "usage: render.sh [--cluster 2] <party> <genesis-hash8> <cidr>" >&2; exit 2; }
  c2=1; shift 2
fi
usage() { echo "usage: render.sh bi|bank-a|bank-b <genesis-hash8> <bank-c-cidr> | render.sh --cluster 2 bank-c <genesis-hash8> <cluster-1-egress-cidr>" >&2; exit 2; }
(( $# == 3 )) || { [[ ${1:-} == bank-c && -z $c2 ]] && { echo "render.sh: bank-c is on cluster 2 (S8): use --cluster 2" >&2; exit 2; }; usage; }
party=$1 hash8=$2 cidr=$3
if [[ -n $c2 ]]; then
  [[ $party == bank-c ]] || { echo "render.sh: --cluster 2 renders bank-c only" >&2; exit 2; }
else
  case $party in
    bi | bank-a | bank-b) ;;
    bank-c) echo "render.sh: bank-c is on cluster 2 (S8): use --cluster 2" >&2; exit 2 ;;
    *) usage ;;
  esac
fi
[[ $hash8 =~ ^[0-9a-f]{8}$ ]] || { echo "render.sh: hash8 must be 8 lowercase hex chars" >&2; exit 2; }
[[ $cidr =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/32$ && $cidr != 0.0.0.0/32 ]] || { echo "render.sh: cidr must be a single IPv4 /32 like 203.0.113.10/32, never wider" >&2; exit 2; }
sed -e "s|@PARTY@|$party|g" -e "s|@GENESIS_HASH8@|$hash8|g" -e "s|@BANKC_LB_CIDR@|$cidr|g" "$here/peer.yaml.tpl" |
  awk -v clb="$clb" '/^@CLB_HEALTH@$/ { if (clb) { print "        - ipBlock:"; print "            cidr: \"100.64.0.0/10\"" } next } { print }' |
  awk -v c2="$c2" '
    !c2 { print; next }
    /^      priorityClassName:/ { next }
    /^        nodeAffinity:$/ { skip = 1; next }
    skip && /^        podAntiAffinity:$/ { skip = 0 }
    skip { next }
    { gsub(/alicloud-essd-wffc/, "fabricx-essd"); print }'
