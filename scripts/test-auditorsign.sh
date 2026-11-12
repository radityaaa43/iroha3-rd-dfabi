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
srefuse() { local label=$1 part=$2; shift 2; refuse "$label" "$part" sign "$@"; }
mkcsr "$T/good" "/CN=bi-auditor"
srefuse "no arguments" "usage"
srefuse "an unknown party" "usage" bank-z "$D" "$T/good.csr"
srefuse "bank-c (no auditor there)" "usage" bank-c "$D" "$T/good.csr"
srefuse "a tag instead of a digest" "digest" bi "debian:latest" "$T/good.csr"
srefuse "a missing CSR file" "CSR" bi "$D" "$T/none.csr"
mkcsr "$T/cn" "/CN=lensa"; srefuse "a CSR with the Lensa subject CN=lensa" "CN=bi-auditor" bi "$D" "$T/cn.csr"
mkcsr "$T/wp" "/CN=bank-a-auditor"; srefuse "a CSR for ANOTHER party's auditor (CN=bank-a-auditor for bi)" "CN=bi-auditor" bi "$D" "$T/wp.csr"
mkcsr "$T/cn" "/CN=bi"; srefuse "a CSR whose subject is not exactly CN=bi-auditor" "CN=bi-auditor" bi "$D" "$T/cn.csr"
openssl req -new -newkey rsa:2048 -nodes -keyout "$T/rsa.key" -out "$T/rsa.csr" -subj "/CN=bi-auditor" 2>/dev/null; srefuse "an RSA CSR (must be EC P-256)" "P-256" bi "$D" "$T/rsa.csr"
mkcsr "$T/san" "/CN=bi-auditor" -addext "subjectAltName=DNS:evil.example"; srefuse "a CSR that requests extensions (SAN)" "extension" bi "$D" "$T/san.csr"
mkcsr "$T/ca" "/CN=bi-auditor" -addext "basicConstraints=CA:TRUE"; srefuse "a CSR that requests CA:TRUE" "extension" bi "$D" "$T/ca.csr"
printf 'not a csr\n' > "$T/junk.csr"; srefuse "a garbage CSR" "CSR" bi "$D" "$T/junk.csr"
cat "$T/good.key" "$T/good.csr" > "$T/withkey.csr"; srefuse "a file that also holds a private key" "private" bi "$D" "$T/withkey.csr"
for p in bi bank-a bank-b; do
  mkcsr "$T/pp-$p" "/CN=$p-auditor"
  out=$("$R" sign "$p" "$D" "$T/pp-$p.csr" 2>&1) || { fail "$p: render failed: $out"; continue; }
  python3 -I scripts/check-auditorsign.py sign "$p" "$D" "$T/pp-$p.csr" <<<"$out" || fails=$((fails + 1))
  python3 -I scripts/check-netpol-form.py "auditorsign" <<<"$out" || fails=$((fails + 1))
  # MUTANT checks: the checker must reject the Lensa CA Secret and a CSR mismatch
  python3 -I -c '
import sys, yaml
docs = [d for d in yaml.safe_load_all(sys.stdin.read()) if d]
for d in docs:
    if d["kind"] == "Job":
        d["spec"]["template"]["spec"]["volumes"][0]["secret"]["secretName"] = "iroha3-lensa-ca"
