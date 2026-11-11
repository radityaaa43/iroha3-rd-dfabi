#!/usr/bin/env bash
# Offline test of network/keygen-party.sh and network/assemble.sh with STUB kagami and rd-dfabi (no docker, no cluster,
# no real keys). It checks the plumbing only: which commands and flags run, what is printed, which inputs are
# required, what is refused. The real kagami behaviour is settled by .github/workflows/genesis-probe.yml.
# Needs bash, jq. Exit != 0 on any failure.
set -uo pipefail
cd "$(dirname "$0")/.."
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fails=0
fail() { echo "FAIL: $*" >&2; fails=$((fails + 1)); }
ok() { echo "ok:   $*"; }

# ---- stubs: record argv, write the files the real tools write, print what they print
mkdir "$T/bin"
cat > "$T/bin/kagami" <<'STUB'
#!/usr/bin/env bash
echo "kagami $*" >> "$STUB_LOG"
case "$1 $2" in
  "keys --algorithm")
    out=""; while [[ $# -gt 0 ]]; do [[ $1 == --out-dir ]] && out=$2; shift; done
    mkdir -m 700 "$out"; echo "PUB-$(basename "$out")" > "$out/public.key"; echo "PRIVATE-MARKER-$(basename "$out")" > "$out/private.key"
    chmod 600 "$out/private.key"; echo "POP-$(basename "$out")" > "$out/pop.hex"; echo "generated keys in $out" ;;
  "genesis generate") echo '{"transactions":[]}' ;;
  "genesis sign")
    while [[ $# -gt 0 ]]; do case $1 in --out-file) echo signed > "$2" ;; --expected-hash-out) echo "hash:STUB" > "$2" ;; esac; shift; done ;;
esac
STUB
cat > "$T/bin/rd-dfabi" <<'STUB'
#!/usr/bin/env bash
echo "rd-dfabi $*" >> "$STUB_LOG"
case "$1 $2" in
  "keys new") echo "SEED-MARKER" > "$3/$4.seed"; chmod 600 "$3/$4.seed"; echo "$4 ed0120PUB$4" ;;
  "keys new-note") echo "NOTE-MARKER" > "$3/$4.note"; chmod 600 "$3/$4.note"; echo "$4 note keys written to $3/$4.note" ;;
  "keys mint-finality") echo '{"stub":"mint-finality-triple"}' ;; # public triple: keygen-party.sh embeds it as JSON (S5)
esac
STUB
chmod +x "$T/bin/kagami" "$T/bin/rd-dfabi"
export STUB_LOG="$T/log" KAGAMI="$T/bin/kagami" RDDFABI="$T/bin/rd-dfabi"
: > "$STUB_LOG"

# ---- keygen-party.sh
for p in bi bank-a bank-b bank-c; do
  c="$T/custody-$p"
  out=$(network/keygen-party.sh "$p" "$c" 2>"$T/err") || { fail "keygen $p failed: $(cat "$T/err")"; continue; }
  if [[ $(wc -l <<<"$out") -eq 1 ]] && jq -e --arg p "$p" '.party == $p and (.public_key|startswith("PUB-")) and (.pop_hex|startswith("POP-")) and (.account_public_key|startswith("ed0120"))' <<<"$out" >/dev/null; then
    ok "keygen $p prints one JSON line of public values"
  else
    fail "keygen $p stdout: $out"
  fi
  grep -q 'MARKER' <<<"$out$(cat "$T/err")" && fail "keygen $p printed secret material"
  [[ $(stat -c %a "$c") == 700 ]] && ok "keygen $p custody dir is 0700" || fail "keygen $p custody dir mode $(stat -c %a "$c")"
  [[ -f $c/$p.seed && -f $c/$p.note ]] || fail "keygen $p: seed or note missing in custody"
done
if jq -e '.gov_account_public_key|startswith("ed0120")' <<<"$(network/keygen-party.sh bi "$T/custody-bi2" 2>/dev/null)" >/dev/null; then ok "bi also gets bi-gov"; else fail "bi output lacks gov_account_public_key"; fi
if network/keygen-party.sh bank-a "$T/custody-bank-a" >/dev/null 2>&1; then fail "keygen reused a non-empty custody dir"; else ok "keygen refuses an existing custody dir"; fi
if network/keygen-party.sh nobody "$T/custody-x" >/dev/null 2>&1; then fail "keygen accepted an unknown party"; else ok "keygen refuses an unknown party"; fi

