#!/usr/bin/env bash
# Offline test of deploy/driver/render.sh (no cluster; python3 + PyYAML). Exit != 0 on any failure.
set -uo pipefail
cd "$(dirname "$0")/.."
R=deploy/driver/render.sh
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
H8=${H64:0:8}

refuse() { # <label> <expected message part> <args...>
  local label=$1 part=$2; shift 2
  local err rc
  err=$("$R" "$@" 2>&1 >/dev/null); rc=$?
  [[ $rc -eq 2 && $err == *"$part"* ]] && ok "refuses $label (exit 2)" || fail "$label not refused as expected (rc=$rc: $err)"
}
refuse "no arguments" "usage"
refuse "an unknown party" "usage" nobody "$D" "$P"
refuse "a tag instead of a digest" "digest" bi "debian:latest" "$P"
refuse "a short digest" "digest" bi "sha256:abc" "$P"
refuse "a missing public dir" "public dir" bi "$D" "$T/none"
mkdir "$T/p2"; cp "$P/chain_id" "$P/peers.json" "$T/p2/"; refuse "a public dir without genesis.expected_hash" "genesis.expected_hash" bi "$D" "$T/p2"
mkdir "$T/p3"; cp "$P"/* "$T/p3/"; : > "$T/p3/x.seed"; refuse "a public dir holding a seed" "private material" bi "$D" "$T/p3"

for p in bi bank-a bank-b bank-c; do
  out=$("$R" "$p" "$D" "$P" 2>&1) || { fail "$p: render failed: $out"; continue; }
  grep -q '@[A-Z_]*@' <<<"$out" && fail "$p: unreplaced placeholder in output"
  python3 -I scripts/check-driver.py "$p" "$D" "$H8" "$CHAIN" <<<"$out" || fails=$((fails + 1))
done
# --audit-tls: [audit] 2-of-3 through the gateways, [tls], client-cert Secret volume, public server CAs ConfigMap
mkdir -p "$P/gateway-ca"
for q in bi bank-a bank-b bank-c; do printf -- '-----BEGIN CERTIFICATE-----\nMIIB%s\n-----END CERTIFICATE-----\n' "$q" > "$P/gateway-ca/$q-server-ca.pem"; done
for p in bi bank-a bank-b bank-c; do
  out=$("$R" "$p" "$D" "$P" --audit-tls 2>&1) || { fail "$p --audit-tls: render failed: $out"; continue; }
  python3 -I scripts/check-driver.py "$p" "$D" "$H8" "$CHAIN" tls <<<"$out" || fails=$((fails + 1))
done
refuse "--audit-tls without the public server CAs" "server-ca" bi "$D" "$T/p2" --audit-tls
refuse "an unknown extra flag" "usage" bi "$D" "$P" --frob
a=$("$R" bi "$D" "$P"); b=$("$R" bi "$D" "$P")
[[ $a == "$b" ]] && ok "render is deterministic" || fail "render differs between runs"
before=$(find "$T" -type f | sort | xargs cksum)
"$R" bi "$D" "$P" >/dev/null; [[ $(find "$T" -type f | sort | xargs cksum) == "$before" ]] && ok "writes nothing" || fail "files changed"
if (( fails )); then echo "FAILED: $fails check(s)" >&2; exit 1; fi
echo "PASS"
