#!/usr/bin/env bash
# Offline test of deploy/pool-init/render.sh (no cluster; python3 + PyYAML). Exit != 0 on any failure.
set -uo pipefail
cd "$(dirname "$0")/.."
R=deploy/pool-init/render.sh
fails=0
fail() { echo "FAIL: $*" >&2; fails=$((fails + 1)); }
ok() { echo "ok:   $*"; }
T=$(mktemp -d); trap 'rm -r -- "$T"' EXIT
D=sha256:$(printf 'a%.0s' $(seq 1 64))
H64=$(printf '0123456789abcdef%.0s' 1 2 3 4); H8=${H64:0:8}
P="$T/public"; mkdir "$P"
CHAIN=11111111-2222-4333-8444-555555555555
echo "$CHAIN" > "$P/chain_id"
printf 'hash:%s#ABCD\n' "${H64^^}" > "$P/genesis.expected_hash"
jq -n '[ "bi","bank-a","bank-b","bank-c" | {party: ., public_key: ("ea0130" + .), pop_hex: "0xaa"} ]' > "$P/peers.json"
refuse() { local label=$1 part=$2; shift 2; local err rc; err=$("$R" "$@" 2>&1 >/dev/null); rc=$?; [[ $rc -eq 2 && $err == *"$part"* ]] && ok "refuses $label (exit 2)" || fail "$label not refused as expected (rc=$rc: $err)"; }
refuse "no arguments" "usage"
refuse "a tag instead of a digest" "digest" "debian:latest" "$P" 1000 100
refuse "a missing public dir" "public dir" "$D" "$T/none" 1000 100
refuse "a zero reserve" "reserve" "$D" "$P" 0 100
refuse "a non-numeric reserve" "reserve" "$D" "$P" 10x 100
refuse "a reserve above u64" "reserve" "$D" "$P" 99999999999999999999999 100
mkdir "$T/p3"; cp "$P"/* "$T/p3/"; : > "$T/p3/x.seed"; refuse "a public dir holding a seed" "private material" "$D" "$T/p3" 1000 100
out=$("$R" "$D" "$P" 1000 100 2>&1) || fail "render failed: $out"
python3 -I scripts/check-poolinit.py "$D" "$H8" "$CHAIN" 1000 100 <<<"$out" || fails=$((fails + 1))
a=$("$R" "$D" "$P" 1000 100); b=$("$R" "$D" "$P" 1000 100)
[[ -n $a && $a == "$b" ]] && ok "render is deterministic" || fail "render differs between runs or is empty"
before=$(find "$T" -type f | sort | xargs cksum)
"$R" "$D" "$P" 1000 100 >/dev/null; [[ $(find "$T" -type f | sort | xargs cksum) == "$before" ]] && ok "writes nothing" || fail "files changed"
if (( fails )); then echo "FAILED: $fails check(s)" >&2; exit 1; fi
echo "PASS"
