#!/usr/bin/env bash
# Offline test of deploy/peers/render.sh (no cluster, no kubectl; needs python3 + PyYAML). Exit != 0 on any failure.
set -uo pipefail
cd "$(dirname "$0")/.."
R=deploy/peers/render.sh
H=a1b2c3d4
CIDR=203.0.113.10/32
fails=0
fail() { echo "FAIL: $*" >&2; fails=$((fails + 1)); }
ok() { echo "ok:   $*"; }

refuse() { # <label> <expected message part> <args...>
  local label=$1 part=$2; shift 2
  local err rc
  err=$("$R" "$@" 2>&1 >/dev/null); rc=$?
  [[ $rc -eq 2 && $err == *"$part"* ]] && ok "refuses $label (exit 2)" || fail "$label not refused as expected (rc=$rc: $err)"
}
refuse "bank-c (cluster 2, S8)" "S8" bank-c $H $CIDR
refuse "no arguments" "usage"
refuse "unknown party" "usage" nobody $H $CIDR
refuse "bad genesis hash" "hash8" bi nothex $CIDR
refuse "bad cidr" "cidr" bi $H not-a-cidr
refuse "missing cidr" "usage" bi $H

for p in bi bank-a bank-b; do
  out=$("$R" "$p" $H $CIDR 2>&1) || { fail "$p: render failed: $out"; continue; }
  grep -q '@[A-Z_]*@' <<<"$out" && fail "$p: unreplaced placeholder in output"
  python3 -I scripts/check-peers.py "$p" $H $CIDR <<<"$out" || fails=$((fails + 1))
done
if (( fails )); then echo "FAILED: $fails check(s)" >&2; exit 1; fi
echo "PASS"
