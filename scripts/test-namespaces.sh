#!/usr/bin/env bash
# Offline test of deploy/ns/render.sh (no cluster, no kubectl; needs python3 + PyYAML). Exit != 0 on any failure.
set -uo pipefail
cd "$(dirname "$0")/.."
R=deploy/ns/render.sh
fails=0
fail() { echo "FAIL: $*" >&2; fails=$((fails + 1)); }
ok() { echo "ok:   $*"; }

# A refusal must be the script's own (exit 2 and a message naming the reason), not a missing file.
refuse() { # <label> <expected message part> <args...>
  local label=$1 part=$2; shift 2
  local err rc
  err=$("$R" "$@" 2>&1 >/dev/null); rc=$?
  [[ $rc -eq 2 && $err == *"$part"* ]] && ok "refuses $label (exit 2)" || fail "$label not refused as expected (rc=$rc: $err)"
}
refuse "bank-c without --cluster 2" "cluster 2" bank-c
refuse "no party" "usage"
refuse "unknown party" "usage" nobody
refuse "bi on cluster 2" "bank-c" --cluster 2 bi
refuse "bank-a on cluster 2" "bank-c" --cluster 2 bank-a
refuse "priorityclass on cluster 2" "PriorityClass" --cluster 2 priorityclass
refuse "bank-c on cluster 1 flag" "cluster 2" --cluster 1 bank-c
refuse "cluster 3" "usage" --cluster 3 bank-c

for p in bi bank-a bank-b; do
  out=$("$R" "$p" 2>&1) || { fail "$p: render failed: $out"; continue; }
  grep -q '@' <<<"$out" && fail "$p: unreplaced placeholder in output"
  python3 -I scripts/check-ns.py "$p" <<<"$out" || fails=$((fails + 1))
done
out=$("$R" --cluster 2 bank-c 2>&1) || fail "bank-c: render failed: $out"
grep -q '@' <<<"$out" && fail "bank-c: unreplaced placeholder in output"
grep -q 'PriorityClass' <<<"$out" && fail "bank-c: output contains a PriorityClass (none on cluster 2)"
python3 -I scripts/check-ns.py bank-c <<<"$out" || fails=$((fails + 1))
out=$("$R" --cluster 2 --ns-only bank-c 2>&1) || fail "bank-c: --ns-only render failed: $out"
python3 -I scripts/check-ns.py bank-c ns-only <<<"$out" || fails=$((fails + 1))
out=$("$R" --ns-only bi 2>&1) || fail "bi: --ns-only render failed: $out"
python3 -I scripts/check-ns.py bi ns-only <<<"$out" || fails=$((fails + 1))
refuse "--ns-only priorityclass" "PriorityClass" --ns-only priorityclass
pc=$("$R" priorityclass 2>&1) || fail "priorityclass render failed: $pc"
python3 -I scripts/check-ns.py priorityclass <<<"$pc" || fails=$((fails + 1))

if (( fails )); then echo "FAILED: $fails check(s)" >&2; exit 1; fi
echo "PASS"
