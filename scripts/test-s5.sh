#!/usr/bin/env bash
# End-to-end test of the S5 pipeline with the REAL tools of the pinned images (docker; no cluster, throwaway keys, nothing kept):
# keygen-party.sh x4 (real kagami + rd-dfabi) -> mint-finality-roster -> assemble-s5.sh -> render-peer.sh x4 -> iroha3d --check-config.
# Needs docker, jq, python3. Env: NODE_IMAGE, DRIVER_IMAGE. Exit != 0 on any failure.
set -uo pipefail
cd "$(dirname "$0")/.."
NODE_IMAGE=${NODE_IMAGE:-ghcr.io/radityaaa43/iroha3-rd-node:071e281e-stark}
DRIVER_IMAGE=${DRIVER_IMAGE:-ghcr.io/radityaaa43/iroha3-rd-driver:33d5ffac}
W=$(mktemp -d "${TMPDIR:-/tmp}/s5test.XXXXXX"); chmod 700 "$W"; mkdir "$W/bin" "$W/tmp"
trap '[[ -n ${KEEP_TMP:-} ]] || rm -rf "$W"' EXIT # KEEP_TMP=1: debugging only (throwaway keys)
fails=0
fail() { echo "FAIL: $*" >&2; fails=$((fails + 1)); }
ok() { echo "ok:   $*"; }
U="$(id -u):$(id -g)"
wrap() { # <name> <entrypoint> <image>
  printf '#!/usr/bin/env bash\nexec docker run --rm -i --user %s -v %s:%s -w %s --entrypoint %s %s "$@"\n' "$U" "$W" "$W" "$W" "$2" "$3" > "$W/bin/$1"
  chmod +x "$W/bin/$1"
}
wrap kagami kagami "$NODE_IMAGE"; wrap iroha iroha "$NODE_IMAGE"; wrap rd-dfabi /usr/local/bin/rd-dfabi "$DRIVER_IMAGE"
export KAGAMI="$W/bin/kagami" IROHA="$W/bin/iroha" RDDFABI="$W/bin/rd-dfabi" TMPDIR="$W/tmp"

P="$W/public"; mkdir "$P"
lines=()
for p in bi bank-a bank-b bank-c; do
  line=$(network/keygen-party.sh "$p" "$W/custody-$p" 2>"$W/err") || { fail "keygen $p: $(tail -3 "$W/err")"; continue; }
  lines+=("$line")
  jq -e '.mint_finality.validator and .mint_finality.eq_proof_public_key and .mint_finality.ep_proof_public_key' <<<"$line" >/dev/null && ok "keygen $p prints its public mint-finality triple" || fail "keygen $p: no triple"
  [[ $(stat -c %s "$W/custody-$p/$p.mint-finality.seed") -eq 32 ]] && ok "keygen $p: 32-byte mint-finality seed stays in custody" || fail "keygen $p: seed size"
  grep -q 'mint-finality.seed\|private' <<<"$line" && fail "keygen $p printed a secret file name or key"
