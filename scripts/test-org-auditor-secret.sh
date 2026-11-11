#!/usr/bin/env bash
# Offline test of deploy/auditor/org-secret.sh with a STUB kubectl (no cluster, no real keys). Needs bash.
set -uo pipefail
cd "$(dirname "$0")/.."
S=deploy/auditor/org-secret.sh
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fails=0
fail() { echo "FAIL: $*" >&2; fails=$((fails + 1)); }
ok() { echo "ok:   $*"; }
mkdir "$T/bin"
cat > "$T/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
echo "kubectl $*" >> "$STUB_LOG"
if [[ $1 != create ]]; then echo "Error from server (Forbidden): verb $1 on secrets is not allowed" >&2; exit 1; fi
for a in "$@"; do case $a in --from-file=*) f=${a#--from-file=}; echo "FILE ${f%%=*} $(wc -c < "${f#*=}")" >> "$STUB_LOG" ;; esac; done
echo "secret created"
STUB
chmod +x "$T/bin/kubectl"
export STUB_LOG="$T/log" KUBECTL="$T/bin/kubectl"
mk() { mkdir -p "$1"; echo SEED > "$1/$2.seed"; echo HYBRID > "$1/$2.hybrid"; chmod 600 "$1"/$2.*; }
refuse() { local label=$1 reason=$2; shift 2; local out rc; out=$("$S" "$@" 2>&1); rc=$?; [[ $rc -eq 2 && $out == *"$reason"* ]] && ok "refuses $label (exit 2)" || fail "$label: rc=$rc $out"; }
refuse "no arguments" "usage"
refuse "bank-c" "usage" bank-c "$T/x"
refuse "a missing dir" "not found" bank-a "$T/none"
mk "$T/a" bank-a-auditor
mk "$T/b" bi-auditor; rm "$T/b/bi-auditor.hybrid"
refuse "a missing file" "is missing" bi "$T/b"
mk "$T/c" bank-b-auditor; chmod 644 "$T/c/bank-b-auditor.seed"
refuse "a world-readable seed" "mode 600" bank-b "$T/c"
mk "$T/a2" bank-a-auditor
refuse "bank-a custody holding another org's names" "is missing" bank-b "$T/a2"
: > "$STUB_LOG"
out=$("$S" bank-a "$T/a" 2>&1); rc=$?
[[ $rc -eq 0 && $out == *"Secret bank-a-auditor-key created in rd-iroha3-bank-a"* ]] && ok "creates bank-a-auditor-key in rd-iroha3-bank-a" || fail "create: rc=$rc $out"
grep -q "create secret generic bank-a-auditor-key -n rd-iroha3-bank-a" "$STUB_LOG" && grep -q "FILE bank-a-auditor.seed" "$STUB_LOG" && grep -q "FILE bank-a-auditor.hybrid" "$STUB_LOG" && ok "plain create with exactly the two files" || fail "kubectl call: $(cat "$STUB_LOG")"
[[ $out != *SEED* && $out != *HYBRID* ]] && ok "prints no value" || fail "value printed"
if (( fails )); then echo "FAILED: $fails check(s)" >&2; exit 1; fi
echo "PASS"
