#!/usr/bin/env bash
# Print the S17 per-bank driver server manifests of one party (iroha3 PLAN S17, ARCHITECTURE-iroha3 10a, docs/server-mode.md):
# ConfigMap driver-config (public values only), Deployment driver, Service driver, NetworkPolicy driver-ingress. Writes nothing,
# calls no cluster, renders NO Secret: the bank creates Secret `<party>-keys` (<party>.seed, <party>.note, client.toml) itself with its
# own kubeconfig. The image is pinned by digest; the pod pulls it with the imagePullSecret `ghcr-pull` of the namespace.
#   deploy/driver/render.sh <bi|bank-a|bank-b|bank-c> <sha256:digest> <public-dir> [--audit-tls] [--mint-enabled --mint-max-rd N --mint-max-dfabi N]
# --mint-enabled (BI only, K6/W0b): emits `mint_enabled = true` (top-level) and an [auditor] table with the per-request mint caps (+ the 4 trading accounts as `parties`; listen/store_dir are required
# by the config when the table is present and unused by the server mode), so POST /mint answers instead of 403. Caps have no default (K6 D2: equal to the S13 reserves).
# --audit-tls also renders NetworkPolicy driver-egress (R17: DNS, the own party's Torii 8080, the gateways on 8443: same-cluster ones by namespace
# selector, the gateways of the OTHER cluster only as explicit --remote-gw-cidr <ip>/32 (their external LB addresses; repeatable)).
# --audit-tls (iroha3 S13 transport A): adds `[audit] min_approvals = 2` with the three gateway URLs (bi, bank-a, bank-b) and `[tls]` to
# rd-dfabi.toml, the Secret volume iroha3-client-cert (tls.crt, tls.key 0400, /tls/client) and the ConfigMap gateway-server-cas (the 4 PUBLIC
# <party>-server-ca.pem from <public-dir>/gateway-ca/, /tls/cas). Without it the output is unchanged.
# --remote-gw <party>=<ipv4> (repeatable; bank-c ONLY, and --audit-tls on bank-c requires all three of bi, bank-a, bank-b): the cluster-1 auditors' gateways are not resolvable from
# cluster 2, so the config gets `[tls.resolve]` "gateway.rd-iroha3-<party>.svc.cluster.local" = "<ip>:8443" (node-build tls_http.rs:53-55; the gateway leaf SAN stays that name) and the SAME
# ip as a /32 ipBlock in driver-egress, so the two cannot drift. <ip> = the external gateway-lb address of that party, read at apply time, never committed.
# <public-dir> (network/public or ~/iroha3-new/public) holds chain_id, genesis.expected_hash (names ConfigMap genesis-<hash8>) and
# peers.json; it must hold no private material. bank-c (cluster 2) renders the same objects: no zone or node pin anywhere.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
usage() { echo "usage: render.sh bi|bank-a|bank-b|bank-c <sha256:<64 hex> image digest> <public-dir> [--audit-tls [--remote-gw-cidr <ipv4>/32]... [--remote-gw bi|bank-a|bank-b=<ipv4>]...] [--mint-enabled --mint-max-rd <n> --mint-max-dfabi <n>]" >&2; exit 2; }
(( $# >= 3 )) || usage
party=$1 digest=$2 pub=$3; shift 3
tls="" remote=() gw=() mint="" mrd="" mdf=""
positive() { [[ $1 =~ ^[1-9][0-9]{0,18}$ ]] && (( ${#1} < 19 || $1 <= 9223372036854775807 )) 2>/dev/null; }
while (( $# )); do
  case $1 in
    --audit-tls) [[ -z $tls ]] || usage; tls=$1; shift ;;
    --remote-gw-cidr)
      [[ -n $tls && $# -ge 2 ]] || usage
      [[ $2 =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/32$ ]] || { echo "render.sh: --remote-gw-cidr must be an IPv4 /32 (the external address of a gateway load balancer on the other cluster): got '$2'" >&2; exit 2; }
      remote+=("$2"); shift 2 ;;
    --remote-gw)
      [[ -n $tls && $# -ge 2 ]] || usage
      [[ $2 =~ ^(bi|bank-a|bank-b)=(.+)$ ]] || { echo "render.sh: --remote-gw must be <bi, bank-a or bank-b>=<ipv4>: got '$2'" >&2; exit 2; }
      gp=${BASH_REMATCH[1]} gi=${BASH_REMATCH[2]}
      [[ $gi =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || { echo "render.sh: --remote-gw $gp needs a plain ipv4 address (no mask, no name): got '$gi'" >&2; exit 2; }
      [[ $gi =~ ^(10\.|127\.|192\.168\.|169\.254\.|172\.(1[6-9]|2[0-9]|3[01])\.|0\.|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.) ]] && { echo "render.sh: --remote-gw $gp must be a public address (the external gateway-lb), not $gi" >&2; exit 2; }
      for g in ${gw[@]+"${gw[@]}"}; do [[ ${g%%=*} != "$gp" ]] || { echo "render.sh: --remote-gw $gp given twice" >&2; exit 2; }; done
      gw+=("$gp=$gi"); shift 2 ;;
    --mint-enabled) [[ -z $mint ]] || usage; mint=1; shift ;;
    --mint-max-rd) [[ $# -ge 2 ]] || usage; mrd=$2; shift 2 ;;
    --mint-max-dfabi) [[ $# -ge 2 ]] || usage; mdf=$2; shift 2 ;;
    *) usage ;;
  esac
done
if (( ${#gw[@]} )); then
  [[ $party == bank-c ]] || { echo "render.sh: --remote-gw is for the bank-c driver only (cluster 1 resolves the gateways by name); got $party" >&2; exit 2; }
fi
if [[ -n $tls && $party == bank-c ]]; then
  for q in bi bank-a bank-b; do
    [[ " ${gw[*]-} " == *" $q="* ]] || { echo "render.sh: bank-c --audit-tls needs --remote-gw $q=<ipv4> (cluster 2 cannot resolve the cluster-1 gateway names); missing: $q" >&2; exit 2; }
  done
fi
if [[ -n $mint ]]; then
  [[ $party == bi ]] || { echo "render.sh: --mint-enabled is for the BI driver only (party bi), got $party" >&2; exit 2; }
  [[ -n $mrd && -n $mdf ]] || { echo "render.sh: --mint-enabled needs --mint-max-rd and --mint-max-dfabi (the per-request caps; no default)" >&2; exit 2; }
  positive "$mrd" && positive "$mdf" || { echo "render.sh: --mint-max-rd / --mint-max-dfabi must be positive integers below 2^63" >&2; exit 2; }
elif [[ -n $mrd || -n $mdf ]]; then usage; fi
case $party in bi | bank-a | bank-b | bank-c) ;; *) usage ;; esac
[[ $digest =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "render.sh: the image must be pinned by a digest (sha256:<64 lowercase hex>), not a tag: got '$digest'" >&2; exit 2; }
[[ -d $pub ]] || { echo "render.sh: public dir $pub not found" >&2; exit 2; }
for f in chain_id genesis.expected_hash peers.json $([[ -n $mint ]] && echo accounts.json); do [[ -f $pub/$f ]] || { echo "render.sh: $pub/$f is missing" >&2; exit 2; }; done
[[ -z $(find "$pub" \( -name '*.seed' -o -name '*.note' -o -name '*.hybrid' -o -name private.key \) -print -quit) ]] \
  || { echo "render.sh: $pub holds private material (*.seed, *.note, *.hybrid or private.key); public files only" >&2; exit 2; }
if [[ -n $tls ]]; then
  for q in bi bank-a bank-b bank-c; do [[ -f $pub/gateway-ca/$q-server-ca.pem ]] || { echo "render.sh: $pub/gateway-ca/$q-server-ca.pem is missing (public server CA of $q)" >&2; exit 2; }; done
  grep -l 'PRIVATE KEY' "$pub"/gateway-ca/*.pem >/dev/null 2>&1 && { echo "render.sh: $pub/gateway-ca holds a private key" >&2; exit 2; }
fi
exec python3 -I "$here/render.py" "$party" "$digest" "$pub" "$here/../../network" "$tls" "${mint:+$mrd:$mdf}" ${remote[@]+"${remote[@]}"} ${gw[@]+"${gw[@]}"}
