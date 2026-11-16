#!/usr/bin/env bash
# Offline test (jq, python3; no docker, no keys) of the neutral genesis and the sponsor account (APS conformance design 4.1, 4.4):
#  1. network/nexus.toml: dataspace/lane aliases ds-1/ds-2 and lane-1/lane-2, descriptions neutral, no rd|dfabi|rupiah in catalog or routing;
#     lane index == dataspace id (the genesis read grants rely on it).
#  2. network/genesis-rd-dfabi.jq and network/genesis-rd-dfabi-s5.jq register the `sponsor` account, fund it with XOR for fees, give it
#     CanReadRestrictedDataspace on every restricted dataspace ONLY when $sponsor_read is true, and never write a pool.
# The integration of the same rows over the real kagami output is scripts/test-s5.sh (docker, CI s5-test.yml) and network/check.sh.
set -uo pipefail
cd "$(dirname "$0")/.."
fails=0
fail() { echo "FAIL: $*" >&2; fails=$((fails + 1)); }
ok() { echo "ok:   $*"; }

# ---- 1. nexus.toml
if python3 -I - network/nexus.toml <<'PY'
import re, sys, tomllib
n = tomllib.load(open(sys.argv[1], "rb"))["nexus"]
lanes, dss = n["lane_catalog"], n["dataspace_catalog"]
assert [d["alias"] for d in dss] == ["universal", "ds-1", "ds-2"], [d["alias"] for d in dss]
assert [l["alias"] for l in lanes] == ["universal", "lane-1", "lane-2"], [l["alias"] for l in lanes]
assert [l["dataspace"] for l in lanes] == [d["alias"] for d in dss]
assert [l["index"] for l in lanes] == [d["id"] for d in dss] == [0, 1, 2]
assert [d["description"] for d in dss][1:] == ["private settlement dataspace 1", "private settlement dataspace 2"], [d["description"] for d in dss]
strings = []
def walk(o):
    if isinstance(o, dict):
        for v in o.values(): walk(v)
    elif isinstance(o, list):
        for v in o: walk(v)
    elif isinstance(o, str): strings.append(o)
for part in (n["lane_catalog"], n["dataspace_catalog"], n["routing_policy"]): walk(part)
bad = [s for s in strings if re.search(r"rd|dfabi|rupiah", s, re.I)]
assert not bad, bad
PY
then ok "nexus.toml: ds-1/ds-2, lane-1/lane-2, neutral descriptions, no rd|dfabi|rupiah in catalog or routing"; else fail "nexus.toml is not the neutral catalog"; fi

# ---- 2. the two genesis overlays
SPONSOR=sponsor-account-id
for f in network/genesis-rd-dfabi.jq network/genesis-rd-dfabi-s5.jq; do
  for sr in false true; do
    out=$(jq -n '{transactions: []}' | jq --arg bi BI --arg gov GOV --arg a A --arg b B --arg c C --arg gen GEN --arg rd RDID --arg dfabi DFID \
      --arg domain wonderland.ds-1 --argjson readds '[1,2]' --arg sponsor "$SPONSOR" --argjson sponsor_read "$sr" -f "$f" 2>&1) \
      || { fail "$f sponsor_read=$sr: jq failed: ${out:0:200}"; continue; }
    ins='[.transactions[].instructions[] | objects]'
    n=$(jq --arg s "$SPONSOR" "$ins | [.[] | select(.Register.Account.id? == \$s)] | length" <<<"$out")
    [[ $n == 1 ]] && ok "$f sponsor_read=$sr: sponsor account registered once" || fail "$f sponsor_read=$sr: sponsor Register.Account count $n"
    n=$(jq --arg s "$SPONSOR" "$ins | [.[] | select(.Mint.Asset.destination? == (\"6TEAJqbb8oEPmLncoNiMRbLEK6tw#\" + \$s) and .Mint.Asset.object == \"1000\")] | length" <<<"$out")
    [[ $n == 1 ]] && ok "$f sponsor_read=$sr: sponsor funded with 1000 XOR for fees" || fail "$f sponsor_read=$sr: sponsor XOR mint count $n"
    n=$(jq --arg s "$SPONSOR" "$ins | [.[] | select(.Grant.Permission.destination? == \$s)] | length" <<<"$out")
    r=$(jq --arg s "$SPONSOR" "$ins | [.[] | select(.Register.Role.grant_to? == \$s)] | length" <<<"$out")
    d=$(jq -c --arg s "$SPONSOR" "$ins | [.[] | select(.Grant.Permission.destination? == \$s) | .Grant.Permission.object | select(.name == \"CanReadRestrictedDataspace\") | .payload.dataspace] | sort" <<<"$out")
    if [[ $sr == false ]]; then
      [[ $n == 0 && $r == 0 ]] && ok "$f: sponsor_read=false -> no permission, no role for the sponsor" || fail "$f: sponsor_read=false but $n grants / $r roles for the sponsor"
    else
      [[ $n == 2 && $r == 2 && $d == "[1,2]" ]] && ok "$f: sponsor_read=true -> CanReadRestrictedDataspace on dataspaces 1 and 2 (direct + role)" || fail "$f: sponsor_read=true: $n grants $d, $r roles"
    fi
    # the three readers (bi, a, b) and the outsider c are unchanged by the sponsor: 3 readers x 2 dataspaces, c none
    n=$(jq "$ins | [.[] | select(.Grant.Permission.object.name? == \"CanReadRestrictedDataspace\") | .Grant.Permission.destination] | map(select(. != \"$SPONSOR\")) | unique | length" <<<"$out")
    [[ $n == 3 ]] && ok "$f sponsor_read=$sr: the 3 party readers are unchanged" || fail "$f sponsor_read=$sr: reader accounts $n, want 3"
    if grep -qi 'pool' <<<"$out"; then fail "$f sponsor_read=$sr: genesis writes a pool (activation needs height >= 11, never genesis)"; else ok "$f sponsor_read=$sr: no pool in genesis"; fi
  done
