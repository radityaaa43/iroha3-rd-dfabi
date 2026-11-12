#!/usr/bin/env bash
# Offline test of deploy/auditor-sign/render.sh (no cluster; python3 + PyYAML + openssl). Exit != 0 on any failure.
set -uo pipefail
cd "$(dirname "$0")/.."
R=deploy/auditor-sign/render.sh
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
mkcsr "$T/good" "/CN=bi-auditor"
refuse "no arguments" "usage"
refuse "an unknown party" "usage" bank-z "$D" "$T/good.csr"
refuse "bank-c (no auditor there)" "usage" bank-c "$D" "$T/good.csr"
refuse "a tag instead of a digest" "digest" bi "debian:latest" "$T/good.csr"
refuse "a missing CSR file" "CSR" bi "$D" "$T/none.csr"
mkcsr "$T/cn" "/CN=lensa"; refuse "a CSR with the Lensa subject CN=lensa" "CN=bi-auditor" bi "$D" "$T/cn.csr"
mkcsr "$T/wp" "/CN=bank-a-auditor"; refuse "a CSR for ANOTHER party's auditor (CN=bank-a-auditor for bi)" "CN=bi-auditor" bi "$D" "$T/wp.csr"
mkcsr "$T/cn" "/CN=bi"; refuse "a CSR whose subject is not exactly CN=bi-auditor" "CN=bi-auditor" bi "$D" "$T/cn.csr"
openssl req -new -newkey rsa:2048 -nodes -keyout "$T/rsa.key" -out "$T/rsa.csr" -subj "/CN=bi-auditor" 2>/dev/null; refuse "an RSA CSR (must be EC P-256)" "P-256" bi "$D" "$T/rsa.csr"
mkcsr "$T/san" "/CN=bi-auditor" -addext "subjectAltName=DNS:evil.example"; refuse "a CSR that requests extensions (SAN)" "extension" bi "$D" "$T/san.csr"
mkcsr "$T/ca" "/CN=bi-auditor" -addext "basicConstraints=CA:TRUE"; refuse "a CSR that requests CA:TRUE" "extension" bi "$D" "$T/ca.csr"
printf 'not a csr\n' > "$T/junk.csr"; refuse "a garbage CSR" "CSR" bi "$D" "$T/junk.csr"
cat "$T/good.key" "$T/good.csr" > "$T/withkey.csr"; refuse "a file that also holds a private key" "private" bi "$D" "$T/withkey.csr"
for p in bi bank-a bank-b; do
  mkcsr "$T/pp-$p" "/CN=$p-auditor"
  out=$("$R" "$p" "$D" "$T/pp-$p.csr" 2>&1) || { fail "$p: render failed: $out"; continue; }
  python3 -I scripts/check-auditorsign.py "$p" "$D" "$T/pp-$p.csr" <<<"$out" || fails=$((fails + 1))
  python3 -I scripts/check-netpol-form.py "auditorsign" <<<"$out" || fails=$((fails + 1))
  # MUTANT checks: the checker must reject the Lensa CA Secret and a CSR mismatch
  python3 -I -c '
import sys, yaml
docs = [d for d in yaml.safe_load_all(sys.stdin.read()) if d]
for d in docs:
    if d["kind"] == "Job":
        d["spec"]["template"]["spec"]["volumes"][0]["secret"]["secretName"] = "iroha3-lensa-ca"
print(yaml.safe_dump_all(docs))' <<<"$out" | python3 -I scripts/check-auditorsign.py "$p" "$D" "$T/pp-$p.csr" >/dev/null 2>&1 && fail "MUTANT $p: Job mounting iroha3-lensa-ca passed" || ok "MUTANT $p: a Job mounting the Lensa CA Secret FAILS"
done
a=$("$R" bi "$D" "$T/pp-bi.csr"); b=$("$R" bi "$D" "$T/pp-bi.csr")
[[ -n $a && $a == "$b" ]] && ok "render is deterministic" || fail "render differs between runs or is empty"
# FUNCTIONAL: run the rendered Job script (paths redirected into a temp tree) against a throwaway Lensa CA: the output is ONLY a PEM certificate that verifies, CN=bi-auditor,
# CA:FALSE, EKU clientAuth; the CA key never appears in stdout/stderr; a CSR with a requested extension aborts without a certificate.
runjob() { # <csr> -> prints stdout, sets rc, stderr in $T/err
  local csr=$1 box="$T/box.$RANDOM"; mkdir -p "$box/ca" "$box/csr" "$box/tmp"
  cp "$T/ca/ca.crt" "$T/ca/ca.key" "$box/ca/"; chmod 400 "$box/ca/ca.key"; cp "$csr" "$box/csr/auditor-client.csr"
  "$R" bi "$D" "$T/good.csr" 2>/dev/null | python3 -I -c '
import sys, json
docs = [json.loads(x) for x in sys.stdin.read().split("\n---\n")]
print([d for d in docs if d["kind"] == "Job"][0]["spec"]["template"]["spec"]["containers"][0]["command"][2])' > "$box/job.sh" || return 99
  sed -i "s#/ca/#@CA@/#g; s#/csr/#@CSR@/#g; s#/tmp/#@TMP@/#g; s#@CA@#$box/ca#g; s#@CSR@#$box/csr#g; s#@TMP@#$box/tmp#g" "$box/job.sh"
  sh "$box/job.sh" > "$box/out" 2> "$T/err"; local rc=$?; JOBOUT="$box/out"; return $rc
}
mkdir -p "$T/ca"; openssl req -x509 "${ec[@]}" -keyout "$T/ca/ca.key" -out "$T/ca/ca.crt" -days 30 -subj "/CN=iroha3-bi-role-ca" -addext "basicConstraints=critical,CA:TRUE,pathlen:0" -addext "keyUsage=critical,keyCertSign,cRLSign" 2>/dev/null
if runjob "$T/good.csr"; then
  ok "the Job script signs a good CSR (rc 0)"
  [[ $(grep -c 'BEGIN' "$JOBOUT") -eq 1 && $(grep -c 'BEGIN CERTIFICATE' "$JOBOUT") -eq 1 ]] && ok "stdout is ONE PEM certificate and nothing else" || fail "stdout is not exactly one certificate: $(head -3 "$JOBOUT")"
  ! grep -q 'PRIVATE KEY' "$JOBOUT" "$T/err" && ok "no private key in stdout or stderr" || fail "a private key was printed"
  txt=$(openssl x509 -in "$JOBOUT" -noout -text 2>/dev/null)
  openssl verify -CAfile "$T/ca/ca.crt" -purpose sslclient "$JOBOUT" >/dev/null 2>&1 && [[ $txt == *"Subject: CN = bi-auditor"* || $txt == *"Subject: CN=bi-auditor"* ]] && [[ $txt == *"CA:FALSE"* && $txt == *"TLS Web Client Authentication"* ]] && ok "the certificate verifies against the CA: CN=bi-auditor, CA:FALSE, EKU clientAuth" || fail "certificate shape: $txt"