# ---- assemble.sh fixtures: PUBLIC ONLY
P="$T/public"; mkdir "$P"
jq -n '[ "bi","bank-a","bank-b","bank-c" | {party: ., public_key: ("PUB-validator-" + .), pop_hex: ("POP-validator-" + .)} ]' > "$P/peers.json"
jq -n '[ "bi","bank-a","bank-b","bank-c" ] | map({(.): {dns: (. + "-0." + . + ".rd-iroha3-" + . + ".svc.cluster.local:1337"), external: "203.0.113.10:1337"}}) | add' > "$P/peers.addr.json"
jq -n '{bi:"ed0120PUBbi","bi-gov":"ed0120PUBgov","bank-a":"ed0120PUBa","bank-b":"ed0120PUBb","bank-c":"ed0120PUBc"}' > "$P/accounts.json"
echo '{"stub":"params"}' > "$P/kagemusha-mint-finality-public.json"
echo "SIGNER-PRIVATE-MARKER" > "$T/signer.key"; chmod 600 "$T/signer.key"
run() { # <VAR=value ...> : run assemble.sh into a fresh OUT dir; later assignments win
  rm -rf "$T/out"; : > "$STUB_LOG"
  env PUBLIC_DIR="$P" OUT_DIR="$T/out" GENESIS_PRIVATE_KEY_FILE="$T/signer.key" GENESIS_PUBLIC_KEY=PUB-genesis ASSEMBLE_ACCEPT_GAP=1 "$@" network/assemble.sh >"$T/aout" 2>&1
}
if run; then ok "assemble.sh runs on public inputs"; else fail "assemble.sh failed: $(cat "$T/aout")"; fi
sign=$(grep '^kagami genesis sign' "$STUB_LOG" || true); gen=$(grep '^kagami genesis generate' "$STUB_LOG" || true)
for f in --topology --private-key-file --expected-public-key --out-file --expected-hash-out; do [[ $sign == *"$f"* ]] || fail "genesis sign lacks $f"; done
if [[ $(grep -o -- '--peer-pop' <<<"$sign" | wc -l) -eq 4 ]]; then ok "genesis sign gets 4 --peer-pop"; else fail "genesis sign --peer-pop count: $sign"; fi
[[ $sign == *"--peer-pop PUB-validator-bi=POP-validator-bi"* ]] || fail "peer-pop is not PK=POP"
# probe log (genesis-probe run 43006538345): `--topology` is "JSON-serialized vector of PeerId", the PoPs travel in --peer-pop
topo=$(sed -E 's/.*--topology ([^ ]+) .*/\1/' <<<"$sign")
if jq -e 'type == "array" and all(type == "string") and (sort == ["PUB-validator-bank-a","PUB-validator-bank-b","PUB-validator-bank-c","PUB-validator-bi"])' <<<"$topo" >/dev/null 2>&1; then
  ok "--topology is a vector of the 4 public keys (no pop objects)"
else
  fail "--topology shape: $topo"
fi
if [[ $gen == *"--kagemusha-mint-finality-parameters"* && $gen == *"--genesis-public-key PUB-genesis"* ]]; then ok "genesis generate gets the mint-finality parameters and the genesis public key"; else fail "generate args: $gen"; fi
if [[ -s $T/out/genesis.signed.nrt && -s $T/out/genesis.expected_hash ]]; then ok "outputs: genesis.signed.nrt, genesis.expected_hash"; else fail "outputs missing in $T/out"; fi
if grep -rl 'PRIVATE-MARKER' "$T/out" "$T/aout" >/dev/null 2>&1; then fail "private key material reached the output dir or stdout"; fi
if [[ ! -e network/out ]]; then ok "no network/out created"; else fail "network/out exists"; fi

rm -rf "$T/out"
env PUBLIC_DIR="$P" OUT_DIR="$T/out" GENESIS_PRIVATE_KEY_FILE="$T/signer.key" GENESIS_PUBLIC_KEY=PUB-genesis network/assemble.sh >"$T/aout" 2>&1; rc=$?
if [[ $rc -eq 3 && $(cat "$T/aout") == *GAP* ]]; then ok "refuses without ASSEMBLE_ACCEPT_GAP (lane-validator overlay not ported)"; else fail "gap guard: rc=$rc $(cat "$T/aout")"; fi

refuse() { # <label> <reason substring in assemble.sh's own message> <mutation run inside the public dir>
  local label=$1 reason=$2; shift 2
  cp -r "$P" "$T/public.bak"; (cd "$P" && eval "$*")
  run; local rc=$?
  rm -rf "$P"; mv "$T/public.bak" "$P"
  if [[ $rc -eq 2 && $(cat "$T/aout") == *"$reason"* ]]; then ok "refuses: $label"; else fail "not refused as expected: $label (rc=$rc: $(head -c 200 "$T/aout"))"; fi
}
refuse "missing peers.addr.json" "peers.addr.json" 'rm peers.addr.json'
refuse "3 peers instead of 4" "4 peers" 'jq "del(.[3])" peers.json > x && mv x peers.json'
refuse "a peer without pop_hex" "pop_hex" 'jq ".[0].pop_hex=\"\"" peers.json > x && mv x peers.json'
refuse "bank-c without external address" "external" 'jq "del(.\"bank-c\".external)" peers.addr.json > x && mv x peers.addr.json'
refuse "missing bi-gov account" "bi-gov" 'jq "del(.\"bi-gov\")" accounts.json > x && mv x accounts.json'
refuse "missing mint-finality parameters" "mint-finality" 'rm kagemusha-mint-finality-public.json'
refuse "a seed file in the public dir" "secret" 'echo x > bi.seed'
refuse "a private.key in the public dir" "secret" 'echo x > private.key'
run GENESIS_PRIVATE_KEY_FILE=/nonexistent; rc=$?
if [[ $rc -eq 2 && $(cat "$T/aout") == *GENESIS_PRIVATE_KEY_FILE* ]]; then ok "refuses a missing signer key file"; else fail "signer key: rc=$rc $(cat "$T/aout")"; fi
run GENESIS_PUBLIC_KEY=; rc=$?
if [[ $rc -eq 2 && $(cat "$T/aout") == *GENESIS_PUBLIC_KEY* ]]; then ok "refuses an empty GENESIS_PUBLIC_KEY"; else fail "public key: rc=$rc $(cat "$T/aout")"; fi

if (( fails )); then echo "FAILED: $fails check(s)" >&2; exit 1; fi
echo "PASS"
