#!/usr/bin/env bash
# Print the (iv) egress PROBE (ANALYST key-egress audit, R17): a throwaway Pod `egress-probe` + its OWN narrow Egress NetworkPolicy `egress-probe-egress` in
# rd-iroha3-<party>. Writes nothing, calls no cluster, renders NO Secret.
#   deploy/egress-probe/render.sh <bi|bank-a|bank-b|bank-c> <sha256:<64 hex> driver image digest> [--role driver]
# --role driver renders ONLY the positive-control Pod `egress-probe-driver` (label rd-iroha3/role=driver, NO rd/egress-locked label, no policy, no Secret): the pod that
# must KEEP reaching the own Torii after torii-bootstrap is deleted (S14.G) and whose log carries the 4/4 counts; the default Pod (role=egress-probe) must lose it.
# The Pod has the labels of a locked pod (rd-iroha3/role=egress-probe, rd/egress-locked=true), NO Secret, NO SA token, the driver image by digest (ghcr-pull),
# and loops every 15 s printing one line of OPEN / REFUSED / TIMEOUT per target (read with `kubectl logs`, never exec): DNS of the own peer service and ghcr.io,
# the own peer's Torii :8080, the gateways :8443 (NXDOMAIN until S14), and the holes that must be closed: 1.1.1.1:443, 8.8.8.8:53, the apiserver
# (KUBERNETES_SERVICE_HOST:443) and the ghcr.io address. The policy allows ONLY cluster DNS, the own peer Torii and the gateways (same shape as driver-egress).
# --role driver: ONLY a Pod labelled role=driver (positive control of driver-egress / the torii-bootstrap deletion).
# --role driver-min: like --role driver but labelled ONLY rd-iroha3/role=driver (no part-of/party): admitted by peers-torii and selected by driver-egress, yet it matches NO Service/Deployment selector
# (the full --role driver probe also lands in Service `driver` endpoints: do not use it once gateways exist). Use driver-min as the P-pos of the torii-bootstrap deletion (S14.G).
# --role gateway: ONLY a Pod labelled rd-iroha3/role=gateway + app.kubernetes.io/name=gateway (no part-of/party: no Service/Deployment selector matches it), selected by the REAL gateway-egress and admitted
# by besu's bundle-server netpol: positive own peer :8080, own driver :8091, bundle-server Service :80; negative internet/apiserver/ghcr (+ foreign peer, also ingress-denied). Deadline 1800 s.
# --role lb --lb-target <public ip>/32 ...: Pod lb-probe (label role=lb-probe only) + NetworkPolicy lb-probe-egress: egress ONLY the target LB /32(s) on TCP 8443 (no DNS, no SA token, no Secret, deadline 1800 s):
# the LB/ACL functional proof (TCP connect from the admitted source = OPEN; never TLS).
# --role peer --remote-p2p <ip>/32 ...: ONLY a Pod labelled rd-iroha3/role=peer and NOTHING else (no part-of/party: no StatefulSet, Service or PDB selector matches it), selected by peers-egress; it opens NEW TCP
# connections to the same-cluster peers (1337, 8080) and to each remote LB /32 (1337) = positive control, and tries the internet/apiserver/ghcr/foreign driver = negative control.
# Create the Pod first (baseline: everything OPEN), then the policy, then read the log: the holes turn to TIMEOUT. Delete the Pod after; keep or delete the policy per the GO.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
usage() { echo "usage: render.sh bi|bank-a|bank-b|bank-c <sha256:<64 hex> driver image digest> [--role driver | --role driver-min | --role gateway | --role peer --remote-p2p <public ipv4>/32 ... | --role lb --lb-target <public ipv4>/32 ...]" >&2; exit 2; }
(( $# >= 2 )) || usage
party=$1 digest=$2; shift 2
role="" remotes=() kind=""
while (( $# )); do
  case $1 in
    --role) [[ ${2:-} == driver || ${2:-} == driver-min || ${2:-} == peer || ${2:-} == gateway || ${2:-} == lb ]] || usage; role=$2; shift 2 ;;
    --remote-p2p | --lb-target)
      [[ ${2:-} =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/32$ ]] || { echo "render.sh: $1 must be a single IPv4 /32 (got '${2:-}')" >&2; exit 2; }
      [[ $2 =~ ^(10\.|127\.|192\.168\.|169\.254\.|172\.(1[6-9]|2[0-9]|3[01])\.|0\.) ]] && { echo "render.sh: $1 must be a public address, not $2" >&2; exit 2; }
      k=${1#--}; [[ -z $kind || $kind == "$k" ]] || usage; kind=$k
      remotes+=("${2%/32}"); shift 2 ;;
    *) usage ;;
  esac
done
case $party in bi | bank-a | bank-b | bank-c) ;; *) usage ;; esac
[[ $digest =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "render.sh: the image must be pinned by a digest (sha256:<64 lowercase hex>), not a tag: got '$digest'" >&2; exit 2; }
# targets belong to exactly one role: --remote-p2p <-> peer, --lb-target <-> lb; peer and lb REQUIRE at least one; no other role takes any
case $role in
  peer) [[ $kind == remote-p2p ]] || usage ;;
  lb) [[ $kind == lb-target ]] || usage ;;
  *) [[ -z $kind ]] || usage ;;
esac
exec python3 -I "$here/render.py" "$party" "$digest" "${role:-default}" "${remotes[@]}"
