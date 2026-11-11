#!/usr/bin/env bash
# Print the S13 pool-activation Job (iroha3 PLAN S13; ANALYST 2-of-3 BI + orgs A and B; lead transport A). Writes nothing, calls no cluster,
# renders NO Secret. Namespace rd-iroha3-bi ONLY.
#   deploy/pool-init/render.sh <sha256:digest> <public-dir> <rd-reserve> <dfabi-reserve>
# The Job derives the bi-gov client.toml from Secret `bi-gov-key` (key bi-gov.seed, the governance account of genesis S3,
# CanEnactGovernance) into an emptyDir, removes the seed copy, then runs `rd-dfabi pool-init` ONCE: pools for RD and DFABI are born with
# `[audit] min_approvals = 2` over the three gateways (bi, bank-a, bank-b; mutual TLS from Secret iroha3-client-cert, pinned server CAs
# from the EXISTING ConfigMap gateway-server-cas of `driver/render.sh --audit-tls`). bi.note (only that key of Secret bi-keys) is the BI
# note secret the pool funding needs; the BI seed and the auditor keys are never mounted. backoffLimit 0: a failed run is NOT retried.
# PVC pools-index (1Gi) holds pools.json (public data, single writer = BI; S15 reuses it). Reserves are explicit amounts, no default.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
usage() { echo "usage: render.sh <sha256:<64 hex> image digest> <public-dir> <rd-reserve> <dfabi-reserve>" >&2; exit 2; }
(( $# == 4 )) || usage
digest=$1 pub=$2 rd=$3 dfabi=$4
[[ $digest =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "render.sh: the image must be pinned by a digest (sha256:<64 lowercase hex>), not a tag: got '$digest'" >&2; exit 2; }
[[ -d $pub ]] || { echo "render.sh: public dir $pub not found" >&2; exit 2; }
for v in "$rd" "$dfabi"; do
  [[ $v =~ ^[1-9][0-9]{0,18}$ ]] && (( ${#v} < 19 || v <= 9223372036854775807 )) || { echo "render.sh: reserve '$v' must be a positive integer below 2^63" >&2; exit 2; }
done
for f in chain_id genesis.expected_hash peers.json; do [[ -f $pub/$f ]] || { echo "render.sh: $pub/$f is missing" >&2; exit 2; }; done
[[ -z $(find "$pub" \( -name '*.seed' -o -name '*.note' -o -name '*.hybrid' -o -name private.key \) -print -quit) ]] \
  || { echo "render.sh: $pub holds private material (*.seed, *.note, *.hybrid or private.key); public files only" >&2; exit 2; }
exec python3 -I "$here/render.py" "$digest" "$pub" "$here/../../network" "$rd" "$dfabi"
