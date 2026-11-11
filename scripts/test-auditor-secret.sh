#!/usr/bin/env bash
# Offline test of deploy/ns/auditor-secret.sh with a STUB kubectl (no cluster, no real keys). Needs bash, jq.
set -uo pipefail
cd "$(dirname "$0")/.."
S=deploy/ns/auditor-secret.sh
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fails=0
fail() { echo "FAIL: $*" >&2; fails=$((fails + 1)); }
ok() { echo "ok:   $*"; }
mkdir "$T/bin"
cat > "$T/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
# party-admin Role: secrets create/update/patch only. No get, so `apply` and `--dry-run` GET paths are Forbidden.
echo "kubectl $*" >> "$STUB_LOG"
if [[ $1 != create ]]; then echo "Error from server (Forbidden): verb $1 on secrets is not allowed" >&2; exit 1; fi
for a in "$@"; do [[ $a == --dry-run* ]] && { echo "Error from server (Forbidden): --dry-run not allowed in this test" >&2; exit 1; }; done
if [[ -n ${STUB_EXISTS:-} ]]; then echo 'Error from server (AlreadyExists): secrets "bi-auditor-key" already exists' >&2; exit 1; fi
for a in "$@"; do case $a in --from-file=*) f=${a#--from-file=}; echo "FILE ${f%%=*} $(wc -c < "${f#*=}")" >> "$STUB_LOG" ;; esac; done
echo "secret/bi-auditor-key created"
STUB
chmod +x "$T/bin/kubectl"
export STUB_LOG="$T/log" KUBECTL="$T/bin/kubectl"
: > "$STUB_LOG"
mk() { # <dir>: custody with both files, mode 0600
  mkdir -p "$1"; echo "SEED-MARKER" > "$1/bi-auditor.seed"; echo "HYBRID-MARKER" > "$1/bi-auditor.hybrid"; chmod 600 "$1"/bi-auditor.*
}
refuse() { # <label> <reason> <args...>
  local label=$1 reason=$2; shift 2
  local out rc; out=$("$S" "$@" 2>&1); rc=$?
  [[ $rc -eq 2 && $out == *"$reason"* ]] && ok "refuses $label (exit 2)" || fail "$label: rc=$rc $out"
}
mk "$T/c"
out=$("$S" "$T/c" 2>&1); rc=$?
[[ $rc -eq 0 ]] && ok "creates the Secret from a good custody dir" || fail "good dir: rc=$rc $out"
grep -q 'MARKER' <<<"$out" && fail "secret values reached stdout/stderr"
log=$(cat "$STUB_LOG")
[[ $log == *"create secret generic bi-auditor-key"* && $log == *"-n rd-iroha3-bi"* ]] && ok "Secret bi-auditor-key in rd-iroha3-bi" || fail "secret name/namespace: $log"
[[ $log == *"FILE bi-auditor.seed "* && $log == *"FILE bi-auditor.hybrid "* ]] && ok "keys bi-auditor.seed and bi-auditor.hybrid" || fail "key names: $log"
[[ $(grep -c 'rd-iroha3-' <<<"$log" | head -1) -ge 1 && $log != *"rd-iroha3-bank"* && $log != *"-n iroha3"* ]] && ok "no other namespace touched" || fail "other namespace in: $log"
[[ $(grep -c '^kubectl' <<<"$log") -eq 1 && $log != *apply* && $log != *replace* && $log != *dry-run* ]] && ok "one plain create call, no apply/replace/dry-run" || fail "verbs: $log"
: > "$STUB_LOG"; out=$(STUB_EXISTS=1 "$S" "$T/c" 2>&1); rc=$?
[[ $rc -ne 0 && $out == *AlreadyExists* ]] && ok "re-run fails with AlreadyExists (safe, never overwrites)" || fail "re-run: rc=$rc $out"
[[ $(cat "$STUB_LOG") != *apply* && $(cat "$STUB_LOG") != *replace* ]] && ok "re-run does not fall back to apply/replace" || fail "re-run log: $(cat "$STUB_LOG")"
refuse "no argument" "usage"
refuse "a missing custody dir" "custody" "$T/none"
mk "$T/d1"; rm "$T/d1/bi-auditor.hybrid"; refuse "a missing hybrid key" "bi-auditor.hybrid" "$T/d1"
mk "$T/d2"; chmod 644 "$T/d2/bi-auditor.seed"; refuse "a world-readable seed" "mode" "$T/d2"
mkdir -p "$T/repo/.git"; mk "$T/repo/custody"; refuse "a custody dir inside a git checkout" "git" "$T/repo/custody"
if (( fails )); then echo "FAILED: $fails check(s)" >&2; exit 1; fi
echo "PASS"
