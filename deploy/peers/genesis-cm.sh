#!/usr/bin/env bash
# PRINT an immutable ConfigMap `genesis-<hash8>` for rd-iroha3-<party> (iroha3 PLAN S7). Writes nothing, calls no cluster.
#   deploy/peers/genesis-cm.sh <bi|bank-a|bank-b|bank-c> <public-dir> | kubectl apply -f -
# ConfigMaps are not in the party-admin Role: pipe this to `kubectl apply` with the ADMIN kubeconfig (not a party one).
# <public-dir> holds genesis.signed.nrt and genesis.expected_hash (`hash:<64 hex>#<crc>`); hash8 = its first 8 hex chars, lowercase.
# The expected_hash value ends with exactly one LF: iroha3d refuses the mounted file otherwise ("must contain exactly one LF-terminated
# canonical public identity", live S7b 2026-11-11), and `$(<file)` strips the LF the file on disk has.
# Refuses a public dir that holds any *.seed, *.note, *.hybrid or private.key.
set -euo pipefail
party=${1:-} dir=${2:-}
[[ $# -eq 2 ]] || { echo "usage: genesis-cm.sh <bi|bank-a|bank-b|bank-c> <public-dir>" >&2; exit 2; }
case $party in bi|bank-a|bank-b|bank-c) ;; *) echo "genesis-cm.sh: unknown party $party (want bi, bank-a, bank-b or bank-c)" >&2; exit 2 ;; esac
[[ -d $dir ]] || { echo "genesis-cm.sh: public dir $dir not found" >&2; exit 2; }
for f in genesis.signed.nrt genesis.expected_hash; do
  [[ -f $dir/$f ]] || { echo "genesis-cm.sh: $dir/$f is missing" >&2; exit 2; }
done
[[ -z $(find "$dir" \( -name '*.seed' -o -name '*.note' -o -name '*.hybrid' -o -name private.key \) -print -quit) ]] \
  || { echo "genesis-cm.sh: $dir holds private material (*.seed, *.note, *.hybrid or private.key); public files only" >&2; exit 2; }
hash=$(<"$dir/genesis.expected_hash")
[[ $hash =~ ^hash:([0-9A-Fa-f]{64})#[0-9A-Fa-f]{4}$ ]] || { echo "genesis-cm.sh: $dir/genesis.expected_hash is not hash:<64 hex>#<crc>" >&2; exit 2; }
h8=${BASH_REMATCH[1]:0:8}; h8=${h8,,}
cat <<YAML
apiVersion: v1
kind: ConfigMap
metadata:
  name: genesis-$h8
  namespace: rd-iroha3-$party
  labels:
    app.kubernetes.io/part-of: rd-iroha3
    rd-iroha3/party: $party
immutable: true
binaryData:
  genesis.signed.nrt: $(base64 -w0 "$dir/genesis.signed.nrt")
data:
  genesis.expected_hash: "$hash\n"
YAML
