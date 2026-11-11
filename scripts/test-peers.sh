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
refuse "bank-c without --cluster 2" "S8" bank-c $H $CIDR
refuse "--cluster 2 with a cluster-1 party" "bank-c" --cluster 2 bi $H $CIDR
refuse "--cluster 3" "usage" --cluster 3 bank-c $H $CIDR
refuse "no arguments" "usage"
refuse "unknown party" "usage" nobody $H $CIDR
refuse "bad genesis hash" "hash8" bi nothex $CIDR
refuse "bad cidr" "cidr" bi $H not-a-cidr
refuse "a /24 bank-c range" "/32" bi $H 203.0.113.0/24
refuse "0.0.0.0/0" "/32" bi $H 0.0.0.0/0
refuse "missing cidr" "usage" bi $H
refuse "a clb health range other than 100.64.0.0/10" "100.64.0.0/10" --clb-health-cidr 10.0.0.0/8 bi $H $CIDR
refuse "an open clb health range" "100.64.0.0/10" --clb-health-cidr 0.0.0.0/0 bi $H $CIDR

for p in bi bank-a bank-b; do
  out=$("$R" "$p" $H $CIDR 2>&1) || { fail "$p: render failed: $out"; continue; }
  grep -q '@[A-Z_]*@' <<<"$out" && fail "$p: unreplaced placeholder in output"
  python3 -I scripts/check-peers.py "$p" $H $CIDR <<<"$out" || fails=$((fails + 1))
  python3 -I scripts/check-netpol-form.py "peers" <<<"$out" || fails=$((fails + 1))
done
for p in bi bank-a bank-b; do # the CLB health-check source is opt-in; Alibaba CLB probes and forwards from 100.64.0.0/10
  out=$("$R" --clb-health-cidr 100.64.0.0/10 "$p" $H $CIDR 2>&1) || { fail "$p: render with --clb-health-cidr failed: $out"; continue; }
  python3 -I scripts/check-peers.py "$p" $H $CIDR clb <<<"$out" || fails=$((fails + 1))
  python3 -I scripts/check-netpol-form.py "peers" <<<"$out" || fails=$((fails + 1))
  [[ $("$R" "$p" $H $CIDR | grep -c '100\.64\.') -eq 0 ]] && ok "$p: default render has no 100.64 element" || fail "$p: default render carries 100.64"
done
# S8: bank-c on cluster 2 (default and with the CLB element)
out=$("$R" --cluster 2 bank-c $H $CIDR 2>&1) || fail "bank-c --cluster 2: render failed: $out"
python3 -I scripts/check-peers.py bank-c $H $CIDR c2 <<<"$out" || fails=$((fails + 1))
python3 -I scripts/check-netpol-form.py "peers" <<<"$out" || fails=$((fails + 1))
grep -q 'alicloud' <<<"$out" && fail "bank-c --cluster 2 still names a cluster-1 StorageClass (alicloud-*)"
out=$("$R" --clb-health-cidr 100.64.0.0/10 --cluster 2 bank-c $H $CIDR 2>&1) || fail "bank-c --cluster 2 --clb-health-cidr: render failed: $out"
python3 -I scripts/check-peers.py bank-c $H $CIDR clb c2 <<<"$out" || fails=$((fails + 1))
python3 -I scripts/check-netpol-form.py "peers" <<<"$out" || fails=$((fails + 1))
if (( fails )); then echo "FAILED: $fails check(s)" >&2; exit 1; fi
echo "PASS"
