#!/usr/bin/env bash
# Assemble and sign the genesis from PUBLIC data only (iroha3 PLAN S2/S5). One signer runs this once; the genesis
# private key is supplied as a file path, never printed, and must be destroyed afterwards.
#   Inputs (all in $PUBLIC_DIR, default network/public): peers.json (party, public_key, pop_hex), peers.addr.json
#   ({party: {dns, external}}), accounts.json (public keys of bi, bi-gov, bank-a, bank-b, bank-c),
#   kagemusha-mint-finality-public.json (public parameters).
#   Env: GENESIS_PRIVATE_KEY_FILE, GENESIS_PUBLIC_KEY, KAGAMI (default kagami), OUT_DIR (default $PUBLIC_DIR),
#   IVM_DIR (kagami --ivm-dir), ASSEMBLE_ACCEPT_GAP=1.
#   Outputs in $OUT_DIR: genesis.signed.nrt, genesis.expected_hash, genesis.public_key.
# GAP (why ASSEMBLE_ACCEPT_GAP is required): today's genesis comes from `kagami localnet` plus the post-processing in
# network/generate.sh:262-400 (RD/DFABI overlay genesis-rd-dfabi.jq, lane validators and stake, gas parameters dropped,
# committee keys, `--config` peer.toml binding the DA policy). This script starts from `kagami genesis generate` and
# signs; it does NOT port that post-processing, and the mint-finality parameters source and the --ivm-dir location
# are [unverified] (see network/RUNBOOK-per-org.md sections 4-5). Do not use its output for a real chain yet.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
PUBLIC_DIR=${PUBLIC_DIR:-$here/public}
OUT_DIR=${OUT_DIR:-$PUBLIC_DIR}
KAGAMI=${KAGAMI:-kagami}
die() { echo "assemble.sh: $*" >&2; exit 2; }

[[ -n ${GENESIS_PRIVATE_KEY_FILE:-} && -f ${GENESIS_PRIVATE_KEY_FILE} ]] || die "GENESIS_PRIVATE_KEY_FILE must name an existing file"
[[ -n ${GENESIS_PUBLIC_KEY:-} ]] || die "GENESIS_PUBLIC_KEY must be set (the expected public key of the signer)"
[[ -z $(find "$PUBLIC_DIR" -type f \( -name '*.seed' -o -name '*.note' -o -name '*.hybrid' -o -name 'private.key' \) 2>/dev/null) ]] \
  || die "secret material (*.seed, *.note, *.hybrid, private.key) found in $PUBLIC_DIR; keep it in the org's custody"

peers=$PUBLIC_DIR/peers.json addr=$PUBLIC_DIR/peers.addr.json accts=$PUBLIC_DIR/accounts.json params=$PUBLIC_DIR/kagemusha-mint-finality-public.json
[[ -f $peers ]] || die "$peers is missing"
[[ $(jq 'length' "$peers") -eq 4 ]] || die "peers.json must list exactly 4 peers (3f+1 committee)"
[[ $(jq -r '[.[].party] | sort | join(",")' "$peers") == "bank-a,bank-b,bank-c,bi" ]] || die "peers.json parties must be bi, bank-a, bank-b, bank-c"
[[ $(jq '[.[] | select((.public_key // "") == "" or (.pop_hex // "") == "")] | length' "$peers") -eq 0 ]] || die "every peer needs public_key and a non-empty pop_hex"
[[ -f $addr ]] || die "$addr is missing (peers.addr.json: load balancers first, then genesis)"
[[ $(jq -r '[.[] | .dns // ""] | map(select(. == "")) | length' "$addr") -eq 0 && $(jq 'length' "$addr") -eq 4 ]] || die "peers.addr.json needs a dns address for each of the 4 parties"
[[ $(jq -r '."bank-c".external // ""' "$addr") != "" ]] || die "peers.addr.json needs an external address for bank-c (cluster 2)"
[[ -f $accts ]] || die "$accts is missing"
for a in bi bi-gov bank-a bank-b bank-c; do
  [[ $(jq -r --arg a "$a" '.[$a] // ""' "$accts") != "" ]] || die "accounts.json lacks the public key of $a (bi-gov: the governance account)"
done
[[ -f $params ]] || die "$params is missing (public KAGEMUSHA mint-finality parameters)"

if [[ ${ASSEMBLE_ACCEPT_GAP:-} != 1 ]]; then
  echo "assemble.sh: GAP: the lane-validator/stake overlay, the RD/DFABI overlay and the committee keys of network/generate.sh:262-400 are not ported yet; set ASSEMBLE_ACCEPT_GAP=1 for a probe run only" >&2
  exit 3
fi

mkdir -p "$OUT_DIR"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
topology=$(jq -c '[.[].public_key]' "$peers") # `--topology` is a "JSON-serialized vector of PeerId" (genesis-probe run 43006538345); PoPs go in --peer-pop
"$KAGAMI" genesis generate --profile iroha3-dev --ivm-dir "${IVM_DIR:-./ivm_libs}" --genesis-public-key "$GENESIS_PUBLIC_KEY" \
  --kagemusha-mint-finality-parameters "$params" --consensus-mode npos default > "$tmp/genesis.json"
pops=()
while IFS= read -r pair; do pops+=(--peer-pop "$pair"); done < <(jq -r '.[] | "\(.public_key)=\(.pop_hex)"' "$peers")
"$KAGAMI" genesis sign "$tmp/genesis.json" --topology "$topology" "${pops[@]}" \
  --private-key-file "$GENESIS_PRIVATE_KEY_FILE" --expected-public-key "$GENESIS_PUBLIC_KEY" \
  --out-file "$OUT_DIR/genesis.signed.nrt" --expected-hash-out "$OUT_DIR/genesis.expected_hash" >/dev/null
printf '%s\n' "$GENESIS_PUBLIC_KEY" > "$OUT_DIR/genesis.public_key"
echo "assemble.sh: wrote genesis.signed.nrt, genesis.expected_hash, genesis.public_key to $OUT_DIR; destroy $GENESIS_PRIVATE_KEY_FILE now" >&2
