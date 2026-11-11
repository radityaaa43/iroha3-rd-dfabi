#!/usr/bin/env bash
# Print the namespace manifests for one party, or the cluster-scoped PriorityClass. Writes nothing, calls no cluster.
#   deploy/ns/render.sh bi|bank-a|bank-b           cluster 1: Namespace, default-deny-ingress, ServiceAccount, Role, RoleBinding
#   deploy/ns/render.sh priorityclass              cluster 1: PriorityClass rd-iroha3-peer
#   deploy/ns/render.sh --cluster 2 bank-c         cluster 2: the same five objects; NO PriorityClass on cluster 2
# bank-c is cluster 2 only and needs the flag (cluster 2 is a separate GO); the flag accepts nothing but bank-c.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
cluster=1
if [[ ${1:-} == --cluster ]]; then
  cluster=${2:-}
  [[ $cluster == 1 || $cluster == 2 ]] || { echo "usage: render.sh [--cluster 1|2] bi|bank-a|bank-b|priorityclass|bank-c" >&2; exit 2; }
  shift 2 || true
fi
what=${1:-}
if [[ $cluster == 2 ]]; then
  case $what in
    bank-c) sed "s/@PARTY@/bank-c/g" "$here/party.yaml.tpl" ;;
    priorityclass) echo "render.sh: no PriorityClass on cluster 2 (a priority above the default could preempt foreign pods)" >&2; exit 2 ;;
    *) echo "render.sh: cluster 2 renders bank-c only" >&2; exit 2 ;;
  esac
else
  case $what in
    bi | bank-a | bank-b) sed "s/@PARTY@/$what/g" "$here/party.yaml.tpl" ;;
    priorityclass) cat "$here/priorityclass.yaml" ;;
    bank-c) echo "render.sh: bank-c is on cluster 2 (separate GO); use --cluster 2" >&2; exit 2 ;;
    *) echo "usage: render.sh [--cluster 1|2] bi|bank-a|bank-b|priorityclass|bank-c" >&2; exit 2 ;;
  esac
fi
