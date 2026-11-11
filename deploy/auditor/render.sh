#!/usr/bin/env bash
# Print the S11/S12 auditor manifests of one party (iroha3 PLAN S11 BI auditor, S12 orgs A and B; ANALYST 2-of-3, condition (a): each
# auditor key is generated and held ONLY in its own org namespace). Writes nothing, calls no cluster, renders NO Secret: the org creates
# Secret `<key-name>-key` (bi: bi-auditor-key; bank-a: bank-a-auditor-key; bank-b: bank-b-auditor-key; keys <name>.seed and <name>.hybrid)
# itself with its own kubeconfig (deploy/auditor/org-secret.sh). Image = the driver image WITH the S12 `[auditor] key_name` support.
#   deploy/auditor/render.sh <bi|bank-a|bank-b> <sha256:digest> <public-dir>
# <public-dir> holds chain_id, genesis.expected_hash, peers.json and accounts.json (public keys of bi, bank-a, bank-b, bank-c, bi-gov;
# the 4 trading accounts become the auditor's `parties`); it must hold no private material.
# Objects in rd-iroha3-<party>: ConfigMap auditor-config, PVC audit-store, Deployment auditor, Service auditor (8090), NetworkPolicy
# auditor-ingress (TCP 8090 from the own gateway pods only; the bank and cross-cluster route is the gateway, S14).
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
usage() { echo "usage: render.sh bi|bank-a|bank-b <sha256:<64 hex> image digest> <public-dir>" >&2; exit 2; }
(( $# == 3 )) || usage
party=$1 digest=$2 pub=$3
case $party in bi | bank-a | bank-b) ;; *) usage ;; esac
[[ $digest =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "render.sh: the image must be pinned by a digest (sha256:<64 lowercase hex>), not a tag: got '$digest'" >&2; exit 2; }
[[ -d $pub ]] || { echo "render.sh: public dir $pub not found" >&2; exit 2; }
for f in chain_id genesis.expected_hash peers.json accounts.json; do [[ -f $pub/$f ]] || { echo "render.sh: $pub/$f is missing" >&2; exit 2; }; done
[[ -z $(find "$pub" \( -name '*.seed' -o -name '*.note' -o -name '*.hybrid' -o -name private.key \) -print -quit) ]] \
  || { echo "render.sh: $pub holds private material (*.seed, *.note, *.hybrid or private.key); public files only" >&2; exit 2; }
exec python3 -I "$here/render.py" "$party" "$digest" "$pub" "$here/../../network"
