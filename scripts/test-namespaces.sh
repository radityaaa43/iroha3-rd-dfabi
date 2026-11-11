#!/usr/bin/env bash
# Offline test of deploy/ns/render.sh (no cluster, no kubectl; needs python3 + PyYAML). Exit != 0 on any failure.
set -uo pipefail
cd "$(dirname "$0")/.."
R=deploy/ns/render.sh
fails=0
fail() { echo "FAIL: $*" >&2; fails=$((fails + 1)); }
ok() { echo "ok:   $*"; }

# A refusal must be the script's own (exit 2 and a message naming the reason), not a missing file.
err=$("$R" bank-c 2>&1 >/dev/null); rc=$?
[[ $rc -eq 2 && $err == *"cluster 2"* ]] && ok "render.sh refuses bank-c (exit 2, names cluster 2)" || fail "bank-c not refused as expected (rc=$rc: $err)"
"$R" >/dev/null 2>&1; rc=$?
[[ $rc -eq 2 ]] && ok "render.sh refuses a missing party (exit 2)" || fail "missing party: rc=$rc, want 2"
"$R" nobody >/dev/null 2>&1; rc=$?
[[ $rc -eq 2 ]] && ok "render.sh refuses an unknown party (exit 2)" || fail "unknown party: rc=$rc, want 2"

for p in bi bank-a bank-b; do
  out=$("$R" "$p" 2>&1) || { fail "$p: render failed: $out"; continue; }
  grep -q '@' <<<"$out" && fail "$p: unreplaced placeholder in output"
  python3 -I scripts/check-ns.py "$p" <<<"$out" || fails=$((fails + 1))
done
pc=$("$R" priorityclass 2>&1) || fail "priorityclass render failed: $pc"
python3 -I scripts/check-ns.py priorityclass <<<"$pc" || fails=$((fails + 1))

if (( fails )); then echo "FAILED: $fails check(s)" >&2; exit 1; fi
echo "PASS"
