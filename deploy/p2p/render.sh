#!/usr/bin/env bash
# Print the external p2p LoadBalancer Service of one party. Writes nothing, calls no cluster.
#   deploy/p2p/render.sh bi|bank-a|bank-b             cluster 1
#   deploy/p2p/render.sh --cluster 2 bank-c           cluster 2 (separate GO)
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
use='usage: render.sh [--cluster 1|2] bi|bank-a|bank-b|bank-c'
cluster=1
if [[ ${1:-} == --cluster ]]; then
  cluster=${2:-}; [[ $cluster == 1 || $cluster == 2 ]] || { echo "$use" >&2; exit 2; }
  shift 2
fi
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
sed "s/@PARTY@/$what/g" "$here/p2p-lb.yaml.tpl"