else
  fail "the Job script failed on a good CSR: $(cat "$T/err")"
fi
mkcsr "$T/ext2" "/CN=bi-auditor" -addext "subjectAltName=DNS:evil.example"
cp "$T/ext2.csr" "$T/ext2-forced.csr"
if runjob "$T/ext2.csr"; then fail "the Job script signed a CSR with a requested extension"; elif grep -q "requests extensions" "$T/err" && [[ ! -s $JOBOUT ]]; then ok "the Job script ABORTS on a CSR with a requested extension (its own message, empty stdout, no certificate)"; else fail "aborted for another reason: $(cat "$T/err")"; fi
# keygen.sh + secret.sh (org side): key never printed, 0400, fresh dir only; the Secret is created only for a matching CN=<party>-auditor clientAuth leaf; the key is shredded afterwards
export AUDITOR_SIGN_ALLOW_DISK=1
KG=deploy/auditor-sign/keygen.sh; SC=deploy/auditor-sign/secret.sh
mkdir -m 700 "$T/kg"; kout=$($KG bank-a "$T/kg" 2>&1) && [[ $(stat -c %a "$T/kg/tls.key") == 400 ]] && ! grep -q 'PRIVATE' <<<"$kout" && ok "keygen.sh: key 0400, not printed" || fail "keygen.sh: $kout"
[[ $(openssl req -in "$T/kg/auditor-client.csr" -noout -subject -nameopt RFC2253) == "subject=CN=bank-a-auditor" ]] && "$R" bank-a "$D" "$T/kg/auditor-client.csr" >/dev/null 2>&1 && ok "keygen.sh CSR is accepted by render.sh" || fail "keygen CSR not accepted by render.sh"
$KG bank-a "$T/kg" >/dev/null 2>&1 && fail "keygen.sh reused a dirty work dir" || ok "keygen.sh refuses a non-fresh work dir"
$KG bank-c "$T/kg" >/dev/null 2>&1 && fail "keygen.sh accepted bank-c" || ok "keygen.sh refuses bank-c"
ext=$T/leaf.ext; printf 'basicConstraints=CA:FALSE\nkeyUsage=digitalSignature\nextendedKeyUsage=clientAuth\n' > "$ext"
openssl x509 -req -in "$T/kg/auditor-client.csr" -CA "$T/ca/ca.crt" -CAkey "$T/ca/ca.key" -CAcreateserial -CAserial "$T/ca/s.srl" -days 30 -extfile "$ext" -out "$T/kg.crt" 2>/dev/null
printf '#!/bin/sh\necho "$@" > "%s/kubectl.args"\n' "$T" > "$T/kubectl"; chmod +x "$T/kubectl"
KUBECTL="$T/kubectl" $SC bank-b "$T/kg" "$T/kg.crt" >/dev/null 2>&1 && fail "secret.sh accepted a bank-a leaf for bank-b" || ok "secret.sh refuses a leaf of ANOTHER party"
cp "$T/kg/tls.key" "$T/kg.key.keep"
mkdir -m 700 "$T/kg2"; $KG bank-a "$T/kg2" >/dev/null; KUBECTL="$T/kubectl" $SC bank-a "$T/kg2" "$T/kg.crt" >/dev/null 2>&1 && fail "secret.sh accepted a leaf that does not match the key" || ok "secret.sh refuses a certificate that does not match the key"
KUBECTL="$T/kubectl" $SC bank-a "$T/kg" "$T/kg.crt" >/dev/null 2>&1 && grep -q "create secret generic auditor-client-cert -n rd-iroha3-bank-a" "$T/kubectl.args" && [[ ! -e $T/kg/tls.key ]] && ok "secret.sh creates Secret auditor-client-cert (plain create) and shreds the key" || fail "secret.sh happy path"
if (( fails )); then echo "FAILED: $fails check(s)" >&2; exit 1; fi
echo "PASS"
