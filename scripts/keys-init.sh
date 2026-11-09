#!/usr/bin/env bash
# Operator PC, once: generate APS wallet and BI auditor keys, load them as Secrets in
# namespace iroha3, print the public keys for deploy/k8s-apps/rd-dfabi.toml auditor.parties.
#
#   KUBECONFIG=/abs/path/alibaba.yaml scripts/keys-init.sh <driver-tag>
#
# Seeds are written to $KEYS (default ~/iroha3-keys, mode 700) and kept there: losing
# bi-auditor.hybrid means stored capsules can no longer be re-decrypted (O5 retention).
# Refuses to overwrite existing seeds or Secrets; rotating keys is a separate decision.
# Uses server-side apply so no last-applied annotation copies the seeds into the Secret.
set -euo pipefail

TAG=${1:?usage: $0 <driver-tag>}
IMAGE=ghcr.io/radityaaa43/iroha3-rd-driver:$TAG
KEYS=${KEYS:-$HOME/iroha3-keys}
NS=iroha3
WALLETS=(bi bank-a bank-b bank-c)
export KUBECONFIG="${KUBECONFIG:?set KUBECONFIG to the cluster kubeconfig (absolute path)}"
EXPECTED=https://172.24.11.196:6443
server=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
[ "$server" = "$EXPECTED" ] || { echo "refusing: context server '$server' != $EXPECTED" >&2; exit 1; }

for s in rd-dfabi-wallets bi-auditor-key; do
  if kubectl get secret "$s" -n "$NS" >/dev/null 2>&1; then
    echo "refusing: Secret $s already exists in $NS" >&2; exit 1
  fi
done

umask 077
mkdir -p "$KEYS"
chmod 700 "$KEYS"
docker pull -q "$IMAGE" >/dev/null
for f in "${WALLETS[@]/%/.seed}" bi-auditor.seed bi-auditor.hybrid; do
  [ -e "$KEYS/$f" ] && { echo "refusing: $KEYS/$f exists" >&2; exit 1; }
done
run() { docker run --rm --network none --user "$(id -u):$(id -g)" -v "$KEYS:/k" "$IMAGE" "$@"; }
for name in "${WALLETS[@]}" bi-auditor; do run keys new /k "$name"; done
# Capsule decryption key: random (upstream ML-KEM generation is hedged, not seed-derivable).
run keys new-hybrid /k bi-auditor

apply() { kubectl label --local -f - app.kubernetes.io/part-of=iroha3-rd-driver -o yaml |
  kubectl apply -n "$NS" --server-side --field-manager=iroha3-keys -f -; }
args=()
for name in "${WALLETS[@]}"; do args+=(--from-file="$name.seed=$KEYS/$name.seed"); done
kubectl create secret generic rd-dfabi-wallets -n "$NS" "${args[@]}" --dry-run=client -o yaml | apply
kubectl create secret generic bi-auditor-key -n "$NS" --from-file="bi-auditor.seed=$KEYS/bi-auditor.seed" \
  --from-file="bi-auditor.hybrid=$KEYS/bi-auditor.hybrid" --dry-run=client -o yaml | apply

echo
echo "Put these wallet public keys in deploy/k8s-apps/rd-dfabi.toml [auditor] parties:"
for name in "${WALLETS[@]}"; do run keys show /k "$name"; done
