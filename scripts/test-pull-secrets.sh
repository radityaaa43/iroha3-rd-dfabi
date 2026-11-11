#!/usr/bin/env bash
# Offline guard (ANALYST R15 term 3): every render/template under deploy/ that defines a pod spec must name the imagePullSecret ghcr-pull,
# so a package flipped to private cannot strand a pod on an uncached node. The per-render checkers assert the rendered value; this catches a NEW
# pod-bearing render that forgot it. Excluded on purpose: deploy/runner, deploy/k8s, deploy/k8s-apps, deploy/jobs (the old namespace iroha3 stack, being decommissioned; never applied to rd-iroha3-*).
set -uo pipefail
cd "$(dirname "$0")/.."
fails=0
for f in $(grep -rlE '"containers"|^ +containers:' deploy | grep -vE '^deploy/(runner|k8s|k8s-apps|jobs)/' | sort); do
  if grep -q 'ghcr-pull' "$f"; then echo "ok:   $f names ghcr-pull"; else echo "FAIL: $f defines a pod spec without ghcr-pull" >&2; fails=$((fails + 1)); fi
done
n=$(grep -rlE '"containers"|^ +containers:' deploy | grep -vE '^deploy/(runner|k8s|k8s-apps|jobs)/' | wc -l)
(( n >= 5 )) && echo "ok:   $n pod-bearing files found" || { echo "FAIL: expected >= 5 pod-bearing files (gateway, driver, auditor, pool-init, peers), found $n" >&2; fails=$((fails + 1)); }
if (( fails )); then echo "FAILED: $fails check(s)" >&2; exit 1; fi
echo "PASS"