done
(( ${#lines[@]} == 4 )) || { echo "FAILED: keygen" >&2; exit 1; }
printf '%s\n' "${lines[@]}" | jq -s '[.[] | {party, public_key, pop_hex}]' > "$P/peers.json"
printf '%s\n' "${lines[@]}" | jq -s '(map({(.party): .account_public_key}) | add) + {"bi-gov": (map(select(.party=="bi"))[0].gov_account_public_key)}' > "$P/accounts.json"
i=0; tri=()
for l in "${lines[@]}"; do i=$((i + 1)); jq -c '.mint_finality' <<<"$l" > "$W/triple$i.json"; tri+=("$W/triple$i.json"); done
"$RDDFABI" keys mint-finality-roster "$P/kagemusha-mint-finality-public.json" "${tri[@]}" >/dev/null 2>"$W/err" && ok "roster built from the 4 public triples" || fail "roster: $(tail -2 "$W/err")"

# the signer: its own ed25519 key (throwaway), destroyed by the trap
"$KAGAMI" keys --algorithm ed25519 --out-dir "$W/signer" >/dev/null
export KEEP_TMP=${KEEP_TMP:-} GENESIS_PRIVATE_KEY_FILE="$W/signer/private.key" GENESIS_PUBLIC_KEY="$(tr -d '\n' < "$W/signer/public.key")" PUBLIC_DIR="$P" KEEP_MANIFEST="$W/manifest.json"
network/assemble-s5.sh 2>"$W/err" && ok "assemble-s5.sh signs" || { { fail "assemble-s5.sh"; sed -E "s/\x1b\[[0-9;]*m//g" "$W/err" | grep -v "^\s*$" | head -25 >&2; echo "FAILED" >&2; exit 1; }; }
for f in genesis.signed.nrt genesis.expected_hash genesis.public_key chain_id peer.template.toml; do [[ -s $P/$f ]] && ok "wrote $f" || fail "missing $f"; done
grep -q '^hash:' "$P/genesis.expected_hash" && ok "expected_hash has the hash: form" || fail "expected_hash: $(head -c 80 "$P/genesis.expected_hash")"

m="$W/manifest.json"
gen_id=$("$IROHA" tools address convert "$GENESIS_PUBLIC_KEY" | tail -1)
bi_id=$("$IROHA" tools address convert "$(jq -r .bi "$P/accounts.json")" | tail -1)
gov_id=$("$IROHA" tools address convert "$(jq -r '."bi-gov"' "$P/accounts.json")" | tail -1)
grants() { jq -r --arg n "$1" '[.transactions[].instructions[] | objects | select(.Grant.Permission.object.name? == $n) | .Grant.Permission.destination] | unique | join(",")' "$m"; }
[[ $(grants CanEnactGovernance) == "$gov_id" ]] && ok "S3: CanEnactGovernance only at bi-gov" || fail "CanEnactGovernance holders: $(grants CanEnactGovernance | cut -c1-60)"
[[ $(grants CanReadAllLedgerData) == "$bi_id" ]] && ok "S3: CanReadAllLedgerData only at bi" || fail "CanReadAllLedgerData holders: $(grants CanReadAllLedgerData | cut -c1-60)"
[[ $(jq -r '[.transactions[].parameters.custom // empty | .sumeragi_npos_parameters.payload.epoch_length_blocks // empty][0]' "$m") == ${EPOCH_LENGTH:-1152921504606846976} ]] \
  && ok "S5b: epoch_length_blocks = ${EPOCH_LENGTH:-2^60}" || fail "epoch_length_blocks: $(jq -c '[.transactions[].parameters.custom // empty | .sumeragi_npos_parameters.payload.epoch_length_blocks // empty]' "$m")"
[[ $(jq -r '[.transactions[].topology[]?.peer] | sort | join(",")' "$m") == $(jq -r '[.[].public_key] | sort | join(",")' "$P/peers.json") ]] && ok "topology = the 4 org peer keys" || fail "topology differs from peers.json"
[[ $(jq -r '[.kagemusha_mint_finality.epoch_roster.validators[].validator] | sort | join(",")' "$m") == $(jq -r '[.[].public_key] | sort | join(",")' "$P/peers.json") ]] && ok "mint-finality roster = the 4 org peer keys" || fail "roster differs"
[[ $(jq '[.transactions[].instructions[] | objects | select(has("RegisterPublicLaneValidator"))] | length' "$m") -eq 12 ]] && ok "12 lane validators (4 x lanes 0,1,2)" || fail "lane validator count"
for k in $(jq -r '.[].public_key' "$P/peers.json"); do grep -q -F "$k" "$m" || fail "peer key $k missing from the manifest"; done
for p in bi bank-a bank-b bank-c; do grep -q -F "$(jq -r --arg p "$p" '.[$p] // empty' "$P/accounts.json")" "$m" && fail "raw account public key of $p appears in the manifest (ids must be I105)"; done
n=$(jq '[.transactions[].instructions[] | if type=="object" then keys[0] else "frame" end] | length' "$m"); ok "manifest has $n instructions"

# per-org peer.toml: render with each org's own custody, then the real binary checks it against the signed genesis
if [[ -n ${RUN_CHAIN:-} ]]; then # all four peers on one docker network, addressed by container name
  jq -n '[ "bi","bank-a","bank-b","bank-c" | {(.): {dns: ("s5-" + . + ":1337"), external: ("s5-" + . + ":1337")}} ] | add' > "$P/peers.addr.json"
else
  jq -n '{"bi":{"dns":"bi-0.bi.rd-iroha3-bi.svc.cluster.local:1337","external":"192.0.2.1:1337"},
          "bank-a":{"dns":"bank-a-0.bank-a.rd-iroha3-bank-a.svc.cluster.local:1337","external":"192.0.2.2:1337"},
          "bank-b":{"dns":"bank-b-0.bank-b.rd-iroha3-bank-b.svc.cluster.local:1337","external":"192.0.2.3:1337"},
          "bank-c":{"dns":"bank-c-0.bank-c.rd-iroha3-bank-c.svc.cluster.local:1337","external":"192.0.2.4:1337"}}' > "$P/peers.addr.json"
fi
for p in bi bank-a bank-b bank-c; do
  out="$W/peer-$p.toml"
  network/render-peer.sh "$p" "$W/custody-$p" "$out" 2>"$W/err" || { fail "render-peer $p: $(tail -2 "$W/err")"; continue; }
  [[ $(stat -c %a "$out") == 600 ]] && ok "peer.toml of $p is 0600" || fail "peer.toml mode $(stat -c %a "$out")"
  if network/render-peer.sh "$p" "$W/custody-$p" "$out" 2>/dev/null; then fail "render-peer overwrote an existing file"; else ok "render-peer refuses to overwrite ($p)"; fi
  for q in bi bank-a bank-b bank-c; do [[ $q != "$p" ]] && grep -q -F "$(tr -d '\n' < "$W/custody-$q/validator/private.key")" "$out" && fail "peer.toml of $p carries the private key of $q"; done
  grep -q -F "$(tr -d '\n' < "$W/custody-$p/validator/private.key")" "$out" && ok "peer.toml of $p carries its own peer key" || fail "own key missing in $p"
  mkdir -p "$W/store-$p"
  res=$(docker run --rm --user "$U" -v "$out:/config/peer.toml:ro" -v "$P:/genesis:ro" --tmpfs /storage:rw,size=1g,mode=1777 \
        --entrypoint iroha3d "$NODE_IMAGE" --sora --check-config --config /config/peer.toml 2>&1 | tail -3)
  if grep -qiE 'error|invalid|fail' <<<"$res"; then fail "iroha3d --check-config $p: $(tr '\n' ' ' <<<"$res" | cut -c1-300)"; else ok "iroha3d --sora --check-config accepts the peer.toml of $p ($(tr '\n' ' ' <<<"$res" | cut -c1-80))"; fi
done
if [[ -n ${RUN_CHAIN:-} ]] && (( fails == 0 )); then
  # the four rendered peers form a chain from the signed genesis and commit blocks (CI; needs ~4 GB RAM)
  trap 'docker rm -f s5-bi s5-bank-a s5-bank-b s5-bank-c >/dev/null 2>&1; docker network rm s5net >/dev/null 2>&1; [[ -n ${KEEP_TMP:-} ]] || rm -r -- "$W"' EXIT
  docker network create s5net >/dev/null
  port=18080
  for p in bi bank-a bank-b bank-c; do
    docker run -d --name "s5-$p" --network s5net --user "$U" -p "$port:8080" -v "$W/peer-$p.toml:/config/peer.toml:ro" -v "$P:/genesis:ro" \
      --tmpfs "/storage:rw,size=2g,mode=0700,uid=$(id -u),gid=$(id -g)" --entrypoint iroha3d "$NODE_IMAGE" --sora --config /config/peer.toml >/dev/null || fail "start $p"
    port=$((port + 1))
  done
  h=0
  for n in $(seq 1 "${CHAIN_WAIT:-120}"); do
    st=$(curl -s --max-time 4 http://127.0.0.1:18080/status)
    h=$(jq -r '.blocks // 0' <<<"$st" 2>/dev/null || echo 0)
    ((n % 6 == 1)) && echo "t=$((n * 5))s height=$h peers=$(jq -r '.peers // "?"' <<<"$st" 2>/dev/null) running=$(docker ps -q --filter name=s5- | wc -l)/4"
    [[ $(docker ps -q --filter name=s5- | wc -l) -eq 4 ]] || { fail "a peer container stopped"; break; }
    ((h >= ${CHAIN_BLOCKS:-3})) && break
    sleep 5
  done
  docker stats --no-stream --format 'cpu {{.Name}} {{.CPUPerc}} mem {{.MemUsage}}' 2>/dev/null | grep s5- || true
  echo "host: $(nproc) cpus, $(free -m | awk 'NR==2{print $2" MB total, "$7" MB available"}')"
  seen=$(curl -s --max-time 4 http://127.0.0.1:18080/status | jq -r '.peers // "?"')
  if ((h >= ${CHAIN_BLOCKS:-3})); then ok "4 peers from the signed genesis commit blocks: height $h, peers seen by bi: $seen"; else
    fail "no progress: height $h"
    for p in bi bank-b; do
      echo "-- s5-$p: first 25 WARN/ERROR lines (noise filtered)"
      docker logs "s5-$p" 2>&1 | grep -E ' (ERROR|WARN) ' | grep -vE 'peer_monitor|alias|onboard' | sed -E 's/HeightContextId\(\{[^}]*\}\)/HCID/g; s/\{[^}]{80,}\}/{..}/g' | head -25 | cut -c1-420
      echo "-- s5-$p: lines mentioning view / lane / beacon / mint"
      docker logs "s5-$p" 2>&1 | grep -iE 'view change|new view|fastpq|beacon|mint.finality|lane validator' | sed -E 's/HeightContextId\(\{[^}]*\}\)/HCID/g; s/\{[^}]{80,}\}/{..}/g' | head -12 | cut -c1-420
    done
  fi
fi
if (( fails )); then echo "FAILED: $fails check(s)" >&2; exit 1; fi
echo "PASS"
