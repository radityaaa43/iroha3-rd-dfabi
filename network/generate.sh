#!/usr/bin/env bash
# Generate the 4-party permissioned Iroha 3 network material.
#   network/public/**  committed (genesis, public keys, PoPs, chain id)
#   network/out/**     gitignored, holds ALL private keys (dirs 0700, files 0600)
# Run on the operator PC. Refuses to run if network/out already exists.
#
# --aps  additionally build the 3-lane Nexus topology with atomic private
#        settlement (gate G1b): merge network/nexus.toml into every peer.toml,
#        add RD/DFABI (genesis-rd-dfabi.jq) and the lane 1/2 validator
#        instructions to the genesis, then validate and re-sign it. Needs
#        PARTY_ACCOUNTS=<json file> {"bi":..,"bank-a":..,"bank-b":..,"bank-c":..}
#        with the public account ids of the four parties (not secret).
# NETWORK_OUT / NETWORK_PUB redirect out/ and public/ (testing); NETWORK_OUT
# must then be outside the repo or gitignored by the caller.
set -euo pipefail

IMAGE="${IMAGE:-ghcr.io/radityaaa43/iroha3-rd-node:071e281e-stark}"
NS=iroha3
PARTIES=(bi bank-a bank-b bank-c) # peer0..peer3

APS=0
for arg in "$@"; do
  if [[ $arg == --aps ]]; then APS=1; fi
done

cd "$(dirname "$0")"
HERE="$PWD"
OUT="${NETWORK_OUT:-$PWD/out}"
PUB="${NETWORK_PUB:-$PWD/public}"

if [[ -e $OUT ]]; then
  echo "refusing to run: $OUT already exists (would overwrite keys in use)." >&2
  echo "move it to offline custody or delete it deliberately first." >&2
  exit 1
fi

# network/out holds every private key: it must be gitignored before we write it.
if [[ -z ${NETWORK_OUT:-} ]] && ! git check-ignore -q out/.probe; then
  echo "refusing to run: network/out is not gitignored." >&2
  exit 1
fi

umask 077
mkdir -p "$OUT" "$PUB"
RAW="$OUT/.raw"
mkdir "$RAW"
TMP="$(mktemp -d)"
done_ok=0
# On any exit: drop scratch dirs; on failure also drop the half-built (never
# used) out/ so a rerun is possible.
trap 'rm -rf "$RAW" "$TMP"; [[ $done_ok == 1 ]] || rm -rf "$OUT"' EXIT

