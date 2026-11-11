#!/usr/bin/env bash
# Print the namespace manifests for one party, or the cluster-scoped PriorityClass. Writes nothing, calls no cluster.
#   deploy/ns/render.sh [--ns-only] bi|bank-a|bank-b     cluster 1: Namespace, default-deny-ingress, ServiceAccount, Role, RoleBinding
#   deploy/ns/render.sh priorityclass                    cluster 1: PriorityClass rd-iroha3-peer
#   deploy/ns/render.sh --cluster 2 [--ns-only] bank-c   cluster 2: the same five objects; NO PriorityClass on cluster 2;
#                                                        Namespace label cluster: "2"
# --ns-only prints only the Namespace doc (PLAN S1a = GO 1); without it the full set (S1b = GO 2).
# bank-c is cluster 2 only and needs --cluster 2 (separate GO); the flag accepts nothing but bank-c.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
use='usage: render.sh [--cluster 1|2] [--ns-only] bi|bank-a|bank-b|bank-c|priorityclass'
cluster=1 nsonly=0
while [[ ${1:-} == --* ]]; do
  case $1 in
    --cluster) cluster=${2:-}; [[ $cluster == 1 || $cluster == 2 ]] || { echo "$use" >&2; exit 2; }; shift 2 ;;
    --ns-only) nsonly=1; shift ;;
    *) echo "$use" >&2; exit 2 ;;
  esac
done
what=${1:-}
render() { # <party> <cluster>
  local doc
  if [[ $2 == 2 ]]; then doc=$(sed -e "s/@PARTY@/$1/g" -e 's/@CLUSTER_LABEL@/cluster: "2"/' "$here/party.yaml.tpl")
  else doc=$(sed -e "s/@PARTY@/$1/g" -e '/@CLUSTER_LABEL@/d' "$here/party.yaml.tpl"); fi
  if (( nsonly )); then awk 'BEGIN{RS="\n---\n"} NR==1{print; exit}' <<<"$doc"; else printf '%s\n' "$doc"; fi
}
if [[ $cluster == 2 ]]; then
  case $what in
    bank-c) render bank-c 2 ;;
    priorityclass) echo "render.sh: no PriorityClass on cluster 2 (a priority above the default could preempt foreign pods)" >&2; exit 2 ;;
    *) echo "render.sh: cluster 2 renders bank-c only" >&2; exit 2 ;;
  esac
else
  case $what in
    bi | bank-a | bank-b) render "$what" 1 ;;
    priorityclass) (( nsonly )) && { echo "render.sh: --ns-only does not apply to the PriorityClass" >&2; exit 2; }; cat "$here/priorityclass.yaml" ;;
    bank-c) echo "render.sh: bank-c is on cluster 2 (separate GO); use --cluster 2" >&2; exit 2 ;;
    *) echo "$use" >&2; exit 2 ;;
  esac
fi
