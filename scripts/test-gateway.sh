#!/usr/bin/env bash
# Offline test of deploy/gateway/render.sh (no cluster, no docker; python3 + PyYAML). Exit != 0 on any failure.
set -uo pipefail
cd "$(dirname "$0")/.."
R=deploy/gateway/render.sh
fails=0
fail() { echo "FAIL: $*" >&2; fails=$((fails + 1)); }
ok() { echo "ok:   $*"; }
T=$(mktemp -d); trap 'rm -r -- "$T"' EXIT
EI=example.io/envoy@sha256:$(printf 'e%.0s' $(seq 1 64))
OI=example.io/opa@sha256:$(printf 'f%.0s' $(seq 1 64))
cat > "$T/opa.yaml" <<'EOF'
plugins:
  envoy_ext_authz_grpc:
    addr: 127.0.0.1:9191
    path: gw/allow
keys:
  bank:
    algorithm: RS256
    key: |
      -----BEGIN PUBLIC KEY-----
      MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8A
      -----END PUBLIC KEY-----
EOF
sed 's/PUBLIC KEY/PRIVATE KEY/' "$T/opa.yaml" > "$T/opa-private.yaml"
printf 'plugins: {}\n' > "$T/opa-nokeys.yaml"
ACL=acl-d9ji5nwbqutwulof33ydb

refuse() { # <label> <expected message part> <args...>
  local label=$1 part=$2; shift 2
  local err rc
  err=$("$R" "$@" 2>&1 >/dev/null); rc=$?
  [[ $rc -eq 2 && $err == *"$part"* ]] && ok "refuses $label (exit 2)" || fail "$label not refused as expected (rc=$rc: $err)"
}
base=(--envoy-image "$EI" --opa-image "$OI" --opa-config "$T/opa.yaml")
refuse "no arguments" "usage"
refuse "an unknown party" "usage" nobody "${base[@]}"
refuse "an envoy tag instead of a digest" "digest" bi --envoy-image envoy:v1 --opa-image "$OI" --opa-config "$T/opa.yaml"
refuse "an opa tag instead of a digest" "digest" bi --envoy-image "$EI" --opa-image opa:latest --opa-config "$T/opa.yaml"
refuse "a missing opa config" "opa-config" bi --envoy-image "$EI" --opa-image "$OI" --opa-config "$T/none.yaml"
refuse "an opa config with a private key" "private key" bi --envoy-image "$EI" --opa-image "$OI" --opa-config "$T/opa-private.yaml"
refuse "an opa config without keys and plugin" "keys" bi --envoy-image "$EI" --opa-image "$OI" --opa-config "$T/opa-nokeys.yaml"
refuse "bank-c on cluster 1" "cluster" bank-c "${base[@]}" --cluster 1
refuse "bi on cluster 2" "cluster" bi "${base[@]}" --cluster 2
refuse "cluster 2 without --lb-acl" "lb-acl" bank-c "${base[@]}" --cluster 2 --lb-range 47.237.84.150/32
refuse "cluster 2 without --lb-range" "lb-range" bank-c "${base[@]}" --cluster 2 --lb-acl "$ACL"
refuse "cluster 1 with an LB acl" "lb-acl" bi "${base[@]}" --lb-acl "$ACL" --lb-range 47.237.84.150/32
refuse "a bad acl id" "lb-acl" bank-c "${base[@]}" --cluster 2 --lb-acl "x;y" --lb-range 47.237.84.150/32
refuse "a range that is not a /32" "lb-range" bank-c "${base[@]}" --cluster 2 --lb-acl "$ACL" --lb-range 10.0.0.0/8

for p in bi bank-a bank-b; do
  out=$("$R" "$p" "${base[@]}" 2>&1) || { fail "$p: render failed: $out"; continue; }
  grep -q '@[A-Z_]*@' <<<"$out" && fail "$p: unreplaced placeholder in output"
  python3 -I scripts/check-gateway.py "$p" 1 "$EI" "$OI" <<<"$out" || fails=$((fails + 1))
done
out=$("$R" bank-c "${base[@]}" --cluster 2 --lb-acl "$ACL" --lb-range 47.237.84.150/32 2>&1) || fail "bank-c: render failed: $out"
python3 -I scripts/check-gateway.py bank-c 2 "$EI" "$OI" <<<"$out" || fails=$((fails + 1))
grep -q "47.237.84.150/32" <<<"$out" && grep -q "$ACL" <<<"$out" && ok "bank-c carries the existing ACL id and source range" || fail "bank-c: ACL id or range missing"
a=$("$R" bi "${base[@]}"); b=$("$R" bi "${base[@]}")
[[ -n $a && $a == "$b" ]] && ok "render is deterministic" || fail "render differs between runs or is empty"
before=$(find "$T" -type f | sort | xargs cksum)
"$R" bi "${base[@]}" >/dev/null; [[ $(find "$T" -type f | sort | xargs cksum) == "$before" ]] && ok "writes nothing" || fail "files changed"
if (( fails )); then echo "FAILED: $fails check(s)" >&2; exit 1; fi
echo "PASS"
