#!/usr/bin/env bash
# Offline test of deploy/gateway/ca-enroll.sh with REAL openssl and a STUB kubectl (no cluster). Needs bash, openssl.
set -uo pipefail
cd "$(dirname "$0")/.."
S=deploy/gateway/ca-enroll.sh
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fails=0
fail() { echo "FAIL: $*" >&2; fails=$((fails + 1)); }
ok() { echo "ok:   $*"; }
mkdir "$T/bin"
cat > "$T/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
echo "kubectl $*" >> "$STUB_LOG"
[[ -n "${STUB_EXISTS:-}" ]] && { echo "Error from server (AlreadyExists): secret exists" >&2; exit 1; }
if [[ $1 != create ]]; then echo "Error from server (Forbidden): verb $1 on secrets is not allowed" >&2; exit 1; fi
for a in "$@"; do case $a in --from-file=*) f=${a#--from-file=}; echo "FILE ${f%%=*}" >> "$STUB_LOG" ;; esac; done
echo "secret created"
STUB
chmod +x "$T/bin/kubectl"
export STUB_LOG="$T/log" KUBECTL="$T/bin/kubectl" CA_ENROLL_ALLOW_DISK=1
refuse() { local label=$1 reason=$2; shift 2; local out rc; out=$("$S" "$@" 2>&1); rc=$?; [[ $rc -eq 2 && $out == *"$reason"* ]] && ok "refuses $label (exit 2)" || fail "$label: rc=$rc $out"; }
refuse "no arguments" "usage"
refuse "an unknown party" "usage" init nobody "$T/w"
refuse "an unknown command" "usage" frob bi "$T/w"
mkdir -m 700 "$T/w0"; out=$(CA_ENROLL_ALLOW_DISK= "$S" init bi "$T/w0" 2>&1); rc=$?
[[ $rc -eq 2 && $out == *"/dev/shm"* ]] && ok "refuses a work dir outside /dev/shm (exit 2)" || fail "outside /dev/shm: rc=$rc $out"
mkdir -m 755 "$T/open"; refuse "a group/world-accessible work dir" "mode 700" init bi "$T/open"

: > "$STUB_LOG"; W="$T/w"; mkdir -m 700 "$W"
out=$("$S" init bank-a "$W" 2>&1); rc=$?
[[ $rc -eq 0 ]] && ok "init bank-a succeeds" || fail "init: rc=$rc $out"
[[ $out != *"PRIVATE KEY"* ]] && ok "prints no key" || fail "a key was printed"
P="$W/public"
for f in bank-a-role-ca.pem bank-a-server-ca.pem; do [[ -s $P/$f ]] && ok "public $f written" || fail "missing $P/$f"; done
for s in gateway-server iroha3-role-ca iroha3-server-ca iroha3-client-cert; do
  grep -q "create secret generic $s -n rd-iroha3-bank-a" "$STUB_LOG" && ok "Secret $s created in rd-iroha3-bank-a by plain create" || fail "Secret $s not created: $(cat "$STUB_LOG")"
done
! grep -qE "gateway-client-ca|apply|--dry-run" "$STUB_LOG" && ok "init creates no gateway-client-ca and never apply/dry-run" || fail "unexpected kubectl call"
[[ -z $(find "$W" -name '*.key' -o -name '*.srl' 2>/dev/null) ]] && ok "private keys shredded from the work dir after the Secrets exist" || fail "private material left: $(find "$W" -name '*.key')"
# the issued material was verified inside init; re-check what stayed public
[[ $(openssl x509 -in "$P/bank-a-role-ca.pem" -noout -subject 2>/dev/null | grep -c "iroha3-bank-a-role-ca") -ge 1 ]] && ok "role CA subject names the party" || fail "role CA subject"
[[ $(openssl x509 -in "$P/bank-a-role-ca.pem" -noout -text | grep -c "CA:TRUE") -ge 1 ]] && ok "role CA is a CA" || fail "role CA not a CA"
[[ $(openssl x509 -in "$P/bank-a-role-ca.pem" -noout -issuer) == "$(openssl x509 -in "$P/bank-a-role-ca.pem" -noout -subject | sed 's/subject/issuer/')" ]] && ok "role CA is self-signed (root)" || fail "role CA not self-signed"
refuse "a second init over an existing work dir" "already" init bank-a "$W"

# trust: gateway-client-ca from public PEMs only
: > "$STUB_LOG"
cp "$P/bank-a-role-ca.pem" "$T/lensa.pem"
out=$("$S" trust bank-a "$W" "$T/lensa.pem" "$P/bank-a-role-ca.pem" 2>&1); rc=$?
[[ $rc -eq 0 ]] && grep -q "create secret generic gateway-client-ca -n rd-iroha3-bank-a" "$STUB_LOG" && ok "trust creates gateway-client-ca (public PEM bundle)" || fail "trust: rc=$rc $out $(cat "$STUB_LOG")"
echo "-----BEGIN PRIVATE KEY-----" > "$T/bad.pem"
refuse "a private key given as a trust PEM" "private key" trust bank-a "$W" "$T/bad.pem"
refuse "trust without any PEM" "usage" trust bank-a "$W"
: > "$STUB_LOG"; out=$(STUB_EXISTS=1 "$S" trust bank-a "$W" "$T/lensa.pem" "$P/bank-a-role-ca.pem" 2>&1); rc=$?
[[ $rc -ne 0 && $out == *AlreadyExists* && $out != *" created in "* ]] && ok "kubectl failure: non-zero exit, no success line (pipefail/rc)" || fail "kubectl failure: rc=$rc $out"
if (( fails )); then echo "FAILED: $fails check(s)" >&2; exit 1; fi
echo "PASS"
