#!/usr/bin/env bash
# Validate the generated network material. Exit != 0 on any failure.
# Prints key names/prefixes only, never private values.
set -uo pipefail

cd "$(dirname "$0")"
PUB=public
OUT=out
PARTIES=(bi bank-a bank-b bank-c)
fails=0

fail() { echo "FAIL: $*" >&2; fails=$((fails + 1)); }
ok() { echo "ok:   $*"; }
check() { # check "<description>" <command...>
  local d="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$d"; else fail "$d"; fi
}

# --- public bundle ---------------------------------------------------------
for f in genesis.signed.nrt genesis.public_key genesis.expected_hash peers.json chain_id; do
  check "public/$f exists and is non-empty" test -s "$PUB/$f"
done

if [[ -s $PUB/peers.json ]]; then
  check "peers.json: exactly 4 entries" \
    jq -e 'type == "array" and length == 4' "$PUB/peers.json"
  check "peers.json: party order bi, bank-a, bank-b, bank-c" \
    jq -e '[.[].party] == ["bi","bank-a","bank-b","bank-c"]' "$PUB/peers.json"
  check "peers.json: public_key starts with ea0130" \
    jq -e 'all(.[]; (.public_key | type == "string") and (.public_key | startswith("ea0130")))' "$PUB/peers.json"
  check "peers.json: pop_hex non-empty" \
    jq -e 'all(.[]; (.pop_hex | type == "string") and (.pop_hex | length > 2))' "$PUB/peers.json"
  check "peers.json: no duplicate public_key or pop_hex" \
    jq -e '([.[].public_key] | unique | length) == 4 and ([.[].pop_hex] | unique | length) == 4' "$PUB/peers.json"
fi

if [[ -s $PUB/genesis.expected_hash ]]; then
  check "genesis.expected_hash: one line ending in LF" \
    bash -c '[[ $(wc -l < "$1") -eq 1 && $(tail -c1 "$1" | xxd -p) == 0a ]]' _ "$PUB/genesis.expected_hash"
  check "genesis.expected_hash: matches hash format" \
    grep -Eqx 'hash:[0-9A-F]{63}[13579BDF]#[0-9A-F]{4}' "$PUB/genesis.expected_hash"
fi

check "genesis.public_key starts with ed0120" \
  grep -q '^ed0120' "$PUB/genesis.public_key"

if [[ -s $PUB/chain_id ]]; then
  check "chain_id is not the all-zero sample" \
    bash -c '[[ $(tr -d "\n" < "$1") != 00000000-0000-0000-0000-000000000000 ]]' _ "$PUB/chain_id"
  check "chain_id is a UUID" \
    grep -Eqx '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' "$PUB/chain_id"
fi

if grep -rqi 'private_key' "$PUB" 2>/dev/null; then
  fail "private_key string found in public/"
else
  ok "no private_key string in public/"
fi

# --- per-party operator material (container form) --------------------------
if [[ ! -d $OUT ]]; then
  fail "network/out missing (run generate.sh)"
fi
for p in "${PARTIES[@]}"; do
  t="$OUT/$p/peer.toml"
  c="$OUT/$p/client.toml"
  dns="$p-0.$p.iroha3.svc.cluster.local"
  [[ -f $t ]] || { fail "$t missing"; continue; }
  [[ -f $c ]] || fail "$c missing"
  check "$p: peer.toml mode 0600" test "$(stat -c %a "$t")" = 600
  check "$p: P2P bind 0.0.0.0:1337" grep -Eq '^address = "addr:0\.0\.0\.0:1337#[0-9A-F]{4}"$' "$t"
  check "$p: Torii bind 0.0.0.0:8080" grep -Eq '^address = "addr:0\.0\.0\.0:8080#[0-9A-F]{4}"$' "$t"
  check "$p: public_address $dns:1337" \
    grep -Eq "^public_address = \"addr:${dns//./\\.}:1337#[0-9A-F]{4}\"$" "$t"
  check "$p: trusted_peers use DNS names of all 4 parties" \
    bash -c 'for q in bi bank-a bank-b bank-c; do grep -E "^trusted_peers = " "$1" | grep -q "@addr:$q-0\.$q\.iroha3\.svc\.cluster\.local:1337#" || exit 1; done' _ "$t"
  check "$p: genesis file /genesis/genesis.signed.nrt" \
    grep -Fxq 'file = "/genesis/genesis.signed.nrt"' "$t"
  check "$p: kura store_dir under /storage" grep -Eq '^store_dir = "/storage(/|")' "$t"
  check "$p: no host paths or localhost left" \
    bash -c '! grep -Eq "/work/out|127\.0\.0\.1:[0-9]+|localhost" <(grep -Ev "cidrs" "$1")' _ "$t"
  check "$p: no dev faucet/onboarding/key-file references" \
    bash -c '! grep -Eq "^\[+(torii\.faucet|torii\.account_onboarding)|private_key_file" "$1"' _ "$t"
  check "$p: chain matches public/chain_id" \
    bash -c '[[ $(grep -m1 "^chain = " "$1") == "chain = \"$(tr -d "\n" < "$2")\"" ]]' _ "$t" "$PUB/chain_id"
  check "$p: peer public_key matches peers.json" \
    bash -c 'grep -Fxq "public_key = \"$(jq -r --arg p "$3" ".[]|select(.party==\$p).public_key" "$2")\"" "$1"' _ "$t" "$PUB/peers.json" "$p"
  if [[ -f $c ]]; then
    check "$p: client.toml mode 0600" test "$(stat -c %a "$c")" = 600
    check "$p: client torii_url" \
      grep -Fxq "torii_url = \"http://$dns:8080/\"" "$c"
  fi
done

if (( fails )); then
  echo "FAILED: $fails check(s)" >&2
  exit 1
fi
echo "PASS"
