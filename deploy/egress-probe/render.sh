#!/usr/bin/env bash
# Print the (iv) egress PROBE (ANALYST key-egress audit, R17): a throwaway Pod `egress-probe` + its OWN narrow Egress NetworkPolicy `egress-probe-egress` in
# rd-iroha3-<party>. Writes nothing, calls no cluster, renders NO Secret.
#   deploy/egress-probe/render.sh <bi|bank-a|bank-b|bank-c> <sha256:<64 hex> driver image digest>
# The Pod has the labels of a locked pod (rd-iroha3/role=egress-probe, rd/egress-locked=true), NO Secret, NO SA token, the driver image by digest (ghcr-pull),
# and loops every 15 s printing one line of OPEN / REFUSED / TIMEOUT per target (read with `kubectl logs`, never exec): DNS of the own peer service and ghcr.io,
# the own peer's Torii :8080, the gateways :8443 (NXDOMAIN until S14), and the holes that must be closed: 1.1.1.1:443, 8.8.8.8:53, the apiserver
# (KUBERNETES_SERVICE_HOST:443) and the ghcr.io address. The policy allows ONLY cluster DNS, the own peer Torii and the gateways (same shape as driver-egress).
# Create the Pod first (baseline: everything OPEN), then the policy, then read the log: the holes turn to TIMEOUT. Delete the Pod after; keep or delete the policy per the GO.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
usage() { echo "usage: render.sh bi|bank-a|bank-b|bank-c <sha256:<64 hex> driver image digest>" >&2; exit 2; }
(( $# == 2 )) || usage
party=$1 digest=$2
case $party in bi | bank-a | bank-b | bank-c) ;; *) usage ;; esac
[[ $digest =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "render.sh: the image must be pinned by a digest (sha256:<64 lowercase hex>), not a tag: got '$digest'" >&2; exit 2; }
exec python3 -I "$here/render.py" "$party" "$digest"