# Kagami writes as the image user; run as the host user so files are ours.
# No --seed: keys come from OS entropy. Chain id is a fresh random UUID.
CHAIN_ID="$(uuidgen | tr 'A-Z' 'a-z')"
if [[ ! $CHAIN_ID =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
  echo "uuidgen returned no usable chain id" >&2
  exit 1
fi
# --aps needs NPoS: irohad refuses a custom Nexus lane catalog unless the signed
# genesis is NPoS (irohad main.rs, InitKura: "custom Nexus lane topology requires the
# authenticated Sumeragi v2 mode to be NPoS"). The plain network stays permissioned.
CONSENSUS_MODE=permissioned
if [[ $APS == 1 ]]; then CONSENSUS_MODE=npos; fi
docker run --rm --user "$(id -u):$(id -g)" -v "$RAW:/work/out" \
  --entrypoint kagami "$IMAGE" localnet \
  --peers 4 --consensus-mode "$CONSENSUS_MODE" --chain-id "$CHAIN_ID" \
  --out-dir /work/out >/dev/null

# The localnet already emits BLS (bls_normal) validator keys with PoP and a
# genesis signed with that topology; verify the manifest with kagami itself.
docker run --rm --user "$(id -u):$(id -g)" -v "$RAW:/work/out:ro" \
  --entrypoint kagami "$IMAGE" genesis validate /work/out/genesis.json

# Rewrite localnet (host-style) configs into container form, one dir per party.
python3 -I - "$RAW" "$OUT" "$NS" "${PARTIES[@]}" <<'PY'
import json, re, sys, os

raw, out, ns, *parties = sys.argv[1:]


def crc16(data: bytes) -> int:  # CRC-16/CCITT-FALSE, as used by Iroha addr checksums
    c = 0xFFFF
    for b in data:
        c ^= b << 8
        for _ in range(8):
            c = ((c << 1) ^ 0x1021) & 0xFFFF if c & 0x8000 else (c << 1) & 0xFFFF
    return c


def addr(host_port: str) -> str:
    s = "addr:" + host_port
    return "%s#%04X" % (s, crc16(s.encode()))


def dns(p):
    return f"{p}-0.{p}.{ns}.svc.cluster.local"


texts = [open(f"{raw}/peer{i}.toml").read() for i in range(len(parties))]
pk = [re.search(r'^public_key = "(ea0130[0-9A-Fa-f]+)"', t, re.M).group(1) for t in texts]
by_pk = dict(zip(pk, parties))
assert len(set(pk)) == len(parties)

trusted = "trusted_peers = [%s]" % ", ".join(
    '"%s@%s"' % (k, addr(dns(p) + ":1337")) for k, p in zip(pk, parties))
telemetry = "peer_telemetry_urls = [%s]" % ", ".join(
    '"http://%s:8080/"' % dns(p) for p in parties)

peers = []
for i, p in enumerate(parties):
    t = texts[i]
    sec = None
    lines = []
    for ln in t.split("\n"):
        m = re.match(r"^\[+([^\]]+)\]+\s*$", ln)
        if m:
            sec = m.group(1)
        if ln.startswith("trusted_peers = "):
            ln = trusted
        elif ln.startswith("peer_telemetry_urls = "):
            ln = telemetry
        elif ln.startswith("public_address = "):
            ln = 'public_address = "%s"' % addr(dns(p) + ":1337")
        elif sec == "network" and ln.startswith("address = "):
            ln = 'address = "%s"' % addr("0.0.0.0:1337")
        elif sec == "torii" and ln.startswith("address = "):
            ln = 'address = "%s"' % addr("0.0.0.0:8080")
        elif sec == "genesis" and ln.startswith("file = "):
            ln = 'file = "/genesis/genesis.signed.nrt"'
        elif sec == "genesis" and ln.startswith("expected_hash_file = "):
            ln = 'expected_hash_file = "/genesis/genesis.expected_hash"'
        ln = re.sub(r"/work/out/storage/peer\d+", "/storage/kura", ln)
        ln = re.sub(r"/work/out/state/peer\d+", "/storage/state", ln)
        lines.append(ln)
    # Drop sections that reference key/table files which are not shipped to the
    # cluster (only peer.toml is): dev faucet, dev onboarding token, rANS codec tables.
    # None are needed for a permissioned ledger.
    blocks = re.split(r"(?m)^(?=\[)", "\n".join(lines))
    drop = ("[torii.account_onboarding", "[[torii.account_onboarding", "[torii.faucet", "[streaming.codec]")
    new = "".join(b for b in blocks if not b.startswith(drop))
    d = f"{out}/{p}"
    os.makedirs(d, mode=0o700, exist_ok=True)
    os.chmod(d, 0o700)
    with open(f"{d}/peer.toml", "w") as f:
        f.write(new)
    # one shared client identity from localnet; point Torii at this party
    c = open(f"{raw}/client.toml").read()
    c = re.sub(r'^torii_url = .*$', 'torii_url = "http://%s:8080/"' % dns(p), c, flags=re.M)
    # drop the upstream sample [basic_auth] table (mad_hatter / sample password)
    c = re.sub(r'(?ms)^\[basic_auth\]\n.*?(?=^\[|\Z)', '', c)
    assert "basic_auth" not in c and "mad_hatter" not in c
    with open(f"{d}/client.toml", "w") as f:
        f.write(c)
    m = re.search(r'pop_hex = "([0-9a-f]+)"\npublic_key = "%s"' % pk[i], t)
    assert m, "no PoP for " + p
    peers.append({"party": p, "public_key": pk[i], "pop_hex": "0x" + m.group(1)})

json.dump(peers, open(f"{out}/peers.json", "w"), indent=2)
open(f"{out}/peers.json", "a").write("\n")
PY

# --aps: Nexus overlay + 3-lane genesis (see header). Runs while $RAW still holds
# the signing key and the localnet manifest; replaces the manifest and the signed
# block in $RAW so the public bundle below carries the lane-aware genesis.
if [[ $APS == 1 ]]; then
  : "${PARTY_ACCOUNTS:?--aps needs PARTY_ACCOUNTS=<json file with the 4 party account ids>}"
  # Definition ids are opaque values (not checked against their owning domain), kept equal to the
  # ones the frontend (bootstrap-iroha3.ts) and the earlier Global-asset network use:
  # AssetDefinitionId::derive_from_components("rd"|"dfabi", "wonderland").
  RD_ID=7onbjg2gRXveoAAUFsohCZyGW98t
  DFABI_ID=4mBWK1JCwQdHLDPpuVKc56eLsXka
  # RD and DFABI are DataspaceRestricted and share this home dataspace (see genesis-rd-dfabi.jq for why one).
  HOME_DS=ds-rd

  python3 -I - "$HERE/nexus.toml" "$OUT" "${PARTIES[@]}" <<'PY'
import json, sys, tomllib

nexus_toml, out, *parties = sys.argv[1:]


def load(path):
    with open(path, "rb") as f:
        return tomllib.load(f)


def bare(k):
    return k and all(c.isalnum() and c.isascii() or c in "_-" for c in k)


def key(k):
    return k if bare(k) else json.dumps(k, ensure_ascii=False)


def val(v):
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        return repr(v)
    if isinstance(v, str):
        return json.dumps(v, ensure_ascii=False)
    if isinstance(v, list):
        return "[" + ", ".join(val(x) for x in v) + "]"
    raise TypeError(type(v))


def is_table_array(v):
    return isinstance(v, list) and v and all(isinstance(x, dict) for x in v)


def emit(t, path, lines):
    for k, v in t.items():
        if not isinstance(v, dict) and not is_table_array(v):
            lines.append("%s = %s" % (key(k), val(v)))
    for k, v in t.items():
        sub = path + [key(k)]
        if isinstance(v, dict):
            lines += ["", "[%s]" % ".".join(sub)]
            emit(v, sub, lines)
        elif is_table_array(v):
            for item in v:
                lines += ["", "[[%s]]" % ".".join(sub)]
                emit(item, sub, lines)


def merge(base, over):
    for k, v in over.items():
        if isinstance(v, dict) and isinstance(base.get(k), dict):
            merge(base[k], v)
        else:
            base[k] = v


def subst(o, table):
    if isinstance(o, dict):
        return {k: subst(v, table) for k, v in o.items()}
    if isinstance(o, list):
        return [subst(v, table) for v in o]
    return table.get(o, o) if isinstance(o, str) else o


peers = {p: load(f"{out}/{p}/peer.toml") for p in parties}
# kagami localnet draws a fresh escrow/slash-sink account per run; the genesis
# it signed registers exactly that one, so the overlay takes it over.
st = {p: peers[p]["nexus"]["staking"] for p in parties}
ref = st[parties[0]]
for p in parties:
    assert st[p] == ref, "localnet staking section differs between peers"
over = load(nexus_toml)
assert over["nexus"]["staking"]["stake_asset_id"] == ref["stake_asset_id"], \
    "nexus.toml stake_asset_id is not the stake asset the localnet genesis registers"
over = subst(over, {
    "@STAKE_ESCROW_ACCOUNT_ID@": ref["stake_escrow_account_id"],
    "@SLASH_SINK_ACCOUNT_ID@": ref["slash_sink_account_id"],
    "@GAS_TECH_ACCOUNT_ID@": peers[parties[0]]["pipeline"]["gas"]["tech_account_id"],
})
for p in parties:
    merged = peers[p]
    merge(merged, over)
    lines = []
    emit(merged, [], lines)
    text = "\n".join(lines).lstrip("\n") + "\n"
    assert tomllib.loads(text) == merged, "toml writer round trip failed for " + p
    with open(f"{out}/{p}/peer.toml", "w") as f:
        f.write(text)
PY

  FEE_ASSET="$(python3 -I -c 'import sys,tomllib;print(tomllib.load(open(sys.argv[1],"rb"))["nexus"]["fees"]["fee_asset_id"])' "$HERE/nexus.toml")"
  jq -e --arg fee "$FEE_ASSET" 'any(.transactions[].instructions[] | objects; .Register.AssetDefinition.id == $fee and .Register.AssetDefinition.name == "XOR")' "$RAW/genesis.json" >/dev/null \
    || { echo "nexus.toml fees.fee_asset_id is not the XOR asset the localnet genesis registers" >&2; exit 1; }
  STAKE_ASSET="$(python3 -I -c 'import sys,tomllib;print(tomllib.load(open(sys.argv[1],"rb"))["nexus"]["staking"]["stake_asset_id"])' "$HERE/nexus.toml")"
  mapfile -t LANES < <(python3 -I -c 'import sys,tomllib;[print(l["index"]) for l in tomllib.load(open(sys.argv[1],"rb"))["nexus"]["lane_catalog"] if l["index"]>0]' "$HERE/nexus.toml")
  [[ ${#LANES[@]} -eq 2 ]] || { echo "nexus.toml: expected lanes 1 and 2 besides lane 0" >&2; exit 1; }

  GEN_ACCOUNT="$(jq -er 'first(.transactions[].instructions[] | objects | select(.Grant.Permission.object.name == "CanSetParameters")) | .Grant.Permission.destination' "$RAW/genesis.json")"
  # RD/DFABI first (genesis-rd-dfabi.jq), then the lane validators in a transaction of
  # their own, cloned from the lane-0 bootstrap kagami wrote: the same 4
  # validators stake a further 10000 each per lane (mint + register + activate,
  # the genesis_post_topology pattern). The stake asset already exists: kagami
  # localnet registers it for the lane-0 bootstrap.
  # readds = every restricted dataspace id = lane indexes 1..n (check.sh asserts lane index == dataspace id)
  jq --arg bi "$(jq -er '.["bi"]' "$PARTY_ACCOUNTS")" --arg a "$(jq -er '.["bank-a"]' "$PARTY_ACCOUNTS")" \
     --arg b "$(jq -er '.["bank-b"]' "$PARTY_ACCOUNTS")" --arg c "$(jq -er '.["bank-c"]' "$PARTY_ACCOUNTS")" \
     --arg gen "$GEN_ACCOUNT" --arg rd "$RD_ID" --arg dfabi "$DFABI_ID" \
     --arg domain "wonderland.$HOME_DS" \
     --argjson readds "$(printf '%s\n' "${LANES[@]}" | jq -sc .)" \
     -f "$HERE/genesis-rd-dfabi.jq" "$RAW/genesis.json" >"$TMP/genesis.rd.json"
  jq --arg stake "$STAKE_ASSET" --argjson lanes "$(printf '%s\n' "${LANES[@]}" | jq -sc .)" '
    ([.transactions[].instructions[] | objects | select(has("RegisterPublicLaneValidator")).RegisterPublicLaneValidator
      | select(.lane_id == 0)]) as $v
    | if ($v | length) != 4 then error("expected 4 lane-0 validators, found \($v | length)") else . end
    | if any(.transactions[].instructions[] | objects; .Register.AssetDefinition.id == $stake) then . else error("stake asset \($stake) is not registered in genesis") end
    # kagami npos localnet writes ivm_gas_accepted_assets / ivm_gas_units_per_gas into genesis, but its
    # peer.toml [pipeline.gas] has only tech_account_id. Torii then quotes a Nexus fee only, while
    # execution (executor.rs) requires a PipelineGas limit too and rejects every tx. The upstream
    # APS test genesis has neither parameter; drop them so gas stays off.
    | .transactions |= map(if .parameters.custom then del(.parameters.custom.ivm_gas_accepted_assets, .parameters.custom.ivm_gas_units_per_gas) else . end)
    | .transactions += [{instructions: [
        $lanes[] as $lane | $v[] | (
          {Mint: {Asset: {destination: ($stake + "#" + .validator), object: .initial_stake}}},
          {RegisterPublicLaneValidator: (. + {lane_id: $lane})},
          {ActivatePublicLaneValidator: {lane_id: $lane, validator: .validator}}
        )], ivm_triggers: [], topology: []}]
  ' "$TMP/genesis.rd.json" >"$RAW/genesis.json"

  # Privacy / committee transaction (one transaction: a grant is not visible to a
  # later genesis transaction, upstream atomic_private_settlement_localnet.rs
  # genesis_post_topology comment).
  #  1. CanEnactGovernance + RegisterPrivacyProtocolActivationV1 (Proposed at height 1)
  #     + TransitionPrivacyProtocolLifecycleV1 (Active 1/1/1): the capability gate in
  #     state.rs ensure_private_settlement_feature_active_v1 reads this record.
  #  2. CanManageConsensusKeys + RegisterConsensusKey: a Committee-role record on each
  #     validator's own peer key. private_settlement/protocol.rs
  #     validate_private_settlement_committee_authority_v1 resolves the role by the
  #     lane roster's PeerId public key (state.rs peer_has_live_consensus_key_for_role),
  #     so it must be the same key and PoP; no extra private key exists.
  # Genesis JSON carries these instructions as canonical Norito (base64): the structured
  # JSON form does not exist for them (iroha_genesis genesis_instructions_json). The two
  # privacy frames are fixed data; the RegisterConsensusKey frame is the sample below
  # re-keyed per peer (peer key, PoP, derived key id are fixed-length fields; both
  # Norito CRC64 headers are recomputed). Both were produced with the image's own
  # iroha_data_model from the compiled profile served by GET /v1/privacy/capabilities
  # of a 071e281e-stark node (kagami privacy-bootstrap needs all 12 profiles; 11 are
  # unavailable in this build), and the re-keying was checked byte-for-byte against a
  # direct encoding for 4 peers. Public data; changes only with the image.
  if [[ $IMAGE != *:071e281e-stark ]]; then
    echo "the embedded privacy frames belong to the 071e281e-stark image; regenerate them for $IMAGE" >&2
    exit 1
  fi
  python3 -I - "$RAW/genesis.json" "$OUT/peers.json" "$GEN_ACCOUNT" <<'PY'
import base64, hashlib, json, struct, sys

genesis_path, peers_path, gen = sys.argv[1:]
g = json.load(open(genesis_path))
peers = json.load(open(peers_path))
assert len(peers) == 4

REGISTER_ACTIVATION = "TlJUMAAAhip9dwddTSP/bBJh2wJ4EQA9AQAAAAAAAHh+gnTCKF6jAi4taXJvaGEucHJpdmFjeS5yZWdpc3Rlcl9wcm90b2NvbF9hY3RpdmF0aW9uLnYxjAIEAQAAAAAAAE5SVDAAAGjquae8oN6vFpl5QuQfISoA3AAAAAAAAADtJth46AcjAQLaAQQKAAAABAAAAAAEAAAAACEgsAtyR2lFftTMZkC4JGv7jpqMLd5QEIguyNPXcwysYbohIJnyV+S2IX/O8kckOLsDGEffb5Q7/AfbeUP5lVOogAEjISDbH+xDSkMNq3AU6cjxQTnQg1CDhl81deJ8IDNzcheukiEgWarAs1rfgpQOhyk/VfMEq1KQSJahm8WlmJrKJOucS8khIL2Y1jVt5vLsPLZ6xfZqrWp5pHz1bjV8ne36AXLnk5sZDgAAAAAJCAEAAAAAAAAADwoAAAAKBAIAAAAEAgAAAAEA"
TRANSITION_ACTIVE = "TlJUMAAAhip9dwddTSP/bBJh2wJ4EQCHAAAAAAAAAFx3Ik/rbiTzAi8uaXJvaGEucHJpdmFjeS50cmFuc2l0aW9uX3Byb3RvY29sX2xpZmVjeWNsZS52MVZOAAAAAAAAAE5SVDAAAFufZhcemVbdf9h3TVdBQZUAJgAAAAAAAACYg7Z0aYbh/gIECgAAACABAAAAGwgBAAAAAAAAAAgBAAAAAAAAAAgBAAAAAAAAAA=="
SAMPLE_KEY = "TlJUMAAAhip9dwddTSP/bBJh2wJ4EQChAQAAAAAAABKa93/jOEskAiAfY29uc2Vuc3VzOjpSZWdpc3RlckNvbnNlbnN1c0tlef4CdgEAAAAAAABOUlQwAADtjD0RLkmtq+EUR3RYHuR2AE4BAAAAAAAA4pbJeF21itkCMQQBAAAAKypjb21taXR0ZWUtZTljZmQ4OGM1MDMwYjc1OTM1ZDQxZDMyMzc2NzlhN2aaAjEEAQAAACsqY29tbWl0dGVlLWU5Y2ZkODhjNTAzMGI3NTkzNWQ0MWQzMjM3Njc5YTdmajEAAAAAAAAAAQIBlAEUAfoBxgHmAZIBzQHZATIBewGEAYsB6gFVAWwBfwHgAfwBugFdAc4B/AFtAT4BCQHOAQMBvAHrAWkBTwGPAQoBXwHcAbcBwAGrAf4BYwFRAXYBRgEgAY8ByQEnAWJqAWhgAAAAAAAAAK0r2O/l09tS9Ah2gHu7x4spXlHroPHCEQXP7mWE6DexMckGq9PGlDFMrH3Xgjl7YgxzqENcCH5jRlBb9Y/HwFHcgISIAKBhWxSsO5YSIpGjzKn5SbAcowCd10ZpjggvgQgBAAAAAAAAAAEAAQAEAQAAAA=="
SAMPLE_PEER = {"public_key": "ea01309414FAC6E692CDD9327B848BEA556C7FE0FCBA5DCEFC6D3E09CE03BCEB694F8F0A5FDCB7C0ABFE63517646208FC92762",
               "pop_hex": "0xad2bd8efe5d3db52f40876807bbbc78b295e51eba0f1c21105cfee6584e837b131c906abd3c694314cac7dd782397b620c73a8435c087e6346505bf58fc7c051dc80848800a0615b14ac3b96122291a3cca9f949b01ca3009dd746698e082f81"}


def crc64_xz(data, _t=[]):
    if not _t:
        for i in range(256):
            c = i
            for _ in range(8):
                c = (c >> 1) ^ 0xC96C5795D7870F42 if c & 1 else c >> 1
            _t.append(c)
    c = 0xFFFFFFFFFFFFFFFF
    for b in data:
        c = _t[(c ^ b) & 0xFF] ^ (c >> 8)
    return c ^ 0xFFFFFFFFFFFFFFFF


def refresh(frame):  # 40-byte Norito header: length at 23, CRC64 at 31
    h, p = bytearray(frame[:40]), frame[40:]
    h[23:31] = struct.pack("<Q", len(p))
    h[31:39] = struct.pack("<Q", crc64_xz(p))
    return bytes(h) + p


def key_suffix(peer):  # core state.rs derive_committee_key_id
    return hashlib.blake2b(peer["public_key"].encode(), digest_size=64).digest()[:16].hex().encode()


def key_bytes(peer):  # Vec<u8> elements are length-prefixed one by one
    return b"".join(b"\x01" + bytes([x]) for x in bytes.fromhex(peer["public_key"][6:]))


def pop_bytes(peer):
    return bytes.fromhex(peer["pop_hex"][2:])


def register_committee_key(peer):
    frame = base64.b64decode(SAMPLE_KEY)
    for f in (key_suffix, key_bytes, pop_bytes):
        old, new = f(SAMPLE_PEER), f(peer)
        assert len(old) == len(new) and old in frame, f.__name__
        frame = frame.replace(old, new)
    i = frame.find(b"NRT0", 4)  # nested payload frame
    return base64.b64encode(refresh(frame[:i] + refresh(frame[i:]))).decode()


def grant(name):
    return {"Grant": {"Permission": {"destination": gen, "object": {"name": name, "payload": None}}}}


g["transactions"].append({"instructions": [
    grant("CanEnactGovernance"),
    REGISTER_ACTIVATION,
    TRANSITION_ACTIVE,
    grant("CanManageConsensusKeys"),
    *[register_committee_key(p) for p in peers],
], "ivm_triggers": [], "topology": []})
json.dump(g, open(genesis_path, "w"), ensure_ascii=False)
PY

  docker run --rm --user "$(id -u):$(id -g)" -v "$RAW:/work/out:ro" \
    --entrypoint kagami "$IMAGE" genesis validate /work/out/genesis.json
  # Same peer.toml for sign as for the nodes (it binds the DA proof policy), except
  # that the signed block's hash does not exist yet: kagami accepts a placeholder.
  sed 's|^expected_hash_file = .*|expected_hash = "REPLACE_WITH_GENESIS_EXPECTED_HASH"|' \
    "$OUT/${PARTIES[0]}/peer.toml" >"$TMP/sign.toml"
  docker run --rm --user "$(id -u):$(id -g)" -v "$RAW:/work/out" \
    -v "$TMP/sign.toml:/config/peer.toml:ro" \
    --entrypoint kagami "$IMAGE" genesis sign /work/out/genesis.json \
    --private-key-file /work/out/genesis.private_key \
    --expected-public-key "$(cat "$RAW/genesis.public_key")" \
    --config /config/peer.toml \
    --out-file /work/out/aps.signed.nrt \
    --expected-hash-out /work/out/aps.expected_hash \
    --bound-manifest-out /work/out/genesis.bound.json >/dev/null
  # kagami will not overwrite the localnet's hash file in place.
  mv "$RAW/aps.signed.nrt" "$RAW/genesis.signed.nrt"
  mv "$RAW/aps.expected_hash" "$RAW/genesis.expected_hash"
fi

# Public bundle (committed).
cp "$RAW/genesis.signed.nrt" "$RAW/genesis.public_key" "$RAW/genesis.expected_hash" "$PUB/"
printf '%s\n' "$CHAIN_ID" >"$PUB/chain_id"
mv "$OUT/peers.json" "$PUB/peers.json"
chmod 644 "$PUB"/*

# Genesis signing key + source manifest go to custody dir; everything else
# from the raw localnet (other keys, start scripts, state) is discarded.
mkdir "$OUT/genesis"
mv "$RAW/genesis.private_key" "$RAW/genesis.json" "$OUT/genesis/"
if [[ $APS == 1 ]]; then mv "$RAW/genesis.bound.json" "$OUT/genesis/"; fi
cp "$PUB/genesis.public_key" "$OUT/genesis/"
rm -rf "$RAW"

find "$OUT" -type d -exec chmod 700 {} +
find "$OUT" -type f -exec chmod 600 {} +

# Real-binary validation of every converted config against the signed genesis,
# mounted at the same paths the pod will use.
# Custom Nexus lanes only load under the Sora profile (irohad main.rs
# SoraProfileRequired); the nodes need the same flag at start.
SORA_FLAG=()
if [[ $APS == 1 ]]; then SORA_FLAG=(--sora); fi
for p in "${PARTIES[@]}"; do
  st="$TMP/$p"
  mkdir "$st"
  # --aps: fresh tmpfs, as check.sh does; iroha3d reserves 20% of the storage
  # filesystem and a host disk over 80% full would fail the check.
  STORAGE=(-v "$st:/storage")
  if [[ $APS == 1 ]]; then STORAGE=(--tmpfs /storage:rw,size=2g,mode=1777); fi
  docker run --rm --user "$(id -u):$(id -g)" \
    -v "$OUT/$p/peer.toml:/config/peer.toml:ro" -v "$PUB:/genesis:ro" "${STORAGE[@]}" \
    --entrypoint iroha3d "$IMAGE" ${SORA_FLAG[@]+"${SORA_FLAG[@]}"} --check-config --config /config/peer.toml 2>&1 | tail -1
done

done_ok=1

cat <<EOF
Done. chain id: $CHAIN_ID
Public bundle : $PUB   (commit this)
Private keys  : $OUT   (gitignored, never commit)

NEXT: move the genesis signing key out of the repo to offline custody:
  $OUT/genesis/
It is not needed by the cluster. Keep a copy somewhere safe, then delete it
from this checkout.
EOF
