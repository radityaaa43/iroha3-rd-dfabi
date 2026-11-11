#!/usr/bin/env bash
# Create Secret `<party>-keys` (keys <party>.seed, <party>.note, client.toml) in rd-iroha3-<party> from THAT bank's own custody dir
# (iroha3 PLAN S17, docs/server-mode.md condition 2 + precision). The files are the bank's own: `rd-dfabi keys new/new-note` made the seed
# and note, `rd-dfabi keys client-toml` derived client.toml from the seed.
#   deploy/driver/keys-secret.sh <bi|bank-a|bank-b|bank-c> <custody-dir>
# Refuses: unknown party, missing dir/file, a file not mode 600, a seed not 64 hex chars, a note not 128 hex chars, a client.toml without
# a private_key or with an @...@ placeholder, a custody dir inside a git checkout. Prints no value.
# KUBECTL (default kubectl) is the command to run; use THAT party's own kubeconfig. Plain `create` only: the party-admin Role has no
# secrets `get`, so `apply`/`--dry-run` would be Forbidden; a re-run fails with AlreadyExists and changes nothing.
set -euo pipefail
party=${1:-} dir=${2:-}
usage() { echo "usage: keys-secret.sh <bi|bank-a|bank-b|bank-c> <custody-dir>" >&2; exit 2; }
[[ $# -eq 2 ]] || usage
case $party in bi | bank-a | bank-b | bank-c) ;; *) echo "keys-secret.sh: unknown party $party (want bi, bank-a, bank-b or bank-c)" >&2; exit 2 ;; esac
[[ -d $dir ]] || { echo "keys-secret.sh: custody dir $dir not found" >&2; exit 2; }
for f in "$party.seed" "$party.note" client.toml; do
  [[ -f $dir/$f ]] || { echo "keys-secret.sh: $dir/$f is missing" >&2; exit 2; }
  [[ $(stat -c %a "$dir/$f") == 600 ]] || { echo "keys-secret.sh: $dir/$f must have mode 600 (is $(stat -c %a "$dir/$f"))" >&2; exit 2; }
done
d=$(cd "$dir" && pwd -P)
while [[ $d != / ]]; do
  [[ -e $d/.git ]] && { echo "keys-secret.sh: custody dir is inside a git checkout ($d); keep keys outside any repository" >&2; exit 2; }
  d=$(dirname "$d")
done
[[ $(tr -d '\n' < "$dir/$party.seed") =~ ^[0-9a-fA-F]{64}$ ]] || { echo "keys-secret.sh: $party.seed must be 64 hex chars (32 bytes)" >&2; exit 2; }
[[ $(tr -d '\n' < "$dir/$party.note") =~ ^[0-9a-fA-F]{128}$ ]] || { echo "keys-secret.sh: $party.note must be 128 hex chars (spend + view keys)" >&2; exit 2; }
grep -Eq '^[[:space:]]*private_key[[:space:]]*=' "$dir/client.toml" || { echo "keys-secret.sh: $dir/client.toml lacks key private_key" >&2; exit 2; }
grep -Eq '@[A-Za-z0-9_]+@' "$dir/client.toml" && { echo "keys-secret.sh: $dir/client.toml still has an @...@ placeholder" >&2; exit 2; }
KUBECTL=${KUBECTL:-kubectl}
"$KUBECTL" create secret generic "$party-keys" -n "rd-iroha3-$party" \
  --from-file="$party.seed=$dir/$party.seed" --from-file="$party.note=$dir/$party.note" --from-file=client.toml="$dir/client.toml" >/dev/null
echo "keys-secret.sh: Secret $party-keys created in rd-iroha3-$party (values not printed)"