print(yaml.safe_dump_all(docs))' <<<"$out" | python3 -I scripts/check-auditorsign.py sign "$p" "$D" "$T/pp-$p.csr" >/dev/null 2>&1 && fail "MUTANT $p: Job mounting iroha3-lensa-ca passed" || ok "MUTANT $p: a Job mounting the Lensa CA Secret FAILS"
done
a=$("$R" sign bi "$D" "$T/pp-bi.csr"); b=$("$R" sign bi "$D" "$T/pp-bi.csr")
[[ -n $a && $a == "$b" ]] && ok "render is deterministic" || fail "render differs between runs or is empty"
# FUNCTIONAL: run the rendered Job script (paths redirected into a temp tree) against a throwaway Lensa CA: the output is ONLY a PEM certificate that verifies, CN=bi-auditor,
# CA:FALSE, EKU clientAuth; the CA key never appears in stdout/stderr; a CSR with a requested extension aborts without a certificate.
runjob() { # <csr> -> prints stdout, sets rc, stderr in $T/err
  local csr=$1 box="$T/box.$RANDOM"; mkdir -p "$box/ca" "$box/csr" "$box/tmp"
  cp "$T/ca/ca.crt" "$T/ca/ca.key" "$box/ca/"; chmod 400 "$box/ca/ca.key"; cp "$csr" "$box/csr/auditor-client.csr"
  "$R" sign bi "$D" "$T/good.csr" 2>/dev/null | python3 -I -c '
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
# ---- OPTION C stages: keygen (key made IN the pod, written into the pre-created empty Secret through a Role limited to get/update/patch on resourceNames [auditor-client-cert]) and put (public cert) ----
TI=docker.io/alpine/k8s@sha256:$(printf 'b%.0s' $(seq 1 64))
API=(--apiserver 10.200.0.1/32:443 --apiserver 172.24.11.240/32:6443)
refuse "keygen without --apiserver" "usage" keygen bi "$TI" "$D"
refuse "keygen with a tag driver image" "driver image" keygen bi "$TI" debian:latest "${API[@]}"
refuse "keygen with a tag image" "digest" keygen bi docker.io/alpine/k8s:3.19 "$D" "${API[@]}"
refuse "keygen with a bad --apiserver" "--apiserver" keygen bi "$TI" "$D" --apiserver 10.200.0.1/24:443
refuse "keygen for bank-c" "usage" keygen bank-c "$TI" "$D" "${API[@]}"
for p in bi bank-a bank-b; do
  out=$("$R" keygen "$p" "$TI" "$D" "${API[@]}" 2>&1) || { fail "$p keygen render failed: $out"; continue; }
  python3 -I scripts/check-auditorapi.py keygen "$p" "$TI" "$D" 10.200.0.1/32:443 172.24.11.240/32:6443 <<<"$out" || fails=$((fails + 1))
done
kg=$("$R" keygen bank-a "$TI" "$D" "${API[@]}")
kmut() { # <label> <python on docs by (kind,name)>
  python3 -I -c '
import sys, yaml
docs = [d for d in yaml.safe_load_all(sys.stdin.read()) if d]
by = {(d["kind"], d["metadata"]["name"]): d for d in docs}
exec(sys.argv[1]); print(yaml.safe_dump_all(docs))' "$2" <<<"$kg" | python3 -I scripts/check-auditorapi.py keygen bank-a "$TI" "$D" 10.200.0.1/32:443 172.24.11.240/32:6443 >/dev/null 2>&1 && fail "MUTANT $1 passed" || ok "MUTANT: $1 FAILS the keygen checker"
}
RL='by[("Role","auditor-client-api")]["rules"][0]'
kmut "the Role also allows create" "$RL"'["verbs"].append("create")'
kmut "the Role also allows list" "$RL"'["verbs"].append("list")'
kmut "the Role also allows watch" "$RL"'["verbs"].append("watch")'
kmut "the Role also allows delete" "$RL"'["verbs"].append("delete")'
kmut "the Role without resourceNames (all secrets)" "$RL"'.pop("resourceNames")'
kmut "the Role resourceNames naming another Secret" "$RL"'["resourceNames"].append("iroha3-role-ca")'
kmut "the Role on another resource too" "$RL"'["resources"].append("configmaps")'
kmut "a ClusterRoleBinding style subject (another SA)" 'by[("RoleBinding","auditor-client-api")]["subjects"].append({"kind":"ServiceAccount","name":"default","namespace":"rd-iroha3-bank-a"})'
kmut "the keygen NetworkPolicy also allows DNS" 'by[("NetworkPolicy","auditor-client-api-egress")]["spec"]["egress"].append({"to":[{"namespaceSelector":{"matchLabels":{"kubernetes.io/metadata.name":"kube-system"}}}],"ports":[{"protocol":"UDP","port":53}]})'
kmut "the keygen NetworkPolicy opens 0.0.0.0/0" 'by[("NetworkPolicy","auditor-client-api-egress")]["spec"]["egress"][0]["to"].append({"ipBlock":{"cidr":"0.0.0.0/0"}})'
kmut "the keygen pod without rd/egress-locked" 'by[("Job","auditor-client-keygen")]["spec"]["template"]["metadata"]["labels"].pop("rd/egress-locked")'
kmut "the keygen pod mounting a Secret volume" 'v = by[("Job","auditor-client-keygen")]["spec"]["template"]["spec"]["volumes"]; v.append({"name":"s","secret":{"secretName":"iroha3-role-ca"}})'
kmut "the tools-image script calling openssl" 'c = by[("Job","auditor-client-keygen")]["spec"]["template"]["spec"]["containers"][0]["command"]; c[2] += "\nopenssl version"'
kmut "the openssl initContainer printing the key" 'c = by[("Job","auditor-client-keygen")]["spec"]["template"]["spec"]["initContainers"][0]["command"]; c[2] += "\ncat /work/tls.key"'
kmut "the openssl initContainer with kubectl (key + API in one container)" 'c = by[("Job","auditor-client-keygen")]["spec"]["template"]["spec"]["initContainers"][0]["command"]; c[2] += "\nkubectl version"'
kmut "the driver image by tag in the initContainer" 'by[("Job","auditor-client-keygen")]["spec"]["template"]["spec"]["initContainers"][0]["image"] = "ghcr.io/radityaaa43/iroha3-rd-driver:latest"'
kmut "the key hand-over volume on a disk (no Memory)" 'v = [x for x in by[("Job","auditor-client-keygen")]["spec"]["template"]["spec"]["volumes"] if x["name"] == "work"][0]; v["emptyDir"].pop("medium")'
kmut "the keygen script printing the key" 'c = by[("Job","auditor-client-keygen")]["spec"]["template"]["spec"]["containers"][0]["command"]; c[2] += "\ncat /tmp/tls.key"'
kmut "the keygen script without the empty-Secret guard" 'c = by[("Job","auditor-client-keygen")]["spec"]["template"]["spec"]["containers"][0]["command"]; c[2] = c[2].replace("refusing to overwrite a key", "ok")'
kmut "the keygen script putting the key into an argv (-p)" 'c = by[("Job","auditor-client-keygen")]["spec"]["template"]["spec"]["containers"][0]["command"]; c[2] += "\nkubectl patch secret auditor-client-cert -p x"'
kmut "the tools image by tag" 'by[("Job","auditor-client-keygen")]["spec"]["template"]["spec"]["containers"][0]["image"] = "docker.io/alpine/k8s:1.30"'
kmut "a rendered Secret object" 'docs.append({"apiVersion":"v1","kind":"Secret","metadata":{"name":"auditor-client-cert","namespace":"rd-iroha3-bank-a","labels":{"app.kubernetes.io/part-of":"rd-iroha3"}},"stringData":{"x":"y"}})'
# FUNCTIONAL: run the rendered keygen script with a stub kubectl and the real openssl: the key goes ONLY into the patch file (base64, tls.key), stdout is ONLY the CSR, no key in stdout/stderr,
# a non-empty Secret aborts before any key is made.
mkjob() { # <stage docs> <out main script>   (the init script goes to <out>.init)
  python3 -I -c '
import sys, yaml
docs = [d for d in yaml.safe_load_all(sys.stdin.read()) if d]
sp = [d for d in docs if d["kind"] == "Job"][0]["spec"]["template"]["spec"]
print(sp["containers"][0]["command"][2]); open(sys.argv[1] + ".init", "w").write(sp["initContainers"][0]["command"][2] + "\n")' "$2" <<<"$1" > "$2"
}
fbox() { # <script> <count> -> runs it in a temp tree with a stub kubectl; sets rc, stdout in $T/fout, stderr in $T/ferr, patch in $T/fbox/tmp/patch.json
  local sc=$1 cnt=$2; local b="$T/fbox"; find "$b" -mindepth 1 -delete 2>/dev/null; mkdir -p "$b/bin" "$b/tmp"
  cat > "$b/bin/kubectl" <<'STUB'
#!/bin/sh
case "$*" in
  *"{{if .data}}"*) echo "$STUB_COUNT" ;;
  *"{{range"*) echo "tls.key" ;;
  *patch*) cp "$STUB_PATCH" "$STUB_SEEN" ;;
