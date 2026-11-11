#!/usr/bin/env bash
# Smoke check of the MOUNTED layout: materialize the files exactly as the pod sees them (the ConfigMap that deploy/peers/genesis-cm.sh
# prints, decoded as kubelet does: binaryData -> bytes, data -> string) and run the REAL `iroha3d --sora --check-config` on them with a
# peer.toml. Not the disk files: the live S7b crash (expected_hash without LF) passed every disk-file check.
#   scripts/smoke-genesis-mount.sh <party> <public-dir> <peer.toml> [--strip-lf]
# --strip-lf feeds the OLD buggy value (no trailing LF): the check must then FAIL (negative control). Needs docker, python3+PyYAML.
# Env: NODE_IMAGE, GENESIS_CM (script to test; default deploy/peers/genesis-cm.sh, e.g. the old one from `git show origin/main~N:...`). peer.toml is read only (mounted ro); nothing is printed from it.
set -uo pipefail
cd "$(dirname "$0")/.."
NODE_IMAGE=${NODE_IMAGE:-ghcr.io/radityaaa43/iroha3-rd-node:071e281e-stark}
party=${1:?party} pub=${2:?public-dir} toml=${3:?peer.toml} strip=${4:-}
T=$(mktemp -d); chmod 700 "$T"; trap 'rm -r -- "$T"' EXIT
${GENESIS_CM:-deploy/peers/genesis-cm.sh} "$party" "$pub" | python3 -I -c '
import sys, base64, yaml
d = yaml.safe_load(sys.stdin)
out, strip = sys.argv[1], sys.argv[2] == "--strip-lf"
open(out + "/genesis.signed.nrt", "wb").write(base64.b64decode(d["binaryData"]["genesis.signed.nrt"]))
v = d["data"]["genesis.expected_hash"]
open(out + "/genesis.expected_hash", "w", newline="").write(v.rstrip("\n") if strip else v)
' "$T" "$strip" || { echo "smoke: could not materialize the ConfigMap" >&2; exit 2; }
chmod 755 "$T"; chmod 644 "$T"/genesis.*
res=$(docker run --rm --user "$(id -u):$(id -g)" -v "$toml:/config/peer.toml:ro" -v "$T:/genesis:ro" \
  --tmpfs "/storage:rw,size=1g,mode=0700,uid=$(id -u),gid=$(id -g)" --entrypoint iroha3d "$NODE_IMAGE" --sora --check-config --config /config/peer.toml 2>&1 \
  | sed -E 's/\x1b\[[0-9;]*m//g' | tail -4 | tr '\n' ' ')
echo "iroha3d --check-config on the mounted ConfigMap layout${strip:+ ($strip)}: $res"
if grep -q 'Ready: configuration and available genesis are valid' <<<"$res"; then exit 0; else exit 1; fi
