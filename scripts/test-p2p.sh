#!/usr/bin/env bash
# Offline test of deploy/p2p/render.sh (no cluster; python3 + PyYAML). Exit != 0 on any failure.
set -uo pipefail
cd "$(dirname "$0")/.."
R=deploy/p2p/render.sh
fails=0
fail() { echo "FAIL: $*" >&2; fails=$((fails + 1)); }
ok() { echo "ok:   $*"; }
refuse() { # <label> <expected message part> <args...>
  local label=$1 part=$2; shift 2
  local err rc
  err=$("$R" "$@" 2>&1 >/dev/null); rc=$?
  [[ $rc -eq 2 && $err == *"$part"* ]] && ok "refuses $label (exit 2)" || fail "$label not refused as expected (rc=$rc: $err)"
}
refuse "bank-c without --cluster 2" "cluster 2" bank-c
refuse "no argument" "usage"
refuse "unknown party" "usage" nobody
refuse "bi on cluster 2" "bank-c" --cluster 2 bi
refuse "cluster 3" "usage" --cluster 3 bank-c
for p in bi bank-a bank-b; do
  out=$("$R" "$p" 2>&1) || { fail "$p: render failed: $out"; continue; }
  python3 -I scripts/check-p2p.py "$p" <<<"$out" || fails=$((fails + 1))
done
out=$("$R" --cluster 2 bank-c 2>&1) || fail "bank-c: render failed: $out"
python3 -I scripts/check-p2p.py bank-c <<<"$out" || fails=$((fails + 1))
if (( fails )); then echo "FAILED: $fails check(s)" >&2; exit 1; fi
echo "PASS"
