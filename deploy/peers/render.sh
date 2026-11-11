#!/usr/bin/env bash
# Print the peer manifests of one cluster-1 party: headless Service, StatefulSet, NetworkPolicies peers-p2p, peers-torii
# and the temporary torii-bootstrap. Writes nothing, calls no cluster.
#   deploy/peers/render.sh [--clb-health-cidr 100.64.0.0/10] <bi|bank-a|bank-b> <genesis-hash8> <bank-c-external-cidr>      cluster 1
#   deploy/peers/render.sh [--clb-health-cidr 100.64.0.0/10] --cluster 2 bank-c <genesis-hash8> <cluster-1-egress-cidr>   cluster 2 (S8)
# --p2p-egress-cidr <ipv4>/32 (repeatable, opt-in; R17 end step) also renders NetworkPolicy peers-egress: the ONLY egress of the peer pod = cluster DNS, P2P 1337 and Torii 8080
# to the same-cluster peers (exact namespaces) and P2P 1337 to the OTHER cluster's external LB addresses given here (bank-c LB for the c1 peers; the three c1 LBs for bank-c).
# --clb-health-cidr (opt-in, only that value) adds one ipBlock to peers-p2p: Alibaba CLB health checks and forwarding come
# from 100.64.0.0/10. Apply it ONLY after a whitelist ACL is attached to the listener; without one it opens 1337 to the internet.
# bank-c is cluster 2 and needs --cluster 2 (S8): no PriorityClass (it is cluster-scoped and not ours on cluster 2), no cluster-1 node
# exclusion, StorageClass `fabricx-essd` (WaitForFirstConsumer, reclaim Retain; a class of the fabricx team that we only USE: read its
# provisioner, volumeBindingMode and reclaimPolicy before the apply, never create or edit it). `alicloud-essd` on cluster 2 is Immediate.
# bank-c also gets memory request 512Mi (cluster 2 is full; "GO resize" 2026-11-12): CPU request 250m and the limits 2000m/3Gi stay.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
clb="" c2="" egress=()
# prefix flags in any order: --clb-health-cidr 100.64.0.0/10 | --cluster 2 | --p2p-egress-cidr <ipv4>/32 (repeatable)
while (( $# )); do
  case $1 in
    --clb-health-cidr)
      [[ ${2:-} == 100.64.0.0/10 ]] || { echo "render.sh: --clb-health-cidr accepts only 100.64.0.0/10" >&2; exit 2; }
      clb=1; shift 2 ;;
    --cluster)
      [[ ${2:-} == 2 ]] || { echo "usage: render.sh [--cluster 2] <party> <genesis-hash8> <cidr>" >&2; exit 2; }
      c2=1; shift 2 ;;
    --p2p-egress-cidr)
      [[ -n ${2:-} ]] || { echo "usage: render.sh --p2p-egress-cidr <ipv4>/32 ... (value missing)" >&2; exit 2; }
      [[ $2 =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/32$ && $2 != 0.0.0.0/32 ]] || { echo "render.sh: --p2p-egress-cidr must be a single IPv4 /32 (the OTHER cluster's external LB address), never wider: got '$2'" >&2; exit 2; }
      egress+=("$2"); shift 2 ;;
    *) break ;;
  esac
done
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
tel='"rd-iroha3-bank-a", "rd-iroha3-bank-b", "rd-iroha3-bi"' # the cluster-1 peers poll each other's Torii (telemetry); bank-c has none (below)
p2pns=$tel; [[ $party == bank-c ]] && p2pns='"rd-iroha3-bank-c"' # P2P from same-cluster peers: exact namespace names (form ruling), never a part-of label wildcard
sed -e "s|@P2P_NS@|$p2pns|g" -e "s|@TELEMETRY_NS@|$tel|g" -e "s|@PARTY@|$party|g" -e "s|@GENESIS_HASH8@|$hash8|g" -e "s|@BANKC_LB_CIDR@|$cidr|g" "$here/peer.yaml.tpl" |
  awk -v clb="$clb" '/^@CLB_HEALTH@$/ { if (clb) { print "        - ipBlock:"; print "            cidr: \"100.64.0.0/10\"" } next } { print }' |
  awk -v c2="$c2" '
    /^        # @TELEMETRY-BEGIN@$/ { if (c2) skip_t = 1; next }
    /^        # @TELEMETRY-END@$/ { skip_t = 0; next }
    skip_t { next }
    !c2 { print; next }
    /^      priorityClassName:/ { next }
    /^        nodeAffinity:$/ { skip = 1; next }
    skip && /^        podAntiAffinity:$/ { skip = 0 }
    skip { next }
    # bank-c on cluster 2 (full): memory REQUEST 1Gi -> 512Mi so it can be scheduled; CPU request and all limits unchanged
    /^              memory: 1Gi$/ { print "              memory: 512Mi"; next }
    { gsub(/alicloud-essd-wffc/, "fabricx-essd"); print }'
# R17 end step: the ONE narrow Egress policy of the peer pod (only with --p2p-egress-cidr). Destinations/ports: see the header; everything else is denied.
if (( ${#egress[@]} )); then
  echo "---"
  echo "# Egress of the peer pod: cluster DNS; P2P 1337 and Torii 8080 to the peers of this cluster (exact namespaces, the pod label); P2P 1337 to the OTHER cluster's external LB"
  echo "# addresses only (network/s5.py:351-353: other cluster by external address; telemetry URLs: same-cluster peers only, :361). Nothing else leaves the pod."
  echo "apiVersion: networking.k8s.io/v1"
  echo "kind: NetworkPolicy"
  echo "metadata:"
  echo "  name: peers-egress"
  echo "  namespace: rd-iroha3-$party"
  echo "  labels:"
  echo "    app.kubernetes.io/part-of: rd-iroha3"
  echo "spec:"
  echo "  podSelector:"
  echo "    matchLabels:"
  echo "      rd-iroha3/role: peer"
  echo "  policyTypes: [Egress]"
  echo "  egress:"
  echo "    - to:"
  echo "        - namespaceSelector:"
  echo "            matchLabels:"
  echo "              kubernetes.io/metadata.name: kube-system"
  echo "          podSelector:"
  echo "            matchLabels:"
  echo "              k8s-app: kube-dns"
  echo "      ports:"
  echo "        - {protocol: UDP, port: 53}"
  echo "        - {protocol: TCP, port: 53}"
  for port in 1337 NONE 8080; do
    if [[ $port == NONE ]]; then
      echo "    - to:"
      for c in "${egress[@]}"; do echo "        - ipBlock:"; echo "            cidr: \"$c\""; done
      echo "      ports:"; echo "        - {protocol: TCP, port: 1337}"
      continue
    fi
    echo "    - to:"
    for n in ${p2pns//,/ }; do
      echo "        - namespaceSelector:"
      echo "            matchLabels:"
      echo "              kubernetes.io/metadata.name: ${n//\"/}"
      echo "          podSelector:"
      echo "            matchLabels:"
      echo "              rd-iroha3/role: peer"
    done
    echo "      ports:"; echo "        - {protocol: TCP, port: $port}"
  done
fi
