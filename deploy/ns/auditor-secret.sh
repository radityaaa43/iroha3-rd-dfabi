#!/usr/bin/env bash
# Create Secret `bi-auditor-key` (keys bi-auditor.seed, bi-auditor.hybrid) in rd-iroha3-bi from BI's own custody dir
# (iroha3 PLAN S4). The key files are made by the BI org: `rd-dfabi keys new <dir> bi-auditor` and `keys new-hybrid <dir> bi-auditor`.
#   deploy/ns/auditor-secret.sh <custody-dir>
# Refuses a missing dir/file, a group- or world-accessible file, and a custody dir inside a git checkout. Prints no value.
# KUBECTL (default kubectl) is the command to run; use the BI party kubeconfig (KUBECONFIG=...rd-iroha3-bi.kubeconfig).
set -euo pipefail
dir=${1:-}
[[ -n $dir ]] || { echo "usage: auditor-secret.sh <custody-dir>" >&2; exit 2; }
[[ -d $dir ]] || { echo "auditor-secret.sh: custody dir $dir not found" >&2; exit 2; }
for f in bi-auditor.seed bi-auditor.hybrid; do
  [[ -f $dir/$f ]] || { echo "auditor-secret.sh: $dir/$f is missing" >&2; exit 2; }
  [[ $(stat -c %a "$dir/$f") == 600 ]] || { echo "auditor-secret.sh: $dir/$f must have mode 600 (is $(stat -c %a "$dir/$f"))" >&2; exit 2; }
done
real=$(cd "$dir" && pwd -P)
d=$real
while [[ $d != / ]]; do
  [[ -e $d/.git ]] && { echo "auditor-secret.sh: custody dir is inside a git checkout ($d); keep keys outside any repository" >&2; exit 2; }
  d=$(dirname "$d")
done
KUBECTL=${KUBECTL:-kubectl}
"$KUBECTL" create secret generic bi-auditor-key -n rd-iroha3-bi \
  --from-file=bi-auditor.seed="$real/bi-auditor.seed" --from-file=bi-auditor.hybrid="$real/bi-auditor.hybrid" \
  --dry-run=client -o yaml | "$KUBECTL" apply -f - >/dev/null
echo "auditor-secret.sh: Secret bi-auditor-key applied in rd-iroha3-bi (values not printed)"
