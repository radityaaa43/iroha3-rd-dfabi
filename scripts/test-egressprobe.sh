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
# The in-pod status parser (between the PARSE markers of the rendered loop) on REAL-format fixtures (scripts/fixtures/torii-status: derived from the pinned source,
# see the header of the fixtures' generator in the PR) and on a binary body: counts must come out of the pretty JSON (": " after every key, multi-line), nothing out of
# Norito bytes, and ctype/http/bytes are always shown, never the body.
"$R" bi "$D" | python3 -I -c '
import sys, json
docs = [json.loads(x) for x in sys.stdin.read().split("\n---\n")]
s = [d for d in docs if d["kind"] == "Pod"][0]["spec"]["containers"][0]["command"][2]
a, b = s.index("# PARSE-BEGIN"), s.index("# PARSE-END")
open(sys.argv[1], "w").write(s[a:b])
assert "Accept: application/json" in s, "the probe must request JSON explicitly (default is Norito binary)"
' "$T/parse.sh" && ok "the rendered loop has PARSE markers and requests Accept: application/json" || fail "no PARSE markers / no Accept: application/json in the loop"
chk() { # <fixture> <expected output>
  local got; got=$(bash -c 'source "$1"; parse "$2"' _ "$T/parse.sh" "scripts/fixtures/torii-status/$1" 2>&1)
  [[ $got == "$2" ]] && ok "parse $1 -> $2" || fail "parse $1: got '$got', want '$2'"
}
body_len() { python3 -I -c 'import sys; d=open(sys.argv[1],"rb").read(); print(len(d)-d.index(b"\r\n\r\n")-4)' "scripts/fixtures/torii-status/$1"; }
chk status-json-pretty.http "http=200 ctype=application/json bytes=$(body_len status-json-pretty.http) counts=[peers:3 blocks:1 view_changes:0 ]"
chk status-json-compact.http "http=200 ctype=application/json bytes=$(body_len status-json-compact.http) counts=[peers:3 blocks:1 view_changes:0 ]"
chk status-norito-binary.http "http=200 ctype=application/x-norito bytes=$(body_len status-norito-binary.http) counts=[]"
chk status-401.http "http=401 ctype=application/json bytes=$(body_len status-401.http) counts=[]"
a=$("$R" bi "$D"); b=$("$R" bi "$D")
[[ -n $a && $a == "$b" ]] && ok "render is deterministic" || fail "render differs between runs or is empty"
if (( fails )); then echo "FAILED: $fails check(s)" >&2; exit 1; fi
echo "PASS"
