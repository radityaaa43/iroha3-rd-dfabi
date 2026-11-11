#!/usr/bin/env bash
# Offline test of deploy/driver/keys-secret.sh with a STUB kubectl (no cluster, marker strings only, no real keys). Needs bash.
set -uo pipefail
cd "$(dirname "$0")/.."
S=$PWD/deploy/driver/keys-secret.sh
T=$(mktemp -d); trap 'rm -r -- "$T"' EXIT
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
if [[ -n ${STUB_EXISTS:-} ]]; then echo 'Error from server (AlreadyExists): secrets "bi-keys" already exists' >&2; exit 1; fi
for a in "$@"; do case $a in --from-file=*) f=${a#--from-file=}; echo "FILE ${f%%=*} $(wc -c < "${f#*=}")" >> "$STUB_LOG" ;; esac; done
echo "secret created"
STUB
chmod +x "$T/bin/kubectl"
export STUB_LOG="$T/log" KUBECTL="$T/bin/kubectl"
: > "$STUB_LOG"
mk() { # <dir> <party>: good custody (seed 64 hex, note 128 hex, client.toml with key names and marker values), all 0600
  mkdir -p "$1"
  printf '%064x' 7 > "$1/$2.seed"; printf '%0128x' 9 > "$1/$2.note"
  printf '%s\n' 'chain = "x"' '[account]' 'private_key = "PRIV-MARKER"' 'public_key = "ed0120PUB"' > "$1/client.toml"
  chmod 600 "$1/$2.seed" "$1/$2.note" "$1/client.toml"
}
refuse() { # <label> <expected message part> <args...>
  local label=$1 part=$2; shift 2
  local out rc; out=$("$S" "$@" 2>&1); rc=$?
  [[ $rc -eq 2 && $out == *"$part"* ]] && ok "refuses $label (exit 2)" || fail "$label: rc=$rc $out"
  [[ -z $(cat "$STUB_LOG") ]] || fail "$label: kubectl was called: $(cat "$STUB_LOG")"
}
for p in bi bank-a bank-b bank-c; do
  : > "$STUB_LOG"; mk "$T/c-$p" $p
  out=$("$S" $p "$T/c-$p" 2>&1); rc=$?
  [[ $rc -eq 0 ]] && ok "$p: creates the Secret" || fail "$p: rc=$rc $out"
  grep -q 'MARKER' <<<"$out" && fail "$p: secret values reached stdout/stderr"
  log=$(cat "$STUB_LOG")
  [[ $log == *"create secret generic $p-keys -n rd-iroha3-$p "* ]] && ok "$p: Secret $p-keys in rd-iroha3-$p" || fail "$p: name/namespace: $log"
  [[ $log == *"FILE $p.seed 64"* && $log == *"FILE $p.note 128"* && $log == *"FILE client.toml "* ]] && ok "$p: keys $p.seed, $p.note, client.toml" || fail "$p: key names: $log"
  [[ $(grep -c '^kubectl' <<<"$log") -eq 1 && $log != *apply* && $log != *replace* && $log != *dry-run* ]] && ok "$p: one plain create call" || fail "$p: verbs: $log"
done
: > "$STUB_LOG"; out=$(STUB_EXISTS=1 "$S" bi "$T/c-bi" 2>&1); rc=$?
[[ $rc -ne 0 && $out == *AlreadyExists* ]] && ok "re-run fails with AlreadyExists (safe, never overwrites)" || fail "re-run: rc=$rc $out"
[[ $(grep -c '^kubectl' "$STUB_LOG") -eq 1 && $(cat "$STUB_LOG") != *apply* && $(cat "$STUB_LOG") != *replace* ]] && ok "re-run does not fall back to apply/replace" || fail "re-run log: $(cat "$STUB_LOG")"
: > "$STUB_LOG"
refuse "no argument" "usage"
refuse "an unknown party" "unknown party" nobody "$T/c-bi"
refuse "a missing custody dir" "not found" bi "$T/none"
mk "$T/m0" bi; rm "$T/m0/bi.note"; refuse "a missing note" "is missing" bi "$T/m0"
mk "$T/m1" bi; chmod 644 "$T/m1/bi.seed"; refuse "a world-readable seed" "mode 600" bi "$T/m1"
mk "$T/m2" bi; chmod 640 "$T/m2/client.toml"; refuse "a group-readable client.toml" "mode 600" bi "$T/m2"
mk "$T/s1" bi; printf '%063x' 7 > "$T/s1/bi.seed"; chmod 600 "$T/s1/bi.seed"; refuse "a 63-char seed" "64 hex" bi "$T/s1"
mk "$T/s2" bi; printf 'zz%062x' 7 > "$T/s2/bi.seed"; chmod 600 "$T/s2/bi.seed"; refuse "a non-hex seed" "64 hex" bi "$T/s2"
mk "$T/n1" bi; printf '%0127x' 9 > "$T/n1/bi.note"; chmod 600 "$T/n1/bi.note"; refuse "a 127-char note" "128 hex" bi "$T/n1"
mk "$T/t1" bi; printf '%s\n' 'chain = "x"' '[account]' 'public_key = "ed0120PUB"' > "$T/t1/client.toml"; chmod 600 "$T/t1/client.toml"; refuse "a client.toml without a private_key" "private_key" bi "$T/t1"
mk "$T/t2" bi; printf '%s\n' '[account]' 'private_key = "@KEY@"' > "$T/t2/client.toml"; chmod 600 "$T/t2/client.toml"; refuse "a client.toml with a placeholder" "placeholder" bi "$T/t2"
mkdir -p "$T/repo/.git"; mk "$T/repo/c" bi; refuse "a custody dir inside a git checkout" "git checkout" bi "$T/repo/c"
if (( fails )); then echo "FAILED: $fails check(s)" >&2; exit 1; fi
echo "PASS"
