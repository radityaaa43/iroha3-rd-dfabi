#!/usr/bin/env bash
# Offline test of deploy/lensa-sign/render.sh (no cluster; python3 + PyYAML + openssl). Exit != 0 on any failure.
set -uo pipefail
cd "$(dirname "$0")/.."
R=deploy/lensa-sign/render.sh
fails=0
fail() { echo "FAIL: $*" >&2; fails=$((fails + 1)); }
ok() { echo "ok:   $*"; }
T=$(mktemp -d); trap 'find "$T" -delete' EXIT
D=sha256:$(printf 'a%.0s' $(seq 1 64))
ec=(-newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes)
mkcsr() { # <out-prefix> <subject> [extra openssl req args]
  local o=$1 s=$2; shift 2
  openssl req -new "${ec[@]}" -keyout "$o.key" -out "$o.csr" -subj "$s" "$@" 2>/dev/null
}
refuse() { local label=$1 part=$2; shift 2; local err rc; err=$("$R" "$@" 2>&1 >/dev/null); rc=$?; [[ $rc -eq 2 && $err == *"$part"* ]] && ok "refuses $label (exit 2)" || fail "$label not refused (rc=$rc): $err"; }
mkcsr "$T/good" "/CN=lensa"
refuse "no arguments" "usage"
refuse "an unknown party" "usage" bank-z "$D" "$T/good.csr"
refuse "a tag instead of a digest" "digest" bi "debian:latest" "$T/good.csr"
refuse "a missing CSR file" "CSR" bi "$D" "$T/none.csr"
mkcsr "$T/cn" "/CN=bi"; refuse "a CSR whose subject is not exactly CN=lensa" "CN=lensa" bi "$D" "$T/cn.csr"
openssl req -new -newkey rsa:2048 -nodes -keyout "$T/rsa.key" -out "$T/rsa.csr" -subj "/CN=lensa" 2>/dev/null; refuse "an RSA CSR (must be EC P-256)" "P-256" bi "$D" "$T/rsa.csr"
mkcsr "$T/san" "/CN=lensa" -addext "subjectAltName=DNS:evil.example"; refuse "a CSR that requests extensions (SAN)" "extension" bi "$D" "$T/san.csr"
mkcsr "$T/ca" "/CN=lensa" -addext "basicConstraints=CA:TRUE"; refuse "a CSR that requests CA:TRUE" "extension" bi "$D" "$T/ca.csr"
printf 'not a csr\n' > "$T/junk.csr"; refuse "a garbage CSR" "CSR" bi "$D" "$T/junk.csr"
cat "$T/good.key" "$T/good.csr" > "$T/withkey.csr"; refuse "a file that also holds a private key" "private" bi "$D" "$T/withkey.csr"
for p in bi bank-a bank-b bank-c; do
  out=$("$R" "$p" "$D" "$T/good.csr" 2>&1) || { fail "$p: render failed: $out"; continue; }
  python3 -I scripts/check-lensasign.py "$p" "$D" "$T/good.csr" <<<"$out" || fails=$((fails + 1))
  python3 -I scripts/check-netpol-form.py "lensasign" <<<"$out" || fails=$((fails + 1))
done
a=$("$R" bi "$D" "$T/good.csr"); b=$("$R" bi "$D" "$T/good.csr")
[[ -n $a && $a == "$b" ]] && ok "render is deterministic" || fail "render differs between runs or is empty"
if (( fails )); then echo "FAILED: $fails check(s)" >&2; exit 1; fi
echo "PASS"
