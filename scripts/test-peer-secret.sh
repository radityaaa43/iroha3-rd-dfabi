#!/usr/bin/env bash
# Offline test of deploy/peers/peer-secret.sh with a STUB kubectl (no cluster, marker strings only, no real keys). Needs bash.
set -uo pipefail
cd "$(dirname "$0")/.."
S=$PWD/deploy/peers/peer-secret.sh
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
if [[ -n ${STUB_EXISTS:-} ]]; then echo 'Error from server (AlreadyExists): secrets "peer-bi" already exists' >&2; exit 1; fi
for a in "$@"; do case $a in --from-file=*) f=${a#--from-file=}; echo "FILE ${f%%=*} $(wc -c < "${f#*=}")" >> "$STUB_LOG" ;; esac; done
echo "secret/peer created"
STUB
chmod +x "$T/bin/kubectl"
export STUB_LOG="$T/log" KUBECTL="$T/bin/kubectl"
: > "$STUB_LOG"
mk() { # <dir>: good peer.toml (3 key names, marker values) + 32-byte seed, both mode 0600
  mkdir -p "$1"
  printf '%s\n' 'private_key = "PRIV-MARKER"' 'soranet_transport_private_key = "TRANSPORT-MARKER"' 'identity_private_key = "IDENT-MARKER"' 'chain = "x"' > "$1/peer.toml"
  head -c 32 /dev/zero | tr '\0' 'S' > "$1/mint-finality.seed"
  chmod 600 "$1/peer.toml" "$1/mint-finality.seed"
}
refuse() { # <label> <reason> <args...>
  local label=$1 reason=$2; shift 2
  local out rc; out=$("$S" "$@" 2>&1); rc=$?
  [[ $rc -eq 2 && $out == *"$reason"* ]] && ok "refuses $label (exit 2)" || fail "$label: rc=$rc $out"
  [[ -z $(cat "$STUB_LOG") ]] || fail "$label: kubectl was called: $(cat "$STUB_LOG")"
}
mk "$T/g"
for p in bi bank-a bank-b bank-c; do
  : > "$STUB_LOG"
  out=$("$S" $p "$T/g/peer.toml" "$T/g/mint-finality.seed" 2>&1); rc=$?
  [[ $rc -eq 0 ]] && ok "$p: creates the Secret" || fail "$p: rc=$rc $out"
  grep -q 'MARKER' <<<"$out" && fail "$p: secret values reached stdout/stderr"
  log=$(cat "$STUB_LOG")
  [[ $log == *"create secret generic peer-$p -n rd-iroha3-$p "* ]] && ok "$p: Secret peer-$p in rd-iroha3-$p" || fail "$p: name/namespace: $log"
  [[ $log == *"FILE peer.toml "* && $log == *"FILE mint-finality.seed 32"* ]] && ok "$p: keys peer.toml and mint-finality.seed" || fail "$p: key names: $log"
  [[ $(grep -c '^kubectl' <<<"$log") -eq 1 && $log != *apply* && $log != *replace* && $log != *dry-run* ]] && ok "$p: one plain create call" || fail "$p: verbs: $log"
done
: > "$STUB_LOG"; out=$(STUB_EXISTS=1 "$S" bi "$T/g/peer.toml" "$T/g/mint-finality.seed" 2>&1); rc=$?
[[ $rc -ne 0 && $out == *AlreadyExists* ]] && ok "re-run fails with AlreadyExists (safe, never overwrites)" || fail "re-run: rc=$rc $out"
[[ $(cat "$STUB_LOG") != *apply* && $(cat "$STUB_LOG") != *replace* && $(grep -c '^kubectl' "$STUB_LOG") -eq 1 ]] && ok "re-run does not fall back to apply/replace" || fail "re-run log: $(cat "$STUB_LOG")"
: > "$STUB_LOG"
refuse "no argument" "usage"
refuse "two arguments" "usage" bi "$T/g/peer.toml"
refuse "an unknown party" "unknown party" nobody "$T/g/peer.toml" "$T/g/mint-finality.seed"
refuse "a missing peer.toml" "is missing" bi "$T/none.toml" "$T/g/mint-finality.seed"
refuse "a missing seed" "is missing" bi "$T/g/peer.toml" "$T/none.seed"
mk "$T/m1"; chmod 644 "$T/m1/peer.toml"; refuse "a world-readable peer.toml" "mode 600" bi "$T/m1/peer.toml" "$T/m1/mint-finality.seed"
mk "$T/m2"; chmod 640 "$T/m2/mint-finality.seed"; refuse "a group-readable seed" "mode 600" bi "$T/m2/peer.toml" "$T/m2/mint-finality.seed"
mk "$T/s1"; head -c 31 /dev/zero > "$T/s1/mint-finality.seed"; refuse "a 31-byte seed" "32 bytes" bi "$T/s1/peer.toml" "$T/s1/mint-finality.seed"
mk "$T/s2"; head -c 33 /dev/zero > "$T/s2/mint-finality.seed"; refuse "a 33-byte seed" "32 bytes" bi "$T/s2/peer.toml" "$T/s2/mint-finality.seed"
mkdir -p "$T/repo/.git"; mk "$T/repo/c"; refuse "files inside a git checkout" "git checkout" bi "$T/repo/c/peer.toml" "$T/repo/c/mint-finality.seed"
mk "$T/r1"; mkdir -p "$T/repo/d"; cp -p "$T/r1/peer.toml" "$T/repo/d/"; refuse "peer.toml alone inside a git checkout" "git checkout" bi "$T/repo/d/peer.toml" "$T/r1/mint-finality.seed"
mk "$T/r2"; cp -p "$T/r2/mint-finality.seed" "$T/repo/d/"; refuse "the seed alone inside a git checkout" "git checkout" bi "$T/r2/peer.toml" "$T/repo/d/mint-finality.seed"
for k in private_key soranet_transport_private_key identity_private_key; do
  mk "$T/k-$k"; grep -v "^$k = " "$T/k-$k/peer.toml" > "$T/k-$k/x"; cat "$T/k-$k/x" > "$T/k-$k/peer.toml"; rm "$T/k-$k/x"
  refuse "a peer.toml without $k" "lacks key $k" bi "$T/k-$k/peer.toml" "$T/k-$k/mint-finality.seed"
done
mk "$T/p"; echo 'public_address = "@PEER_HOST@:1337"' >> "$T/p/peer.toml"; refuse "a peer.toml with an @...@ placeholder" "placeholder" bi "$T/p/peer.toml" "$T/p/mint-finality.seed"
if (( fails )); then echo "FAILED: $fails check(s)" >&2; exit 1; fi
echo "PASS"
