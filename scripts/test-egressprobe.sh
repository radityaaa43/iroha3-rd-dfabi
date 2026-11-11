#!/usr/bin/env bash
# Offline test of deploy/egress-probe/render.sh (no cluster; python3 + PyYAML). Exit != 0 on any failure.
set -uo pipefail
cd "$(dirname "$0")/.."
R=deploy/egress-probe/render.sh
fails=0
fail() { echo "FAIL: $*" >&2; fails=$((fails + 1)); }
ok() { echo "ok:   $*"; }
D=sha256:$(printf 'a%.0s' $(seq 1 64))
refuse() { local label=$1 part=$2; shift 2; local err rc; err=$("$R" "$@" 2>&1 >/dev/null); rc=$?; [[ $rc -eq 2 && $err == *"$part"* ]] && ok "refuses $label (exit 2)" || fail "$label not refused (rc=$rc): $err"; }
refuse "no arguments" "usage"
refuse "an unknown party" "usage" bank-z "$D"
refuse "a tag instead of a digest" "digest" bi "debian:latest"
for p in bi bank-a bank-b bank-c; do
  out=$("$R" "$p" "$D" 2>&1) || { fail "$p: render failed: $out"; continue; }
  python3 -I scripts/check-egressprobe.py "$p" "$D" <<<"$out" || fails=$((fails + 1))
  python3 -I scripts/check-netpol-form.py "egressprobe" <<<"$out" || fails=$((fails + 1))
done
a=$("$R" bi "$D"); b=$("$R" bi "$D")
[[ -n $a && $a == "$b" ]] && ok "render is deterministic" || fail "render differs between runs or is empty"
if (( fails )); then echo "FAILED: $fails check(s)" >&2; exit 1; fi
echo "PASS"
