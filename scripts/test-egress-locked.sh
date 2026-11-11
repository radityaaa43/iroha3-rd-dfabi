#!/usr/bin/env bash
# Offline guard (ANALYST key-egress audit, R17): every render/template under deploy/ that defines a Job (one-off, may mount key Secrets) must name the
# label rd/egress-locked and an Egress NetworkPolicy. The per-render checker asserts the rendered values; this catches a NEW Job render that forgot
# both. Excluded on purpose: the old-namespace stack (deploy/runner, k8s, k8s-apps, jobs).
set -uo pipefail
cd "$(dirname "$0")/.."
fails=0
for f in $(grep -rlE '"kind": "Job"|^kind: Job' deploy | grep -vE '^deploy/(runner|k8s|k8s-apps|jobs)/' | sort); do
  if grep -q 'rd/egress-locked' "$f" && grep -q '"Egress"' "$f"; then echo "ok:   $f names rd/egress-locked and an Egress policy"
  else echo "FAIL: $f defines a Job without rd/egress-locked + an Egress NetworkPolicy" >&2; fails=$((fails + 1)); fi
done
n=$(grep -rlE '"kind": "Job"|^kind: Job' deploy | grep -vE '^deploy/(runner|k8s|k8s-apps|jobs)/' | wc -l)
(( n >= 1 )) && echo "ok:   $n Job-defining file(s) found" || { echo "FAIL: expected >= 1 Job-defining file (pool-init), found $n" >&2; fails=$((fails + 1)); }
if (( fails )); then echo "FAILED: $fails check(s)" >&2; exit 1; fi
echo "PASS"
