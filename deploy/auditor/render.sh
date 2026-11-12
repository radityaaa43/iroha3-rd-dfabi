#!/usr/bin/env bash
# Print the S11/S12 auditor manifests of one party (iroha3 PLAN S11 BI auditor, S12 orgs A and B; ANALYST 2-of-3, condition (a): each
# auditor key is generated and held ONLY in its own org namespace). Writes nothing, calls no cluster, renders NO Secret: the org creates
# Secret `<key-name>-key` (bi: bi-auditor-key; bank-a: bank-a-auditor-key; bank-b: bank-b-auditor-key; keys <name>.seed and <name>.hybrid)
# itself with its own kubeconfig (deploy/auditor/org-secret.sh). Image = the driver image WITH the S12 `[auditor] key_name` support.
#   deploy/auditor/render.sh <bi|bank-a|bank-b> <sha256:digest> <public-dir> [--keys-in-pvc]
# --keys-in-pvc (bank-a, bank-b only; orchestrator-approved 3b option 4): NO key Secret. An initContainer `keys` (same digest-pinned driver image, no SA token, no
# env, no egress change) creates the auditor key pair INTO the audit-store PVC (subPath keys) ONLY if both files are absent; it never overwrites, fails on a half pair,
# logs only the PUBLIC signing key and its sha256. The BI auditor keeps the Secret model.
# --gw-tls --bank-c-gw-cidr <ip>/32 (analyst ruling P1, 2026-11-12): the auditor reaches ALL FOUR parties only through their gateways (mTLS :8443). A second container `gw-tls` (the pinned official envoy,
# config only) listens on 127.0.0.1:18101-18104 (cleartext loopback between the two containers of ONE pod) and originates mTLS with the auditor's client leaf (Secret auditor-client-cert, created in-namespace,
# not rendered) pinning each target party's own server CA; the auditor's [torii] points at the loopback URLs. auditor-egress becomes DNS + the 4 gateways :8443 (bank-c's gateway-lb by /32): NO Torii.
# <public-dir> holds chain_id, genesis.expected_hash, peers.json and accounts.json (public keys of bi, bank-a, bank-b, bank-c, bi-gov;
# the 4 trading accounts become the auditor's `parties`); it must hold no private material.
# Objects in rd-iroha3-<party>: ConfigMap auditor-config, PVC audit-store, Deployment auditor, Service auditor (8090), NetworkPolicy
# auditor-ingress (TCP 8090 from the own gateway pods only; the bank and cross-cluster route is the gateway, S14).
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
usage() { echo "usage: render.sh bi|bank-a|bank-b <sha256:<64 hex> image digest> <public-dir> [--keys-in-pvc] [--gw-tls --bank-c-gw-cidr <public ipv4>/32]" >&2; exit 2; }
(( $# >= 3 )) || usage
party=$1 digest=$2 pub=$3; shift 3
flags=() pvc="" gw="" bankc=""
while (( $# )); do
  case $1 in
    --keys-in-pvc) [[ -z $pvc ]] || usage; pvc=1; flags+=(pvc); shift ;;
    --gw-tls) [[ -z $gw ]] || usage; gw=1; flags+=(gwtls); shift ;;
    --bank-c-gw-cidr) [[ $# -ge 2 && -z $bankc ]] || usage; bankc=$2; shift 2 ;;
    *) usage ;;
  esac
done
case $party in bi | bank-a | bank-b) ;; *) usage ;; esac
[[ -z $pvc || $party != bi ]] || { echo "render.sh: --keys-in-pvc is for bank-a and bank-b only (keys-in-pvc: the BI auditor keeps the Secret model)" >&2; exit 2; }
if [[ -n $gw ]]; then
  [[ -n $bankc ]] || { echo "render.sh: --gw-tls needs --bank-c-gw-cidr <public ipv4>/32 (the external address of bank-c's gateway-lb on cluster 2, passed at render time, never committed)" >&2; exit 2; }
  [[ $bankc =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/32$ ]] || { echo "render.sh: --bank-c-gw-cidr must be a single IPv4 /32: got '$bankc'" >&2; exit 2; }
  [[ $bankc =~ ^(10\.|127\.|192\.168\.|169\.254\.|172\.(1[6-9]|2[0-9]|3[01])\.|0\.) ]] && { echo "render.sh: --bank-c-gw-cidr must be a public address, not $bankc" >&2; exit 2; }
  flags+=("bankc:${bankc%/32}")
elif [[ -n $bankc ]]; then usage; fi
[[ $digest =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "render.sh: the image must be pinned by a digest (sha256:<64 lowercase hex>), not a tag: got '$digest'" >&2; exit 2; }
[[ -d $pub ]] || { echo "render.sh: public dir $pub not found" >&2; exit 2; }
for f in chain_id genesis.expected_hash peers.json accounts.json; do [[ -f $pub/$f ]] || { echo "render.sh: $pub/$f is missing" >&2; exit 2; }; done
[[ -z $(find "$pub" \( -name '*.seed' -o -name '*.note' -o -name '*.hybrid' -o -name private.key \) -print -quit) ]] \
  || { echo "render.sh: $pub holds private material (*.seed, *.note, *.hybrid or private.key); public files only" >&2; exit 2; }
if [[ -n $gw ]]; then
  for q in bi bank-a bank-b bank-c; do [[ -f $pub/gateway-ca/$q-server-ca.pem ]] || { echo "render.sh: $pub/gateway-ca/$q-server-ca.pem is missing (public server CA of $q)" >&2; exit 2; }; done
  grep -l 'PRIVATE KEY' "$pub"/gateway-ca/*.pem >/dev/null 2>&1 && { echo "render.sh: $pub/gateway-ca holds a private key" >&2; exit 2; }
fi
exec python3 -I "$here/render.py" "$party" "$digest" "$pub" "$here/../../network" "${flags[@]}"
