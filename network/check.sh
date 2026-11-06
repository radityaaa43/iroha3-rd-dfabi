#!/usr/bin/env bash
# Validate the generated network material. Exit != 0 on any failure.
# Prints key names/prefixes only, never private values.
set -uo pipefail

cd "$(dirname "$0")"
# NETWORK_OUT / NETWORK_PUB as in generate.sh (testing against a generate.sh run elsewhere)
PUB="$(realpath -m "${NETWORK_PUB:-public}")"
OUT="$(realpath -m "${NETWORK_OUT:-out}")"
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
  # trusted_peers: exactly 4 entries (all parties, self included, as localnet
  # emits), each exactly <peers.json key>@addr:<party dns>:1337#XXXX, in order.
  check "$p: trusted_peers = 4 exact key@dns:1337 pairs" \
    bash -c '
      line=$(grep -E "^trusted_peers = " "$1") || exit 1
      [[ $(grep -o "\"[^\"]*\"" <<<"$line" | wc -l) -eq 4 ]] || exit 1
      for q in bi bank-a bank-b bank-c; do
        k=$(jq -r --arg q "$q" ".[]|select(.party==\$q).public_key" "$2")
        [[ -n $k ]] || exit 1
        grep -Eq "\"${k}@addr:${q}-0\.${q}\.iroha3\.svc\.cluster\.local:1337#[0-9A-F]{4}\"" <<<"$line" || exit 1
      done' _ "$t" "$PUB/peers.json"
  check "$p: genesis file /genesis/genesis.signed.nrt" \
    grep -Fxq 'file = "/genesis/genesis.signed.nrt"' "$t"
  check "$p: kura store_dir under /storage" grep -Eq '^store_dir = "/storage(/|")' "$t"
  check "$p: no host paths or localhost left" \
    bash -c '! grep -Eq "/work/out|127\.0\.0\.1:[0-9]+|localhost" <(grep -Ev "cidrs" "$1")' _ "$t"
  check "$p: no dev faucet/onboarding/key-file references" \
    bash -c '! grep -Eq "^\[+(torii\.faucet|torii\.account_onboarding)|private_key_file" "$1"' _ "$t"
  check "$p: chain matches public/chain_id" \
    bash -c '[[ $(grep -m1 "^chain = " "$1") == "chain = \"$(tr -d "\n" < "$2")\"" ]]' _ "$t" "$PUB/chain_id"
  # first `public_key =` line is the top-level key (precedes every table);
  # later ones in [[trusted_peers_pop]] list all 4 parties and prove nothing.
  check "$p: top-level public_key is this party's key in peers.json" \
    bash -c '
      want=$(jq -r --arg p "$3" ".[]|select(.party==\$p).public_key" "$2")
      [[ -n $want ]] || exit 1
      [[ $(grep -m1 "^public_key = " "$1") == "public_key = \"$want\"" ]]' _ "$t" "$PUB/peers.json" "$p"
  if [[ -f $c ]]; then
    check "$p: client.toml has no sample [basic_auth]/mad_hatter" \
      bash -c '! grep -Eq "^\[basic_auth\]|mad_hatter" "$1"' _ "$c"
    check "$p: client.toml mode 0600" test "$(stat -c %a "$c")" = 600
    check "$p: client torii_url" \
      grep -Fxq "torii_url = \"http://$dns:8080/\"" "$c"
  fi
done

