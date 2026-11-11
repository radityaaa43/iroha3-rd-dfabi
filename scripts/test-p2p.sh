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
X1=203.0.113.10/32 X2=198.51.100.7/32
refuse "bank-c without --cluster 2" "cluster 2" --external-cidr $X1 bank-c
refuse "no argument" "usage"
refuse "unknown party" "usage" --external-cidr $X1 nobody
refuse "bi on cluster 2" "bank-c" --cluster 2 --external-cidr $X1 bi
refuse "cluster 3" "usage" --cluster 3 --external-cidr $X1 bank-c
refuse "a missing --external-cidr" "external-cidr" bi
refuse "a /24 range" "/32" --external-cidr 203.0.113.0/24 bi
refuse "0.0.0.0/0" "/32" --external-cidr 0.0.0.0/0 bi
refuse "a malformed cidr" "/32" --external-cidr not-a-cidr bi
for p in bi bank-a bank-b; do
  out=$("$R" --external-cidr $X1 --external-cidr $X2 "$p" 2>&1) || { fail "$p: render failed: $out"; continue; }
  python3 -I scripts/check-p2p.py "$p" $X1 $X2 <<<"$out" || fails=$((fails + 1))
done
out=$("$R" --cluster 2 --external-cidr $X1 bank-c 2>&1) || fail "bank-c: render failed: $out"
python3 -I scripts/check-p2p.py bank-c $X1 <<<"$out" || fails=$((fails + 1))
if (( fails )); then echo "FAILED: $fails check(s)" >&2; exit 1; fi
echo "PASS"