esac
STUB
  chmod +x "$b/bin/kubectl"
  mkdir -p "$b/work"
  sed "s#/work/#$b/work/#g" "$sc.init" > "$b/init.sh"; sed "s#/tmp/#$b/tmp/#g; s#/work/#$b/work/#g" "$sc" > "$b/job.sh"
  sh "$b/init.sh" > "$T/finit" 2>&1 || { cp "$T/finit" "$T/ferr"; : > "$T/fout"; return 98; }
  STUB_COUNT=$cnt STUB_PATCH="$b/tmp/patch.json" STUB_SEEN="$b/seen.json" PATH="$b/bin:$PATH" sh "$b/job.sh" > "$T/fout" 2> "$T/ferr"; return $?
}
mkjob "$kg" "$T/kg.sh"
if fbox "$T/kg.sh" 0; then
  ok "the keygen script runs against an empty Secret (rc 0)"
  [[ $(grep -c 'BEGIN CERTIFICATE REQUEST' "$T/fout") -eq 1 && $(grep -c 'BEGIN' "$T/fout") -eq 1 ]] && ok "stdout is ONE PEM CSR and nothing else" || fail "stdout is not exactly one CSR: $(head -2 "$T/fout")"
  ! grep -q 'PRIVATE KEY' "$T/fout" "$T/ferr" && ok "no private key in stdout or stderr" || fail "a private key was printed"
  python3 -I -c '
