#!/usr/bin/env bash
# G1b lane check on the live network: per peer, per lane (default 0 1 2)
#   1. lane exists in /status teu_lane_commit
#   2. EXPECT_VALIDATORS (4) Active validators (GET /v1/nexus/public-lanes/<lane>/validators)
#   3. lane block height increases between two samples INTERVAL seconds apart
# Read-only HTTP GETs on Torii. Prints a PASS/FAIL table; exit != 0 on any FAIL.
#
# Caveats from upstream @071e281e:
#  - The validators route answers 404 for non-public lanes (torii_route_for_public_lane_id,
#    crates/iroha_torii/src/lib.rs:19037). For a restricted lane the count is unverifiable
#    here and counts as FAIL unless RESTRICTED_VALIDATORS=skip.
#  - An idle chain commits no blocks (heights stay flat). Set TRAFFIC_CMD to a command that
#    sends a tx (e.g. the smoke.sh ping) and runs between the two samples.
#    TRAFFIC_CMD must send traffic into every checked lane, or idle lanes FAIL.
# Needs curl + jq.
set -euo pipefail

PEERS=(bi bank-a bank-b bank-c)
declare -A URL=(
  [bi]=${TORII_BI:-http://127.0.0.1:38080}
  [bank-a]=${TORII_BANK_A:-http://127.0.0.1:38081}
  [bank-b]=${TORII_BANK_B:-http://127.0.0.1:38082}
  [bank-c]=${TORII_BANK_C:-http://127.0.0.1:38083}
)
LANES=${LANES:-"0 1 2"}
EXPECT_VALIDATORS=${EXPECT_VALIDATORS:-4}
INTERVAL=${INTERVAL:-5}
RESTRICTED_VALIDATORS=${RESTRICTED_VALIDATORS:-fail}   # fail | skip
TRAFFIC_CMD=${TRAFFIC_CMD:-}

get() { curl -fsS -m 10 -H 'Accept: application/json' "$1"; }  # get <url>

# lane_height <peer> <lane>: latest lane block height, empty if the lane is absent
lane_height() {
  get "${URL[$1]}/status" | jq -r --argjson l "$2" '.teu_lane_commit[]? | select(.lane_id == $l) | .block_height'
}
# lane_visibility <peer> <lane>: public | restricted | "" (absent)
lane_visibility() {
  get "${URL[$1]}/status" | jq -r --argjson l "$2" '.dataspace_catalog[]? | select(.lane_id == $l) | .visibility'
}
# active_validators <peer> <lane>: number of Active validators; "404" when the route refuses the lane
active_validators() {
  local body code
  body=$(curl -sS -m 10 -H 'Accept: application/json' -w '\n%{http_code}' "${URL[$1]}/v1/nexus/public-lanes/$2/validators") || { echo err; return; }
  code=${body##*$'\n'}
  [[ $code == 200 ]] || { echo "$code"; return; }
  jq -r '[.items[]? | select(.status.type == "Active")] | length' <<<"${body%$'\n'*}"
}

declare -A h1 h2 vis val
for p in "${PEERS[@]}"; do
  for l in $LANES; do
    h1[$p/$l]=$(lane_height "$p" "$l" 2>/dev/null || echo err)
    vis[$p/$l]=$(lane_visibility "$p" "$l" 2>/dev/null || echo err)
    val[$p/$l]=$(active_validators "$p" "$l" 2>/dev/null || echo err)
  done
done

if [[ -n $TRAFFIC_CMD ]]; then bash -c "$TRAFFIC_CMD" >&2 || echo "warning: TRAFFIC_CMD failed (exit $?)" >&2; fi
sleep "$INTERVAL"

for p in "${PEERS[@]}"; do
  for l in $LANES; do h2[$p/$l]=$(lane_height "$p" "$l" 2>/dev/null || echo err); done
done

fails=0
printf '%-7s %-4s %-10s %-10s %-8s %-8s %s\n' PEER LANE VISIBILITY VALIDATORS H1 H2 RESULT
for p in "${PEERS[@]}"; do
  for l in $LANES; do
    k=$p/$l why=()
    a=${h1[$k]} b=${h2[$k]} v=${val[$k]}
    if [[ -z $a || $a == err ]]; then why+=("lane absent or peer unreachable")
    elif ! [[ $a =~ ^[0-9]+$ && $b =~ ^[0-9]+$ && $b -gt $a ]]; then why+=("height not increasing")
    fi
    if [[ $v == "$EXPECT_VALIDATORS" ]]; then :
    elif [[ $v == 404 && ${vis[$k]} == restricted && $RESTRICTED_VALIDATORS == skip ]]; then v="404(skip)"
    else why+=("active validators '$v' != $EXPECT_VALIDATORS")
    fi
    if ((${#why[@]})); then r="FAIL: $(IFS=';'; echo "${why[*]}")"; fails=$((fails + 1)); else r=PASS; fi
    printf '%-7s %-4s %-10s %-10s %-8s %-8s %s\n' "$p" "$l" "${vis[$k]:--}" "$v" "${a:--}" "${b:--}" "$r"
  done
done
((fails == 0)) && echo "PASS" || { echo "FAIL: $fails lane check(s)" >&2; exit 1; }