# --- Nexus lanes (G1b): exactly 3 lanes / dataspace ids 0,1,2 ---------------
# Upstream shape: nexus.lane_count, [[nexus.lane_catalog]] {index,alias,dataspace,visibility},
# [[nexus.dataspace_catalog]] {alias,id,fault_tolerance}. NEXUS overrides the path (fixtures).
# Only in aps mode (generated peer.toml carries [[nexus.lane_catalog]]); a non-aps network has no lanes.
NEXUS="${NEXUS:-nexus.toml}"
if grep -qs '^\[\[nexus\.lane_catalog\]\]' "$OUT"/*/peer.toml; then
check "$NEXUS: 3 lanes, dataspace ids 0,1,2 (universal public, ds-rd + ds-dfabi restricted)" \
  python3 -I -c '
import sys, tomllib
n = tomllib.load(open(sys.argv[1], "rb"))["nexus"]
lanes, dss = n["lane_catalog"], n["dataspace_catalog"]
assert n["lane_count"] == len(lanes) == len(dss) == 3
assert [l["index"] for l in lanes] == [0, 1, 2]
assert [d["id"] for d in dss] == [0, 1, 2]
assert [d["alias"] for d in dss] == ["universal", "ds-rd", "ds-dfabi"]
assert [l["dataspace"] for l in lanes] == [d["alias"] for d in dss]
assert [l["visibility"] for l in lanes] == ["public", "restricted", "restricted"]
' "$NEXUS"
# irohad InitKura refuses a custom lane catalog unless the signed genesis is NPoS
# (crates/irohad/src/main.rs, "custom Nexus lane topology requires ... to be NPoS").
# genesis.json records the mode as "consensus_mode": "Npos" / "Permissioned".
check "$OUT/genesis/genesis.json: consensus_mode is Npos (required by a custom lane catalog)" \
  jq -e '.consensus_mode == "Npos"' "$OUT/genesis/genesis.json"
# RD and DFABI are DataspaceRestricted, share one restricted home dataspace (domain wonderland.<ds>, alias <name>#wonderland.<ds>)
# and only BI, A and B (3 of the 4 party accounts) may read the restricted dataspaces: C, the outsider, gets 403 from Torii.
check "genesis.json: RD+DFABI DataspaceRestricted in one restricted dataspace; BI/A/B read every restricted dataspace, C none" \
  python3 -I -c '
import json, sys, tomllib
g = json.load(open(sys.argv[1]))
n = tomllib.load(open(sys.argv[2], "rb"))["nexus"]
ids = {d["alias"]: d["id"] for d in n["dataspace_catalog"]}
lanes = {l["dataspace"]: l["visibility"] for l in n["lane_catalog"]}
restricted = sorted(ids[a] for a, v in lanes.items() if v == "restricted")
ins = [i for t in g["transactions"] for i in t["instructions"] if isinstance(i, dict)]
defs = {d["name"]: d for i in ins if "Register" in i and "AssetDefinition" in i["Register"] for d in [i["Register"]["AssetDefinition"]] if d["name"] in ("RD", "DFABI")}
assert set(defs) == {"RD", "DFABI"}, defs.keys()
homes = {d["owning_domain"].split(".")[-1] for d in defs.values()}
assert len(homes) == 1 and lanes[homes.copy().pop()] == "restricted", homes
assert all(d["balance_scope_policy"] == "DataspaceRestricted" for d in defs.values())
home = homes.pop()
assert sum(1 for i in ins if "Register" in i and "Domain" in i["Register"] and i["Register"]["Domain"]["id"] == "wonderland." + home) == 1
aliases = {i["SetAssetDefinitionAlias"]["asset_definition_id"]: i["SetAssetDefinitionAlias"]["alias"] for i in ins if "SetAssetDefinitionAlias" in i}
for name, d in defs.items():
    assert aliases.get(d["id"]) == name.lower() + "#wonderland." + home, (name, aliases.get(d["id"]))
fee = n["fees"]["fee_asset_id"]
parties = {i["Mint"]["Asset"]["destination"].split("#")[1] for i in ins if "Mint" in i and i["Mint"]["Asset"]["destination"].startswith(fee + "#") and i["Mint"]["Asset"]["object"] == "1000"}
assert len(parties) == 4, parties
grants = [i["Grant"]["Permission"] for i in ins if "Grant" in i and i["Grant"]["Permission"]["object"]["name"] == "CanReadRestrictedDataspace"]
readers = {}
for p in grants: readers.setdefault(p["destination"], []).append(p["object"]["payload"]["dataspace"])
assert len(readers) == 3 and set(readers) < parties, readers.keys()
assert all(sorted(v) == restricted for v in readers.values()), readers.values()
' "$OUT/genesis/genesis.json" "$NEXUS"
# A genesis gas-accepted-assets parameter without node-config accepted_assets makes Torii quote
# a Nexus fee only while execution also requires a PipelineGas limit: every tx is Rejected.
check "genesis.json has no ivm_gas_accepted_assets unless peer.toml [pipeline.gas] sets accepted_assets" \
  bash -c 'jq -e "[.transactions[].parameters.custom // {} | has(\"ivm_gas_accepted_assets\")] | any | not" "$1" >/dev/null || grep -q "^accepted_assets" "${@:2}"' _ \
    "$OUT/genesis/genesis.json" "$OUT"/*/peer.toml
fi

# --- real-binary validation (verifies the #XXXX address checksums too) -------
# Output is suppressed: configs contain private keys. Only exit status is used.
IMAGE="${IMAGE:-ghcr.io/radityaaa43/iroha3-rd-node:071e281e-stark}"
if [[ -d $OUT ]] && command -v docker >/dev/null; then
  # /storage on a fresh tmpfs: iroha3d reserves 20% of the storage filesystem as
  # headroom (AUTO_STORAGE_HEADROOM_BPS), so a host disk over 80% full fails the check.
  for p in "${PARTIES[@]}"; do
    [[ -f $OUT/$p/peer.toml ]] || continue
    # aps peer.toml (custom lane_catalog) is rejected by iroha3d without --sora, as in the StatefulSet.
    sora=(); grep -q '^\[\[nexus\.lane_catalog\]\]' "$OUT/$p/peer.toml" && sora=(--sora)
    check "$p: iroha3d --check-config accepts peer.toml + signed genesis" \
      docker run --rm --user "$(id -u):$(id -g)" \
        -v "$OUT/$p/peer.toml:/config/peer.toml:ro" -v "$PUB:/genesis:ro" --tmpfs /storage:rw,size=2g,mode=1777 \
        --entrypoint iroha3d "$IMAGE" ${sora[@]+"${sora[@]}"} --check-config --config /config/peer.toml
  done
else
  fail "docker or network/out missing: cannot run iroha3d --check-config"
fi

if (( fails )); then
  echo "FAILED: $fails check(s)" >&2
  exit 1
fi
echo "PASS"