import base64, json, sys
d = json.load(open(sys.argv[1]))["data"]
assert list(d) == ["tls.key"], list(d)
assert b"PRIVATE KEY" in base64.b64decode(d["tls.key"])' "$T/fbox/seen.json" && ok "the patch carries ONLY tls.key (base64 PEM key)" || fail "the patch is wrong"
  [[ $(openssl req -in "$T/fout" -noout -subject -nameopt RFC2253) == "subject=CN=bank-a-auditor" ]] && openssl req -in "$T/fout" -noout -verify >/dev/null 2>&1 && ok "the CSR verifies, CN=bank-a-auditor" || fail "bad CSR"
else
  fail "the keygen script failed on an empty Secret: $(cat "$T/ferr")"
fi
if fbox "$T/kg.sh" 1; then fail "the keygen script ran against a NON-empty Secret"; elif grep -q "refusing to overwrite" "$T/ferr" && [[ ! -s $T/fout && ! -e $T/fbox/seen.json ]]; then ok "the keygen script ABORTS on a non-empty Secret (no key made, no patch)"; else fail "abort path wrong: $(cat "$T/ferr")"; fi
# put stage
openssl x509 -req -in "$T/pp-bank-a.csr" -CA "$T/ca/ca.crt" -CAkey "$T/ca/ca.key" -CAcreateserial -CAserial "$T/ca/s.srl" -days 30 -extfile <(printf 'basicConstraints=CA:FALSE\nkeyUsage=digitalSignature\nextendedKeyUsage=clientAuth\n') -out "$T/leaf-a.crt" 2>/dev/null
openssl x509 -req -in "$T/pp-bi.csr" -CA "$T/ca/ca.crt" -CAkey "$T/ca/ca.key" -CAcreateserial -CAserial "$T/ca/s.srl" -days 30 -extfile <(printf 'basicConstraints=CA:FALSE\nkeyUsage=digitalSignature\nextendedKeyUsage=clientAuth\n') -out "$T/leaf-bi.crt" 2>/dev/null
openssl x509 -req -in "$T/pp-bank-a.csr" -CA "$T/ca/ca.crt" -CAkey "$T/ca/ca.key" -CAcreateserial -CAserial "$T/ca/s.srl" -days 30 -extfile <(printf 'basicConstraints=CA:FALSE\nextendedKeyUsage=serverAuth,clientAuth\n') -out "$T/leaf-both.crt" 2>/dev/null
refuse "put with a certificate of ANOTHER party" "CN=bank-a-auditor" put bank-a "$TI" "$D" "$T/leaf-bi.crt"
refuse "put with a serverAuth+clientAuth certificate" "clientAuth only" put bank-a "$TI" "$D" "$T/leaf-both.crt"
refuse "put with a missing certificate" "not found" put bank-a "$TI" "$D" "$T/none.crt"
refuse "put with a tag image" "digest" put bank-a docker.io/alpine/k8s:3.19 "$D" "$T/leaf-a.crt"
pt=$("$R" put bank-a "$TI" "$D" "$T/leaf-a.crt" 2>&1) && python3 -I scripts/check-auditorapi.py put bank-a "$TI" "$D" "$T/leaf-a.crt" <<<"$pt" || fail "put render/check: $pt"
pmut() { python3 -I -c '
import sys, yaml
docs = [d for d in yaml.safe_load_all(sys.stdin.read()) if d]
by = {(d["kind"], d["metadata"]["name"]): d for d in docs}
exec(sys.argv[1]); print(yaml.safe_dump_all(docs))' "$2" <<<"$pt" | python3 -I scripts/check-auditorapi.py put bank-a "$TI" "$D" "$T/leaf-a.crt" >/dev/null 2>&1 && fail "MUTANT $1 passed" || ok "MUTANT: $1 FAILS the put checker"; }
pmut "the put script also writing tls.key" 'c = by[("Job","auditor-client-put")]["spec"]["template"]["spec"]["containers"][0]["command"]; c[2] += "\nkubectl patch secret auditor-client-cert --patch-file /tmp/patch.json # tls.key"'
pmut "the put Job mounting a Secret" 'by[("Job","auditor-client-put")]["spec"]["template"]["spec"]["volumes"].append({"name":"s","secret":{"secretName":"auditor-client-cert"}})'
pmut "a key in the certificate ConfigMap" 'by[("ConfigMap","auditor-client-crt")]["data"]["tls.crt"] += "-----BEGIN PRIVATE KEY-----\nAA\n-----END PRIVATE KEY-----\n"'
mkjob "$pt" "$T/put.sh"
if fbox "$T/put.sh" 0 2>/dev/null; then :; fi
if (( fails )); then echo "FAILED: $fails check(s)" >&2; exit 1; fi
echo "PASS"
