#!/usr/bin/env bash
# Print the S17 per-bank driver server manifests of one party (iroha3 PLAN S17, ARCHITECTURE-iroha3 10a, docs/server-mode.md):
# ConfigMap driver-config (public values only), Deployment driver, Service driver, NetworkPolicy driver-ingress. Writes nothing,
# calls no cluster, renders NO Secret: the bank creates Secret `<party>-keys` (<party>.seed, <party>.note, client.toml) itself with its
# own kubeconfig. The image is pinned by digest; the pod pulls it with the imagePullSecret `ghcr-pull` of the namespace.
#   deploy/driver/render.sh <bi|bank-a|bank-b|bank-c> <sha256:digest> <public-dir>
# <public-dir> (network/public or ~/iroha3-new/public) holds chain_id, genesis.expected_hash (names ConfigMap genesis-<hash8>) and
# peers.json; it must hold no private material. bank-c (cluster 2) renders the same objects: no zone or node pin anywhere.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
usage() { echo "usage: render.sh bi|bank-a|bank-b|bank-c <sha256:<64 hex> image digest> <public-dir>" >&2; exit 2; }
(( $# == 3 )) || usage
party=$1 digest=$2 pub=$3
case $party in bi | bank-a | bank-b | bank-c) ;; *) usage ;; esac
[[ $digest =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "render.sh: the image must be pinned by a digest (sha256:<64 lowercase hex>), not a tag: got '$digest'" >&2; exit 2; }
[[ -d $pub ]] || { echo "render.sh: public dir $pub not found" >&2; exit 2; }
for f in chain_id genesis.expected_hash peers.json; do [[ -f $pub/$f ]] || { echo "render.sh: $pub/$f is missing" >&2; exit 2; }; done
[[ -z $(find "$pub" \( -name '*.seed' -o -name '*.note' -o -name '*.hybrid' -o -name private.key \) -print -quit) ]] \
  || { echo "render.sh: $pub holds private material (*.seed, *.note, *.hybrid or private.key); public files only" >&2; exit 2; }
exec python3 -I "$here/render.py" "$party" "$digest" "$pub" "$here/../../network"
