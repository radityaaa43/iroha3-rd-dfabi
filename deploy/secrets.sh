#!/usr/bin/env bash
# Operator-run from PC: KUBECONFIG=/abs/path/to/alibaba.yaml deploy/secrets.sh [--dry-run]
# KUBECONFIG should be an absolute path (this script cd's to the repo root).
# Loads peer-<party>/client-<party> Secrets and immutable genesis-<hash8> ConfigMap into ns iroha3.
# --dry-run: client-side apply only, no object data is sent. It still needs cluster
#            connectivity (kubectl fetches the openapi schema), but writes nothing.
# Real runs use server-side apply so no last-applied-configuration annotation (a copy of
# the private keys) is written into the Secrets.
# The ConfigMap is immutable and named by genesis hash: re-applying identical content is a
# no-op, differing content fails loudly (intended), so there is no exists-check.
set -euo pipefail

case "${1:-}" in
  "") APPLY=(--server-side --field-manager=iroha3-secrets) ;;
  --dry-run) APPLY=(--dry-run=client) ;;  # --server-side is incompatible with --dry-run=client
  *) echo "usage: $0 [--dry-run]" >&2; exit 2 ;;
esac

cd "$(dirname "$0")/.."
export KUBECONFIG="${KUBECONFIG:-./alibaba.yaml}"
EXPECTED=https://172.24.11.196:6443
server=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
[ "$server" = "$EXPECTED" ] || { echo "refusing: context server '$server' != $EXPECTED" >&2; exit 1; }

NS=iroha3
LABEL=app.kubernetes.io/part-of=iroha3-rd
PUB=network/public
PARTIES=(bi bank-a bank-b bank-c)

# Validate all inputs before touching the cluster.
for f in "$PUB"/genesis.{signed.nrt,public_key,expected_hash} \
         $(for p in "${PARTIES[@]}"; do echo "network/out/$p/peer.toml" "network/out/$p/client.toml"; done); do
  [ -r "$f" ] || { echo "missing or unreadable input: $f" >&2; exit 1; }
done
# hash:2986B430...#XXXX -> 2986b430
hash8=$(sed -E 's/^hash:([0-9A-Fa-f]{8}).*/\1/' "$PUB/genesis.expected_hash" | tr 'A-F' 'a-f')
[[ "$hash8" =~ ^[0-9a-f]{8}$ ]] || { echo "bad $PUB/genesis.expected_hash" >&2; exit 1; }
cm="genesis-$hash8"

# stdin: generated manifest -> add label locally -> apply
apply() { kubectl label --local -f - "$LABEL" -o yaml | kubectl apply -n "$NS" -f - ${APPLY[@]+"${APPLY[@]}"}; }

for party in "${PARTIES[@]}"; do
  out=network/out/$party
  kubectl create secret generic "peer-$party" -n "$NS" --from-file=peer.toml="$out/peer.toml" \
    --dry-run=client -o yaml | apply
  # client.toml points at network_id_file = "genesis.expected_hash" (relative), so ship it alongside
  kubectl create secret generic "client-$party" -n "$NS" --from-file=client.toml="$out/client.toml" \
    --from-file=genesis.expected_hash="$PUB/genesis.expected_hash" --dry-run=client -o yaml | apply
done

echo "genesis configmap: $cm"
{ kubectl create configmap "$cm" -n "$NS" --from-file="$PUB/genesis.signed.nrt" \
    --from-file="$PUB/genesis.public_key" --from-file="$PUB/genesis.expected_hash" \
    --dry-run=client -o yaml; echo "immutable: true"; } | apply
