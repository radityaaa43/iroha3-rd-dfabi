#!/usr/bin/env bash
# Offline test of deploy/auditor/render.sh (no cluster; python3 + PyYAML). Exit != 0 on any failure.
set -uo pipefail
cd "$(dirname "$0")/.."
R=deploy/auditor/render.sh
fails=0
fail() { echo "FAIL: $*" >&2; fails=$((fails + 1)); }
ok() { echo "ok:   $*"; }
T=$(mktemp -d); trap 'rm -r -- "$T"' EXIT
D=sha256:$(printf 'a%.0s' $(seq 1 64))
H64=$(printf '0123456789abcdef%.0s' 1 2 3 4)
P="$T/public"; mkdir "$P"
CHAIN=11111111-2222-4333-8444-555555555555
echo "$CHAIN" > "$P/chain_id"
printf 'hash:%s#ABCD\n' "${H64^^}" > "$P/genesis.expected_hash"
jq -n '[ "bi","bank-a","bank-b","bank-c" | {party: ., public_key: ("ea0130" + .), pop_hex: "0xaa"} ]' > "$P/peers.json"
jq -n '{bi:"ed0120aa","bank-a":"ed0120bb","bank-b":"ed0120cc","bank-c":"ed0120dd","bi-gov":"ed0120ee"}' > "$P/accounts.json"
H8=${H64:0:8}

refuse() { # <label> <expected message part> <args...>
  local label=$1 part=$2; shift 2
  local err rc
  err=$("$R" "$@" 2>&1 >/dev/null); rc=$?
  [[ $rc -eq 2 && $err == *"$part"* ]] && ok "refuses $label (exit 2)" || fail "$label not refused as expected (rc=$rc: $err)"
}
refuse "no arguments" "usage"
refuse "an unknown party" "usage" nobody "$D" "$P"
refuse "bank-c (no auditor in this step)" "usage" bank-c "$D" "$P"
refuse "a tag instead of a digest" "digest" bi "debian:latest" "$P"
refuse "a short digest" "digest" bi "sha256:abc" "$P"
refuse "a missing public dir" "public dir" bi "$D" "$T/none"
mkdir "$T/p2"; cp "$P/chain_id" "$P/peers.json" "$T/p2/"; refuse "a public dir without genesis.expected_hash" "genesis.expected_hash" bi "$D" "$T/p2"
mkdir "$T/p3"; cp "$P"/* "$T/p3/"; : > "$T/p3/x.seed"; refuse "a public dir holding a seed" "private material" bi "$D" "$T/p3"

for p in bi bank-a bank-b; do
  out=$("$R" "$p" "$D" "$P" 2>&1) || { fail "$p: render failed: $out"; continue; }
  grep -q '@[A-Z_]*@' <<<"$out" && fail "$p: unreplaced placeholder in output"
  python3 -I scripts/check-auditor.py "$p" "$D" "$H8" "$CHAIN" <<<"$out" || fails=$((fails + 1))
done
a=$("$R" bi "$D" "$P"); b=$("$R" bi "$D" "$P")
[[ $a == "$b" ]] && ok "render is deterministic" || fail "render differs between runs"
before=$(find "$T" -type f | sort | xargs cksum)
"$R" bi "$D" "$P" >/dev/null; [[ $(find "$T" -type f | sort | xargs cksum) == "$before" ]] && ok "writes nothing" || fail "files changed"
if (( fails )); then echo "FAILED: $fails check(s)" >&2; exit 1; fi
echo "PASS"
