#!/usr/bin/env bash
# Epoch-stall probe (design: network/probes/epoch-stall.md). THROWAWAY chain, 4 stock iroha3d containers on the host
# network, no secrets, no cluster. Usage: epoch-stall.sh r1|r2|r3|r4   Env: IMAGE (required), L (r2 epoch length),
# SECS (observation time, default 150), WORK (scratch dir). Prints one height line per sample and the decisive log lines.
set -uo pipefail
row=${1:?usage: epoch-stall.sh r1|r2|r3|r4}
IMAGE=${IMAGE:?IMAGE is required}
L=${L:-1152921504606846976}
SECS=${SECS:-150}
HERE=$(cd "$(dirname "$0")" && pwd)
W=${WORK:-$(mktemp -d)}; mkdir -p "$W"; chmod 777 "$W"
U="$(id -u):$(id -g)"
k() { docker run --rm --user "$U" -v "$W:/work/out" --entrypoint kagami "$IMAGE" "$@"; }
mode=npos; case $row in r3 | r4) mode=permissioned ;; esac
case $row in r1) EL=20 ;; r2) EL=$L ;; r3 | r4) EL="" ;; *) echo "unknown row $row" >&2; exit 2 ;; esac
echo "== row $row: consensus $mode, epoch_length_blocks ${EL:-n/a}"
k localnet --peers 4 --consensus-mode "$mode" --chain-id 00000000-0000-4000-8000-000000000a01 \
  --base-api-port 18080 --base-p2p-port 11337 --out-dir /work/out/ln >/dev/null || { echo "localnet failed" >&2; exit 1; }
ln="$W/ln"
if [[ -n $EL ]]; then
  python3 -I - "$ln/genesis.json" "$EL" <<'PY' || exit 1
import json, sys
path, el = sys.argv[1], int(sys.argv[2])
g = json.load(open(path))
n = 0
for tx in g["transactions"]:
    c = (tx.get("parameters") or {}).get("custom") or {}
    if "sumeragi_npos_parameters" in c:
        c["sumeragi_npos_parameters"]["payload"]["epoch_length_blocks"] = el
        n += 1
assert n == 1, "expected exactly one sumeragi_npos_parameters"
json.dump(g, open(path, "w"), indent=2)
PY
  sed 's|^expected_hash_file = .*|expected_hash = "REPLACE_WITH_GENESIS_EXPECTED_HASH"|' "$ln/peer0.toml" > "$ln/sign.toml"
  chmod 600 "$ln/sign.toml"
  k genesis sign /work/out/ln/genesis.json --private-key-file /work/out/ln/genesis.private_key \
    --expected-public-key "$(cat "$ln/genesis.public_key")" --config /work/out/ln/sign.toml \
    --out-file /work/out/ln/new.signed.nrt --expected-hash-out /work/out/ln/new.expected_hash >/dev/null || { echo "re-sign failed" >&2; exit 1; }
  mv "$ln/new.signed.nrt" "$ln/genesis.signed.nrt"; mv "$ln/new.expected_hash" "$ln/genesis.expected_hash"
  echo "genesis re-signed with epoch_length_blocks=$EL"
fi
sora=()
if [[ $row == r4 ]]; then
  # our 3-lane / 3-dataspace catalog and routing policy on peer0 only (merge logic as network/generate.sh)
  python3 -I - "$ln/peer0.toml" "$HERE/../nexus.toml" <<'PY' || exit 1
import json, sys, tomllib
peer, nexus = sys.argv[1:]
t = tomllib.load(open(peer, "rb"))
o = tomllib.load(open(nexus, "rb"))["nexus"]
n = t.setdefault("nexus", {})
for key in ("lane_count", "lane_catalog", "dataspace_catalog", "routing_policy", "storage"):
    n[key] = o[key]
def key(k): return k if k and all(c.isalnum() and c.isascii() or c in "_-" for c in k) else json.dumps(k)
def val(v):
    if isinstance(v, bool): return "true" if v else "false"
    if isinstance(v, (int, float)): return repr(v)
    if isinstance(v, str): return json.dumps(v, ensure_ascii=False)
    if isinstance(v, list): return "[" + ", ".join(val(x) for x in v) + "]"
    raise TypeError(type(v))
def tab(v): return isinstance(v, list) and v and all(isinstance(x, dict) for x in v)
def emit(d, path, out):
    for k, v in d.items():
        if not isinstance(v, dict) and not tab(v): out.append("%s = %s" % (key(k), val(v)))
    for k, v in d.items():
        sub = path + [key(k)]
        if isinstance(v, dict): out += ["", "[%s]" % ".".join(sub)]; emit(v, sub, out)
        elif tab(v):
            for item in v: out += ["", "[[%s]]" % ".".join(sub)]; emit(item, sub, out)
out = []
emit(t, [], out)
open(peer, "w").write("\n".join(out).lstrip("\n") + "\n")
PY
  sora=(--sora)
  nodes=(0)
else
  nodes=(0 1 2 3)
fi
for i in "${nodes[@]}"; do
  docker run -d --name "probe-n$i" --user "$U" --network host -v "$W:/work/out" --entrypoint iroha3d "$IMAGE" \
    "${sora[@]}" --config "/work/out/ln/peer$i.toml" >/dev/null
done
if [[ $row == r4 ]]; then
  sleep 25
  echo "-- r4: node0 state: $(docker inspect -f '{{.State.Status}} exit={{.State.ExitCode}}' probe-n0)"
  echo "-- r4: refusal text:"; docker logs probe-n0 2>&1 | grep -iE 'NPoS|lane topology|requires' | head -5
  docker logs probe-n0 2>&1 | tail -5 | cut -c1-300
  docker rm -f probe-n0 >/dev/null; exit 0
fi
sleep 20
cli() { docker run --rm --user "$U" --network host -v "$W:/work/out" --entrypoint iroha "$IMAGE" -c /work/out/ln/client.toml "$@"; }
echo "-- containers:"; docker ps -a --format '{{.Names}} {{.Status}}'
echo "-- node0 log tail:"; docker logs probe-n0 2>&1 | tail -6 | cut -c1-300
echo "-- ops sumeragi status:"; cli ops sumeragi status 2>&1 | head -c 700; echo
echo "-- one ping:"; cli ledger transaction ping --msg probe --fee-payer authority 2>&1 | head -c 600; echo
(while :; do cli ledger transaction ping --msg probe --fee-payer authority >/dev/null 2>&1; sleep 1; done) &
traffic=$!
end=$((SECONDS + SECS)); last=""
while ((SECONDS < end)); do
  h=$(cli ops sumeragi status 2>/dev/null | jq -r '.. | objects | select(has("height")) | .height' 2>/dev/null | sort -n | tail -1)
  echo "t=$((SECS - (end - SECONDS)))s height=${h:-?}"
  last=$h; sleep 5
done
kill "$traffic" 2>/dev/null
echo "-- final height ${last:-?}; decisive log lines (node0):"
docker logs probe-n0 2>&1 | grep -iE 'Pasta|epoch authority|MissingNext|epoch.*(end|boundary)|requires a provisioned' | sort -u | head -8 | cut -c1-400
for i in 0 1 2 3; do docker rm -f "probe-n$i" >/dev/null 2>&1; done
