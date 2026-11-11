#!/usr/bin/env bash
# S5: assemble and sign the NEW chain's genesis from PUBLIC per-org data only (iroha3 PLAN S5/S5b, DELTA 2 + 1b/1d).
# One signer runs this once; the genesis private key is a file path (never printed) and must be destroyed afterwards.
#   Inputs in $PUBLIC_DIR (default network/public): peers.json [{party,public_key,pop_hex}] x4, accounts.json
#     {bi,"bi-gov",bank-a,bank-b,bank-c} -> account PUBLIC keys, kagemusha-mint-finality-public.json (from `rd-dfabi keys
#     mint-finality-roster`). No seed, note, hybrid or private key may be in $PUBLIC_DIR (refused).
#   Env: GENESIS_PRIVATE_KEY_FILE, GENESIS_PUBLIC_KEY (required); KAGAMI, IROHA (default kagami, iroha; wrappers must see the
#     same absolute paths); OUT_DIR (default $PUBLIC_DIR); EPOCH_LENGTH (default 1152921504606846976 = 2^60, user decision
#     "iroha iii", below u64::MAX/3); CHAIN_ID (default fresh uuid); KEEP_MANIFEST=<file> also writes the unsigned manifest.
#   Outputs in $OUT_DIR: genesis.signed.nrt, genesis.expected_hash, genesis.public_key, chain_id, peer.template.toml (public).
# The base content comes from a THROWAWAY `kagami localnet` (upstream's own bootstrap: fee asset, stake asset, fee sponsor,
# aliases, lane-0 validators). Every key it makes is replaced by the orgs' public values and is deleted on exit (network/s5.py).
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
PUBLIC_DIR=${PUBLIC_DIR:-$here/public}
OUT_DIR=${OUT_DIR:-$PUBLIC_DIR}
KAGAMI=${KAGAMI:-kagami}
IROHA=${IROHA:-iroha}
EPOCH_LENGTH=${EPOCH_LENGTH:-1152921504606846976}
die() { echo "assemble-s5.sh: $*" >&2; exit 2; }