done

# ---- 3. network/check-genesis.py (the genesis rows of network/check.sh) follows the SPONSOR_READ genesis parameter
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
gen() { jq -n '{transactions: []}' | jq --arg bi BI --arg a A --arg b B --arg c C --arg gen GEN --arg rd RDID --arg dfabi DFID --arg domain wonderland.ds-1 \
  --argjson readds '[1,2]' --arg sponsor "$SPONSOR" --argjson sponsor_read "$1" -f network/genesis-rd-dfabi.jq; }
gen false > "$T/g0.json"; gen true > "$T/g1.json"
# pool activation smuggled in (wrapped, any depth) must be caught by its instruction name
jq '.transactions[0].instructions += [{Custom:{payload:{ActivatePrivateSettlementPoolV1:{}}}}]' "$T/g0.json" > "$T/gpool.json"
# a pool-ish word elsewhere (a description) is not an activation: the old substring check refused this
jq '.transactions[1].instructions[1].Register.AssetDefinition.description += " pool of RD"' "$T/g0.json" > "$T/gword.json"
# sponsor with a direct read grant but no role, and with a read grant on only one dataspace
jq 'del(.transactions[0].instructions[] | select(.Register.Role.grant_to? == "sponsor-account-id"))' "$T/g1.json" > "$T/g1norole.json"
jq 'del(.transactions[0].instructions[] | select(.Grant.Permission.destination? == "sponsor-account-id" and .Grant.Permission.object.payload.dataspace == 2))' "$T/g1.json" > "$T/g1one.json"
cg() { python3 -I network/check-genesis.py "$1" network/nexus.toml "$SPONSOR" "$2" >/dev/null 2>&1; }
cg "$T/g0.json" 0 && ok "check-genesis: SPONSOR_READ=0, sponsor without permission passes" || fail "check-genesis: SPONSOR_READ=0 on a genesis without sponsor permission"
cg "$T/g1.json" 1 && ok "check-genesis: SPONSOR_READ=1, sponsor reads dataspaces 1 and 2 (direct + role) and nothing else passes" || fail "check-genesis: SPONSOR_READ=1 on a genesis with the sponsor read grants"
cg "$T/g1.json" 0 && fail "check-genesis: SPONSOR_READ=0 accepts a sponsor that holds read grants" || ok "check-genesis: SPONSOR_READ=0 refuses a sponsor that holds read grants"
cg "$T/g0.json" 1 && fail "check-genesis: SPONSOR_READ=1 accepts a sponsor without read grants" || ok "check-genesis: SPONSOR_READ=1 refuses a sponsor without read grants"
cg "$T/g1norole.json" 1 && fail "check-genesis: SPONSOR_READ=1 accepts a sponsor without the role" || ok "check-genesis: SPONSOR_READ=1 refuses a sponsor without the role"
cg "$T/g1one.json" 1 && fail "check-genesis: SPONSOR_READ=1 accepts a sponsor missing dataspace 2" || ok "check-genesis: SPONSOR_READ=1 refuses a sponsor missing dataspace 2"
cg "$T/gpool.json" 0 && fail "check-genesis: accepts a genesis that activates a pool" || ok "check-genesis: refuses ActivatePrivateSettlementPoolV1 in the genesis instructions"
cg "$T/gword.json" 0 && ok "check-genesis: the word pool in a description is not a pool activation" || fail "check-genesis: refuses a genesis only for the word pool in a description"

if (( fails )); then echo "FAILED: $fails check(s)" >&2; exit 1; fi
echo "PASS"
