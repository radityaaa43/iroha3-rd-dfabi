#!/usr/bin/env bash
# Generate the 4-party permissioned Iroha 3 network material.
#   network/public/**  committed (genesis, public keys, PoPs, chain id)
#   network/out/**     gitignored, holds ALL private keys (dirs 0700, files 0600)
# Run on the operator PC. Refuses to run if network/out already exists.
set -euo pipefail

IMAGE="${IMAGE:-ghcr.io/radityaaa43/iroha3-rd-node:071e281e-stark}"
NS=iroha3
PARTIES=(bi bank-a bank-b bank-c) # peer0..peer3

cd "$(dirname "$0")"
OUT="$PWD/out"
PUB="$PWD/public"

if [[ -e $OUT ]]; then
  echo "refusing to run: $OUT already exists (would overwrite keys in use)." >&2
  echo "move it to offline custody or delete it deliberately first." >&2
  exit 1
fi

umask 077
mkdir -p "$OUT" "$PUB"
RAW="$OUT/.raw"
mkdir "$RAW"

# Kagami writes as the image user; run as the host user so files are ours.
# No --seed: keys come from OS entropy. Chain id is a fresh random UUID.
CHAIN_ID="$(uuidgen | tr 'A-Z' 'a-z')"
docker run --rm --user "$(id -u):$(id -g)" -v "$RAW:/work/out" \
  --entrypoint kagami "$IMAGE" localnet \
  --peers 4 --consensus-mode permissioned --chain-id "$CHAIN_ID" \
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
    with open(f"{d}/client.toml", "w") as f:
        f.write(c)
    m = re.search(r'pop_hex = "([0-9a-f]+)"\npublic_key = "%s"' % pk[i], t)
    assert m, "no PoP for " + p
    peers.append({"party": p, "public_key": pk[i], "pop_hex": "0x" + m.group(1)})

json.dump(peers, open(f"{out}/peers.json", "w"), indent=2)
open(f"{out}/peers.json", "a").write("\n")
PY

# Public bundle (committed).
cp "$RAW/genesis.signed.nrt" "$RAW/genesis.public_key" "$RAW/genesis.expected_hash" "$PUB/"
printf '%s\n' "$CHAIN_ID" >"$PUB/chain_id"
mv "$OUT/peers.json" "$PUB/peers.json"
chmod 644 "$PUB"/*

# Genesis signing key + source manifest go to custody dir; everything else
# from the raw localnet (other keys, start scripts, state) is discarded.
mkdir "$OUT/genesis"
mv "$RAW/genesis.private_key" "$RAW/genesis.json" "$OUT/genesis/"
cp "$PUB/genesis.public_key" "$OUT/genesis/"
rm -rf "$RAW"

find "$OUT" -type d -exec chmod 700 {} +
find "$OUT" -type f -exec chmod 600 {} +

# Real-binary validation of every converted config against the signed genesis,
# mounted at the same paths the pod will use.
for p in "${PARTIES[@]}"; do
  st="$(mktemp -d)"
  docker run --rm --user "$(id -u):$(id -g)" \
    -v "$OUT/$p/peer.toml:/config/peer.toml:ro" -v "$PUB:/genesis:ro" -v "$st:/storage" \
    --entrypoint iroha3d "$IMAGE" --check-config --config /config/peer.toml 2>&1 | tail -1
  rm -rf "$st"
done

cat <<EOF
Done. chain id: $CHAIN_ID
Public bundle : $PUB   (commit this)
Private keys  : $OUT   (gitignored, never commit)

NEXT: move the genesis signing key out of the repo to offline custody:
  $OUT/genesis/
It is not needed by the cluster. Keep a copy somewhere safe, then delete it
from this checkout.
EOF
