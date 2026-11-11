#!/usr/bin/env bash
# Create Secret `<name>-key` (keys <name>.seed, <name>.hybrid) in the org's OWN namespace rd-iroha3-<party> from the org's own custody dir
# (iroha3 PLAN S11/S12, ANALYST condition (a): the auditor key is generated and held only in its own org namespace, never on the Lensa
# host). <name> = bi-auditor (bi), bank-a-auditor (bank-a), bank-b-auditor (bank-b). The key files are made by the org:
# `rd-dfabi keys new <dir> <name>` and `rd-dfabi keys new-hybrid <dir> <name>`.
#   deploy/auditor/org-secret.sh <bi|bank-a|bank-b> <custody-dir>
# Refuses a missing dir/file, a group- or world-accessible file, and a custody dir inside a git checkout. Prints no value.
# KUBECTL (default kubectl) is the command to run, with the PARTY kubeconfig. Plain `create` only (the party-admin Role has no secrets
# `get`, so apply/--dry-run would be Forbidden); a re-run fails with AlreadyExists and changes nothing.
set -euo pipefail
party=${1:-} dir=${2:-}
case $party in bi) name=bi-auditor ;; bank-a | bank-b) name=$party-auditor ;; *) echo "usage: org-secret.sh bi|bank-a|bank-b <custody-dir>" >&2; exit 2 ;; esac
[[ -n $dir ]] || { echo "usage: org-secret.sh bi|bank-a|bank-b <custody-dir>" >&2; exit 2; }
[[ -d $dir ]] || { echo "org-secret.sh: custody dir $dir not found" >&2; exit 2; }
for f in "$name.seed" "$name.hybrid"; do
  [[ -f $dir/$f ]] || { echo "org-secret.sh: $dir/$f is missing" >&2; exit 2; }
  [[ $(stat -c %a "$dir/$f") == 600 ]] || { echo "org-secret.sh: $dir/$f must have mode 600 (is $(stat -c %a "$dir/$f"))" >&2; exit 2; }
done
real=$(cd "$dir" && pwd -P)
d=$real
while [[ $d != / ]]; do
  [[ -e $d/.git ]] && { echo "org-secret.sh: custody dir is inside a git checkout ($d); keep keys outside any repository" >&2; exit 2; }
  d=$(dirname "$d")
done
KUBECTL=${KUBECTL:-kubectl}
"$KUBECTL" create secret generic "$name-key" -n "rd-iroha3-$party" \
  --from-file="$name.seed"="$real/$name.seed" --from-file="$name.hybrid"="$real/$name.hybrid" >/dev/null
echo "org-secret.sh: Secret $name-key created in rd-iroha3-$party (values not printed)"