[[ -n ${GENESIS_PRIVATE_KEY_FILE:-} && -f ${GENESIS_PRIVATE_KEY_FILE} ]] || die "GENESIS_PRIVATE_KEY_FILE must name an existing file"
[[ -n ${GENESIS_PUBLIC_KEY:-} ]] || die "GENESIS_PUBLIC_KEY must be set (the expected public key of the signer)"
[[ $EPOCH_LENGTH =~ ^[1-9][0-9]*$ ]] && (( ${#EPOCH_LENGTH} < 19 || ( ${#EPOCH_LENGTH} == 19 && $EPOCH_LENGTH < 6148914691236517205 ) )) \
  || die "EPOCH_LENGTH must be a positive integer below u64::MAX/3 = 6148914691236517205 (iroha_data_model parameter/system.rs:538-542)"
[[ -z $(find "$PUBLIC_DIR" -type f \( -name '*.seed' -o -name '*.note' -o -name '*.hybrid' -o -name 'private.key' \) 2>/dev/null) ]] \
  || die "secret material (*.seed, *.note, *.hybrid, private.key) found in $PUBLIC_DIR; keep it in the org's custody"
peers=$PUBLIC_DIR/peers.json accts=$PUBLIC_DIR/accounts.json params=$PUBLIC_DIR/kagemusha-mint-finality-public.json
[[ -f $peers ]] || die "$peers is missing"
[[ $(jq 'length' "$peers") -eq 4 ]] || die "peers.json must list exactly 4 peers (3f+1 committee)"
[[ $(jq -r '[.[].party] | sort | join(",")' "$peers") == "bank-a,bank-b,bank-c,bi" ]] || die "peers.json parties must be bi, bank-a, bank-b, bank-c"
[[ $(jq '[.[] | select((.public_key // "") == "" or (.pop_hex // "") == "")] | length' "$peers") -eq 0 ]] || die "every peer needs public_key and a non-empty pop_hex"
[[ -f $accts ]] || die "$accts is missing"
for a in bi bi-gov bank-a bank-b bank-c; do
  [[ $(jq -r --arg a "$a" '.[$a] // ""' "$accts") != "" ]] || die "accounts.json lacks the public key of $a"
done
[[ -f $params ]] || die "$params is missing (public KAGEMUSHA mint-finality parameters)"

tmp=$(mktemp -d); chmod 700 "$tmp"; trap '[[ -n ${KEEP_TMP:-} ]] || rm -rf "$tmp"' EXIT # KEEP_TMP=1 only for debugging with throwaway keys
chain=${CHAIN_ID:-$(uuidgen | tr 'A-Z' 'a-z')}
[[ $chain =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || die "CHAIN_ID is not a uuid"

# 1. throwaway localnet (template only)
"$KAGAMI" localnet --peers 4 --consensus-mode npos --chain-id "$chain" --out-dir "$tmp/ln" >/dev/null

# 2. account ids (I105) of the real keys and of the template's genesis/client accounts
conv() { "$IROHA" tools address convert "$1" | tail -1; }
old_client_pk=$(sed -n 's/^public_key *= *"\(.*\)"/\1/p' "$tmp/ln/client.toml" | head -1)
jq -n --arg og "$(conv "$(tr -d '\n' < "$tmp/ln/genesis.public_key")")" --arg oc "$(conv "$old_client_pk")" --arg g "$(conv "$GENESIS_PUBLIC_KEY")" \
  --arg bi "$(conv "$(jq -r '.bi' "$accts")")" --arg gov "$(conv "$(jq -r '."bi-gov"' "$accts")")" \
  --arg a "$(conv "$(jq -r '."bank-a"' "$accts")")" --arg b "$(conv "$(jq -r '."bank-b"' "$accts")")" --arg c "$(conv "$(jq -r '."bank-c"' "$accts")")" \
  '{old_gen:$og, old_client:$oc, gen:$g, bi:$bi, "bi-gov":$gov, "bank-a":$a, "bank-b":$b, "bank-c":$c}' > "$tmp/ids.json"
empty=$(jq -r 'to_entries[] | select(.value == "") | .key' "$tmp/ids.json" | tr '\n' ' ')
[[ -z $empty ]] || die "address conversion returned nothing for: $empty"

# 3. parameters from the repo's own nexus.toml / generate.sh constants (single source)
stake=$(python3 -I -c 'import sys,tomllib;print(tomllib.load(open(sys.argv[1],"rb"))["nexus"]["staking"]["stake_asset_id"])' "$here/nexus.toml")
mapfile -t lanes < <(python3 -I -c 'import sys,tomllib;[print(l["index"]) for l in tomllib.load(open(sys.argv[1],"rb"))["nexus"]["lane_catalog"] if l["index"]>0]' "$here/nexus.toml")
[[ ${#lanes[@]} -eq 2 ]] || die "nexus.toml: expected lanes 1 and 2 besides lane 0"
rd_id=$(sed -n 's/^  RD_ID=\(.*\)$/\1/p' "$here/generate.sh"); df_id=$(sed -n 's/^  DFABI_ID=\(.*\)$/\1/p' "$here/generate.sh")
[[ -n $rd_id && -n $df_id ]] || die "RD_ID / DFABI_ID not found in generate.sh"

# 4. genesis manifest and the public peer.toml template
python3 -I "$here/s5.py" genesis --localnet "$tmp/ln" --peers "$peers" --ids "$tmp/ids.json" --params "$params" --epoch-length "$EPOCH_LENGTH" \
  --lanes "${lanes[@]}" --stake-asset "$stake" --rd-id "$rd_id" --dfabi-id "$df_id" --jq-file "$here/genesis-rd-dfabi-s5.jq" \
  --generate-sh "$here/generate.sh" --out "$tmp/genesis.json"
python3 -I "$here/s5.py" template --localnet "$tmp/ln" --peers "$peers" --ids "$tmp/ids.json" --nexus "$here/nexus.toml" \
  --genesis-public-key "$GENESIS_PUBLIC_KEY" --out "$tmp/peer.template.toml"
"$KAGAMI" genesis validate "$tmp/genesis.json"

# 5. sign. The config only binds the DA proof policy: it is the template with the localnet's throwaway keys and a placeholder hash.
python3 -I "$here/s5.py" signcfg --localnet "$tmp/ln" --template "$tmp/peer.template.toml" --peers "$peers" --out "$tmp/sign.toml"
chmod 600 "$tmp/sign.toml"
# The topology and the PoPs are embedded in the manifest (s5.py genesis); `--topology/--peer-pop` would add a second topology and
# collide with the Committee keys registered in the manifest (probe: "consensus key identifier collision"), as generate.sh signs.
mkdir -p "$OUT_DIR"
"$KAGAMI" genesis sign "$tmp/genesis.json" \
  --private-key-file "$GENESIS_PRIVATE_KEY_FILE" --expected-public-key "$GENESIS_PUBLIC_KEY" --config "$tmp/sign.toml" \
  --out-file "$OUT_DIR/genesis.signed.nrt" --expected-hash-out "$OUT_DIR/genesis.expected_hash" >/dev/null
printf '%s\n' "$GENESIS_PUBLIC_KEY" > "$OUT_DIR/genesis.public_key"
printf '%s\n' "$chain" > "$OUT_DIR/chain_id"
cp "$tmp/peer.template.toml" "$OUT_DIR/peer.template.toml"
[[ -z ${KEEP_MANIFEST:-} ]] || cp "$tmp/genesis.json" "$KEEP_MANIFEST"
echo "assemble-s5.sh: wrote genesis.signed.nrt, genesis.expected_hash, genesis.public_key, chain_id, peer.template.toml to $OUT_DIR; destroy $GENESIS_PRIVATE_KEY_FILE now" >&2
