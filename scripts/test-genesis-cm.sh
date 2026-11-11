#!/usr/bin/env bash
# Offline test of deploy/peers/genesis-cm.sh (prints a manifest; no cluster, no kubectl). Needs bash, python3 + PyYAML.
set -uo pipefail
cd "$(dirname "$0")/.."
G=$PWD/deploy/peers/genesis-cm.sh
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fails=0
fail() { echo "FAIL: $*" >&2; fails=$((fails + 1)); }
ok() { echo "ok:   $*"; }
H64=A3D75EEA3228F8C6C8AD05DD409FAB3CE861C25C0D5162044E7EA384856CE37B
mk() { # <dir> <expected_hash content>
  mkdir -p "$1"; printf 'NRT-MARKER\x00\x01\xff' > "$1/genesis.signed.nrt"; printf '%s\n' "$2" > "$1/genesis.expected_hash"
}
refuse() { # <label> <reason> <args...>
  local label=$1 reason=$2; shift 2
  local out rc; out=$("$G" "$@" 2>&1); rc=$?
  [[ $rc -eq 2 && $out == *"$reason"* ]] && ok "refuses $label (exit 2)" || fail "$label: rc=$rc $out"
}
mk "$T/p" "hash:${H64}#AAF1"
for party in bi bank-a bank-b bank-c; do
  out=$("$G" $party "$T/p" 2>&1) || { fail "$party: rc=$? $out"; continue; }
  python3 -I -c '
import sys, yaml, base64, os
party, pub = sys.argv[1], sys.argv[2]
docs = [d for d in yaml.safe_load_all(sys.stdin) if d]
assert len(docs) == 1, "want exactly one document, got %d" % len(docs)
d = docs[0]
raw = open(pub + "/genesis.signed.nrt", "rb").read()
h = open(pub + "/genesis.expected_hash").read().strip()
assert d["kind"] == "ConfigMap" and d["apiVersion"] == "v1", "kind/apiVersion"
assert d["metadata"]["name"] == "genesis-" + h[len("hash:"):len("hash:") + 8].lower(), "name %s" % d["metadata"]["name"]
assert d["metadata"]["namespace"] == "rd-iroha3-" + party, "namespace"
assert d["metadata"]["labels"] == {"app.kubernetes.io/part-of": "rd-iroha3", "rd-iroha3/party": party}, "labels"
assert d["immutable"] is True, "immutable"
assert set(d["binaryData"]) == {"genesis.signed.nrt"} and base64.b64decode(d["binaryData"]["genesis.signed.nrt"]) == raw, "binaryData"
# iroha3d requires the file to hold exactly one LF-terminated identity (live S7b: "must contain exactly one LF-terminated canonical public identity")
assert set(d["data"]) == {"genesis.expected_hash"} and d["data"]["genesis.expected_hash"] == h + "\n", "data must be the hash plus exactly one LF"
open(sys.argv[3], "w", newline="").write(d["data"]["genesis.expected_hash"])
' "$party" "$T/p" "$T/cm-value.$party" <<<"$out" && ok "$party: manifest structure" || fail "$party: manifest structure"
  # what the pod mounts (the ConfigMap VALUE) must be byte-identical to the disk file that `iroha3d --check-config` accepted
  cmp -s "$T/cm-value.$party" "$T/p/genesis.expected_hash" && ok "$party: ConfigMap value is byte-identical to genesis.expected_hash (one LF)" || fail "$party: ConfigMap value differs from the file the node check accepts"
done
[[ $("$G" bi "$T/p" | grep -c '^  name: genesis-a3d75eea$') -eq 1 ]] && ok "hash8 = first 8 hex chars after hash: (lowercased)" || fail "hash8 derivation"
before=$(find "$T" -type f | sort | xargs cksum)
"$G" bi "$T/p" >/dev/null; [[ $(find "$T" -type f | sort | xargs cksum) == "$before" ]] && ok "writes nothing" || fail "files changed"
[[ -f network/public/genesis.expected_hash && -f network/public/genesis.signed.nrt ]] && { [[ $("$G" bi network/public | grep -c "^  name: genesis-a3d75eea$") -eq 1 ]] && ok "real network/public accepted" || fail "real network/public"; }
refuse "no argument" "usage"
refuse "one argument" "usage" bi
refuse "an unknown party" "unknown party" nobody "$T/p"
refuse "a missing public dir" "not found" bi "$T/none"
mk "$T/b1" "hash:short#AAF1"; refuse "a short hash" "genesis.expected_hash" bi "$T/b1"
mk "$T/b2" "${H64}#AAF1"; refuse "a hash without the hash: prefix" "genesis.expected_hash" bi "$T/b2"
mk "$T/b3" "hash:${H64}"; refuse "a hash without #crc" "genesis.expected_hash" bi "$T/b3"
mk "$T/b4" "hash:${H64}#AAF1
extra"; refuse "a multi-line expected_hash" "genesis.expected_hash" bi "$T/b4"
mk "$T/b5" "hash:${H64/A/g}#AAF1"; refuse "a non-hex hash" "genesis.expected_hash" bi "$T/b5"
mkdir "$T/m"; printf 'x' > "$T/m/genesis.signed.nrt"; refuse "a missing expected_hash" "is missing" bi "$T/m"
mkdir "$T/m2"; echo "hash:${H64}#AAF1" > "$T/m2/genesis.expected_hash"; refuse "a missing genesis.signed.nrt" "is missing" bi "$T/m2"
for f in a.seed a.note a.hybrid private.key; do
  mk "$T/x-$f" "hash:${H64}#AAF1"; echo MARKER > "$T/x-$f/$f"; refuse "a public dir holding $f" "private material" bi "$T/x-$f"
done
if (( fails )); then echo "FAILED: $fails check(s)" >&2; exit 1; fi
echo "PASS"
