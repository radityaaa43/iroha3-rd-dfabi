#!/usr/bin/env bash
# Operator-run from PC: KUBECONFIG=/path/to/alibaba.yaml deploy/secrets.sh [--dry-run]
# Loads peer-<party>/client-<party> Secrets and immutable genesis-<hash8> ConfigMap into ns iroha3.
# --dry-run: client-side only, nothing is written to the cluster.
set -euo pipefail
cd "$(dirname "$0")/.."
export KUBECONFIG="${KUBECONFIG:-./alibaba.yaml}"
EXPECTED=https://172.24.11.196:6443
server=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
[ "$server" = "$EXPECTED" ] || { echo "refusing: context server '$server' != $EXPECTED" >&2; exit 1; }

DRY=()
case "${1:-}" in
  "") ;;
  --dry-run) DRY=(--dry-run=client) ;;
  *) echo "usage: $0 [--dry-run]" >&2; exit 2 ;;
esac
NS=iroha3
LABEL=app.kubernetes.io/part-of=iroha3-rd
PUB=network/public

# stdin: generated manifest -> add label locally -> apply (client-side only when --dry-run)
apply() { kubectl label --local -f - "$LABEL" -o yaml | kubectl apply -n "$NS" -f - "${DRY[@]}"; }

for party in bi bank-a bank-b bank-c; do
  out=network/out/$party
  kubectl create secret generic "peer-$party" -n "$NS" --from-file=peer.toml="$out/peer.toml" \
    --dry-run=client -o yaml | apply
  # client.toml points at network_id_file = "genesis.expected_hash" (relative), so ship it alongside
  kubectl create secret generic "client-$party" -n "$NS" --from-file=client.toml="$out/client.toml" \
    --from-file=genesis.expected_hash="$PUB/genesis.expected_hash" --dry-run=client -o yaml | apply
done

# hash:2986B430...#XXXX -> 2986b430
hash8=$(sed -E 's/^hash:([0-9A-Fa-f]{8}).*/\1/' "$PUB/genesis.expected_hash" | tr 'A-F' 'a-f')
[[ "$hash8" =~ ^[0-9a-f]{8}$ ]] || { echo "bad $PUB/genesis.expected_hash" >&2; exit 1; }
cm="genesis-$hash8"
echo "genesis configmap: $cm"
if kubectl get configmap "$cm" -n "$NS" >/dev/null 2>&1; then
  echo "configmap/$cm exists (immutable), skipping"
else
  { kubectl create configmap "$cm" -n "$NS" --from-file="$PUB/genesis.signed.nrt" \
      --from-file="$PUB/genesis.public_key" --from-file="$PUB/genesis.expected_hash" \
      --dry-run=client -o yaml; echo "immutable: true"; } | apply
fi
