#!/usr/bin/env bash
# Print the manifests for one cluster-1 party, or the cluster-scoped PriorityClass. Writes nothing, calls no cluster.
#   deploy/ns/render.sh bi|bank-a|bank-b     Namespace, default-deny-ingress, ServiceAccount, Role, RoleBinding
#   deploy/ns/render.sh priorityclass        PriorityClass rd-iroha3-peer
# bank-c lives on cluster 2 and is a separate GO: refused here.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
case "${1:-}" in
  bi | bank-a | bank-b) sed "s/@PARTY@/$1/g" "$here/party.yaml.tpl" ;;
  priorityclass) cat "$here/priorityclass.yaml" ;;
  bank-c) echo "render.sh: bank-c is on cluster 2 (separate GO); refused" >&2; exit 2 ;;
  *) echo "usage: render.sh bi|bank-a|bank-b|priorityclass" >&2; exit 2 ;;
esac
