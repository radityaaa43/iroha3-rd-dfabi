#!/usr/bin/env bash
# Operator-run from PC: KUBECONFIG=/path/to/alibaba.yaml deploy/runner/install.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
export KUBECONFIG="${KUBECONFIG:-./alibaba.yaml}"
EXPECTED=https://172.24.11.196:6443
server=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
[ "$server" = "$EXPECTED" ] || { echo "refusing: context server '$server' != $EXPECTED" >&2; exit 1; }

kubectl apply -f deploy/runner/rbac.yaml
token=$(gh api -X POST repos/radityaaa43/iroha3-rd-dfabi/actions/runners/registration-token --jq .token)
kubectl create secret generic gha-runner-registration \
  --from-literal=RUNNER_TOKEN="$token" -n iroha3 --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl apply -f deploy/runner/
