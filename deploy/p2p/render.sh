#!/usr/bin/env bash
# Print the external p2p LoadBalancer Service of one party. Writes nothing, calls no cluster.
#   deploy/p2p/render.sh --acl-id <id> --external-cidr X/32 [--external-cidr Y/32 ...] bi|bank-a|bank-b        cluster 1
#   deploy/p2p/render.sh --cluster 2 --acl-id <id> --external-cidr X/32 [...] bank-c                            cluster 2 (separate GO)
# --acl-id (required) is the Alibaba access-control list holding the same /32 list; it becomes the acl-status/acl-type/acl-id
# annotations. loadBalancerSourceRanges alone creates no ACL on the CLB listener.
# --external-cidr is the peer cluster's egress address as a /32 (cluster-1 LBs: bank C's egress; the bank-C LB: cluster 1's
# egress). Never wider: anything but a single IPv4 /32 is refused. It becomes loadBalancerSourceRanges.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
use='usage: render.sh [--cluster 1|2] --acl-id <id> --external-cidr X/32 [--external-cidr Y/32 ...] bi|bank-a|bank-b|bank-c'
cluster=1
acl=""
have_acl=""
ranges=()
while [[ ${1:-} == --* ]]; do
  case $1 in
    --cluster) cluster=${2:-}; [[ $cluster == 1 || $cluster == 2 ]] || { echo "$use" >&2; exit 2; }; shift 2 ;;
    --acl-id)
      acl=${2:-}; have_acl=1
      [[ $acl =~ ^[A-Za-z0-9][A-Za-z0-9._-]{1,63}$ ]] || { echo "render.sh: --acl-id must be the id of an existing Alibaba access-control list (letters, digits, . _ -), got '$acl'" >&2; exit 2; }
      shift 2 ;;
    --external-cidr)
      c=${2:-}
      [[ $c =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/32$ && $c != 0.0.0.0/32 ]] || { echo "render.sh: --external-cidr must be a single IPv4 /32 (got '$c')" >&2; exit 2; }
      ranges+=("$c"); shift 2 ;;
    *) echo "$use" >&2; exit 2 ;;
  esac
done
what=${1:-}
if [[ $cluster == 2 ]]; then
  [[ $what == bank-c ]] || { echo "render.sh: cluster 2 renders bank-c only" >&2; exit 2; }
else
  case $what in
    bi | bank-a | bank-b) ;;
    bank-c) echo "render.sh: bank-c is on cluster 2 (separate GO); use --cluster 2" >&2; exit 2 ;;
    *) echo "$use" >&2; exit 2 ;;
  esac
fi
[[ -n $have_acl ]] || { echo "render.sh: --acl-id is required: every p2p Service carries the whitelist ACL annotations" >&2; exit 2; }
(( ${#ranges[@]} )) || { echo "render.sh: at least one --external-cidr X/32 is required" >&2; exit 2; }
list=$(printf '    - "%s"\n' "${ranges[@]}")
awk -v party="$what" -v list="$list" -v acl="$acl" '{ gsub(/@PARTY@/, party); gsub(/@ACL_ID@/, acl) } /^@SOURCE_RANGES@$/ { print list; next } { print }' "$here/p2p-lb.yaml.tpl"
