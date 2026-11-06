#!/usr/bin/env bash
# DESTRUCTIVE. Deletes the 4 Iroha 3 StatefulSets and their data PVCs in ns iroha3
# (chain state is lost; redeploy afterwards). Operator-run from PC:
#   KUBECONFIG=/abs/path/to/alibaba.yaml scripts/wipe-network.sh [--dry-run]
# Names are explicit on purpose: no label selectors, so gha-runner and
# runner-state-gha-runner-0 (and every other namespace) can never match.
# --dry-run: print the plan and check the objects exist; deletes nothing, no prompt.
set -euo pipefail

DRY=0
case "${1:-}" in
  "") ;;
  --dry-run) DRY=1 ;;
  *) echo "usage: $0 [--dry-run]" >&2; exit 2 ;;
esac

cd "$(dirname "$0")/.."
export KUBECONFIG="${KUBECONFIG:-./alibaba.yaml}"
EXPECTED=https://172.24.11.196:6443
server=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
[ "$server" = "$EXPECTED" ] || { echo "refusing: context server '$server' != $EXPECTED" >&2; exit 1; }

NS=iroha3
STS=(bi bank-a bank-b bank-c)
PVC=(data-bi-0 data-bank-a-0 data-bank-b-0 data-bank-c-0)

echo "Namespace: $NS   (server $server)"
echo "Will delete StatefulSets:"
for s in "${STS[@]}"; do echo "  statefulset/$s"; done
echo "Will delete PVCs (all chain data):"
for p in "${PVC[@]}"; do echo "  pvc/$p"; done
echo "Untouched: everything else, including gha-runner and runner-state-gha-runner-0."
echo
echo "Currently present:"
kubectl -n "$NS" get statefulset "${STS[@]}" --ignore-not-found
kubectl -n "$NS" get pvc "${PVC[@]}" --ignore-not-found

# Refuse unless every existing target carries iroha3-rd/party=<its party> (the one label
# the StatefulSets and their PVCs share). Absent objects print nothing and are skipped.
for i in "${!STS[@]}"; do
  for t in "statefulset ${STS[i]}" "pvc ${PVC[i]}"; do
    # shellcheck disable=SC2086  # $t is "<kind> <name>"
    got=$(kubectl -n "$NS" get $t --ignore-not-found -o go-template='P={{with .metadata.labels}}{{index . "iroha3-rd/party"}}{{end}}')
    [ -z "$got" ] || [ "$got" = "P=${STS[i]}" ] || { echo "refusing: $t has iroha3-rd/party='${got#P=}', want '${STS[i]}'" >&2; exit 1; }
  done
done

if (( DRY )); then
  echo "dry-run: nothing deleted."
  exit 0
fi

read -r -p "Type 'yes' to delete the objects above: " ans
[ "$ans" = yes ] || { echo "aborted." >&2; exit 1; }

# Delete the StatefulSets first (pods go with them), then the PVCs they held.
kubectl -n "$NS" delete statefulset "${STS[@]}" --ignore-not-found --cascade=foreground --wait=true
kubectl -n "$NS" delete pvc "${PVC[@]}" --ignore-not-found --wait=true --timeout=300s
echo "done. Redeploy: deploy/secrets.sh, then run deploy.yml."
