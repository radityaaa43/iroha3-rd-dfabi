#!/usr/bin/env bash
# Offline guard (lead rule 2026-11-12): no workload manifest/render under deploy/ references a ghcr.io/radityaaa43 image BY TAG; pods pin by digest
# (repo@sha256:...). A tag can be overwritten by a later push and then changes what a rescheduled pod pulls. Excluded on purpose: deploy/runner,
# deploy/k8s-apps, deploy/jobs (old namespace iroha3 stack, being decommissioned). Dev/tooling scripts that `docker run` an image locally are out of scope.
set -uo pipefail
cd "$(dirname "$0")/.."
fails=0
files=$(grep -rlE 'ghcr\.io/radityaaa43/' deploy | grep -vE '^deploy/(runner|k8s-apps|jobs)/' | sort)
for f in $files; do
  bad=$(grep -nE 'ghcr\.io/radityaaa43/[A-Za-z0-9._-]+:[A-Za-z0-9._-]+' "$f" | grep -v '@sha256' || true)
  if [[ -z $bad ]]; then echo "ok:   $f has no tag-only ghcr.io/radityaaa43 image"; else echo "FAIL: $f references an image by tag: $bad" >&2; fails=$((fails + 1)); fi
done
n=$(wc -w <<<"$files"); (( n >= 4 )) && echo "ok:   $n files with ghcr.io/radityaaa43 images scanned" || { echo "FAIL: expected >= 4 files, found $n" >&2; fails=$((fails + 1)); }
if (( fails )); then echo "FAILED: $fails check(s)" >&2; exit 1; fi
echo "PASS"
