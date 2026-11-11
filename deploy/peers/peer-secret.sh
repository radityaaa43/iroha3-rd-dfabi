#!/usr/bin/env bash
# Create Secret `peer-<party>` (keys peer.toml, mint-finality.seed) in rd-iroha3-<party> from that org's OWN files (iroha3 PLAN S7).
#   deploy/peers/peer-secret.sh <bi|bank-a|bank-b|bank-c> <peer.toml> <mint-finality.seed>
# Refuses: unknown party, missing file, a file not mode 600, a seed that is not exactly 32 bytes, a file inside a git checkout,
# a peer.toml without the keys private_key, soranet_transport_private_key, identity_private_key (names only) or with a leftover @...@. Prints no value.
# KUBECTL (default kubectl) is the command to run; use THAT party's own kubeconfig (KUBECONFIG=...rd-iroha3-<party>.kubeconfig).
# Plain `create` only: the party-admin Role has no secrets `get`, so `apply`/`--dry-run` would be Forbidden. A re-run fails with
# AlreadyExists and changes nothing (safe). Rotation is a separate `replace` step, not done here.
set -euo pipefail
party=${1:-} toml=${2:-} seed=${3:-}
[[ $# -eq 3 ]] || { echo "usage: peer-secret.sh <bi|bank-a|bank-b|bank-c> <peer.toml> <mint-finality.seed>" >&2; exit 2; }
case $party in bi|bank-a|bank-b|bank-c) ;; *) echo "peer-secret.sh: unknown party $party (want bi, bank-a, bank-b or bank-c)" >&2; exit 2 ;; esac
for f in "$toml" "$seed"; do
  [[ -f $f ]] || { echo "peer-secret.sh: $f is missing" >&2; exit 2; }
  [[ $(stat -c %a "$f") == 600 ]] || { echo "peer-secret.sh: $f must have mode 600 (is $(stat -c %a "$f"))" >&2; exit 2; }
  d=$(cd "$(dirname "$f")" && pwd -P)
  while [[ $d != / ]]; do
    [[ -e $d/.git ]] && { echo "peer-secret.sh: $f is inside a git checkout ($d); keep keys outside any repository" >&2; exit 2; }
    d=$(dirname "$d")
  done
done
[[ $(stat -c %s "$seed") -eq 32 ]] || { echo "peer-secret.sh: $seed must be exactly 32 bytes" >&2; exit 2; }
for k in private_key soranet_transport_private_key identity_private_key; do
  grep -Eq "^[[:space:]]*$k[[:space:]]*=" "$toml" || { echo "peer-secret.sh: $toml lacks key $k" >&2; exit 2; }
done
grep -Eq '@[A-Za-z0-9_]+@' "$toml" && { echo "peer-secret.sh: $toml still has an @...@ placeholder" >&2; exit 2; }
KUBECTL=${KUBECTL:-kubectl}
"$KUBECTL" create secret generic "peer-$party" -n "rd-iroha3-$party" \
  --from-file=peer.toml="$toml" --from-file=mint-finality.seed="$seed" >/dev/null
echo "peer-secret.sh: Secret peer-$party created in rd-iroha3-$party (values not printed)"
