#!/usr/bin/env bash
# G1 smoke test on the live 4-peer network in namespace iroha3.
#   1. all 4 peers at the same height > 0 with the same block hash
#   2. ping tx from client-bi -> Applied
#   3. BI peer down (replicas=0); ping tx from client-bank-a -> Applied by 3 validators
#   4. BI peer up; BI reaches bank-a's height and block hash within 120 s of Ready
# Exit != 0 names the failed step. Prints only public data (heights, hashes, timings).
# Needs kubectl + jq and the gha-deployer Role (no statefulsets/scale: replicas are patched).
set -euo pipefail

NS=iroha3
IMAGE=ghcr.io/radityaaa43/iroha3-rd-node:071e281e-stark
PARTIES=(bi bank-a bank-b bank-c)
k() { kubectl -n "$NS" "$@"; }
fail() { echo "FAIL step $1: $2" >&2; exit 1; }

cleanup() {
  # never leave BI down or client pods behind
  k patch sts bi -p '{"spec":{"replicas":1}}' >/dev/null || true
  k delete pod -l app.kubernetes.io/name=smoke-client --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

torii() { # torii <party> <path>
  k exec "$1-0" -c iroha3d -- sh -c "curl -fsS -H 'Accept: application/json' 'localhost:8080$2'"
}
height() { torii "$1" /status | jq -er .blocks; }
block_hash() { torii "$1" "/v1/explorer/blocks/$2" | jq -er .hash; }

# Same height on every listed party (polls up to $2 s); prints "height hash".
converged() { # converged "<parties>" <timeout_s>
  local deadline=$((SECONDS + $2)) h hs p
  while :; do
    hs=$(for p in $1; do height "$p" || echo x; done | sort -u)
    if [[ $(wc -l <<<"$hs") -eq 1 && $hs =~ ^[0-9]+$ && $hs -gt 0 ]]; then
      h=$hs
      hs=$(for p in $1; do block_hash "$p" "$h" || echo x; done | sort -u)
      [[ $(wc -l <<<"$hs") -eq 1 && $hs =~ ^[0-9a-f]{64}$ ]] && { echo "$h $hs"; return 0; }
    fi
    ((SECONDS < deadline)) || return 1
    sleep 2
  done
}

client_pod() { # client_pod <party>: pod with only that party's client Secret
  k apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: smoke-client-$1
  labels: {app.kubernetes.io/name: smoke-client}
spec:
  automountServiceAccountToken: false
  enableServiceLinks: false
  restartPolicy: Never
  activeDeadlineSeconds: 1800
  securityContext: {runAsNonRoot: true, runAsUser: 1001, runAsGroup: 1001, fsGroup: 1001, seccompProfile: {type: RuntimeDefault}}
  containers:
    - name: cli
      image: $IMAGE
      command: [sleep, "1800"]
      workingDir: /client
      resources: {requests: {cpu: 50m, memory: 64Mi}, limits: {cpu: 500m, memory: 512Mi}}
      securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: [ALL]}}
      # subPath: regular files, not ..data symlinks; client.toml reads genesis.expected_hash relatively
      volumeMounts:
        - {name: client, mountPath: /client/client.toml, subPath: client.toml, readOnly: true}
        - {name: client, mountPath: /client/genesis.expected_hash, subPath: genesis.expected_hash, readOnly: true}
  volumes:
    - name: client
      secret: {secretName: client-$1, defaultMode: 0440}
EOF
  k wait --for=condition=Ready "pod/smoke-client-$1" --timeout=180s >/dev/null
}

# ping_tx <party> <msg>: submit via the party's own Torii, wait for Applied, print block height.
ping_tx() {
  local out hash st
  out=$(k exec "smoke-client-$1" -- iroha --config client.toml --machine --fee-payer authority \
          ledger transaction ping --msg "$2") || return 1
  hash=$(jq -er .hash <<<"$out") || return 1
  st=$(k exec "smoke-client-$1" -- iroha --config client.toml --machine \
         ledger transaction status --hash "$hash" --wait --timeout-ms 60000) || return 1
  echo "  tx $hash $(jq -c '{terminal_kind, block_height}' <<<"$st")" >&2
  jq -e '.terminal_kind == "Applied"' <<<"$st" >/dev/null || return 1
  jq -er .block_height <<<"$st"
}

echo "== step 1: 4 peers converged"
r=$(converged "${PARTIES[*]}" 60) || fail 1 "peers not at one height/hash within 60 s"
echo "  height/hash: $r"

echo "== step 2: ping from client-bi"
client_pod bi
client_pod bank-a
h2=$(ping_tx bi "smoke-g1-bi-$(date +%s)") || fail 2 "tx from client-bi not Applied"
r=$(converged "${PARTIES[*]}" 60) || fail 2 "peers did not converge after tx (block $h2)"
echo "  applied in block $h2; converged $r"

echo "== step 3: BI down, ping from client-bank-a"
k patch sts bi -p '{"spec":{"replicas":0}}' >/dev/null
k wait --for=delete pod/bi-0 --timeout=180s >/dev/null || fail 3 "bi-0 did not terminate"
h3=$(ping_tx bank-a "smoke-g1-bank-a-bi-down-$(date +%s)") || fail 3 "tx from client-bank-a not Applied with BI down"
r3=$(converged "bank-a bank-b bank-c" 60) || fail 3 "3 banks did not converge (block $h3)"
echo "  applied in block $h3 without BI; banks at $r3"

echo "== step 4: BI up, catch-up"
k patch sts bi -p '{"spec":{"replicas":1}}' >/dev/null
for _ in $(seq 60); do k get pod bi-0 >/dev/null 2>&1 && break; sleep 2; done
k wait --for=condition=Ready pod/bi-0 --timeout=600s >/dev/null || fail 4 "bi-0 not Ready within 600 s"
t0=$SECONDS
read -r want_h want_hash < <(converged "bank-a" 10) || fail 4 "cannot read bank-a head"
deadline=$((SECONDS + 120))
until [[ $(height bi 2>/dev/null) -ge $want_h ]] && [[ $(block_hash bi "$want_h" 2>/dev/null) == "$want_hash" ]]; do
  ((SECONDS < deadline)) || fail 4 "bi did not reach bank-a height $want_h / hash $want_hash within 120 s"
  sleep 2
done
echo "  bi caught up to $want_h $want_hash in $((SECONDS - t0)) s after Ready"
r=$(converged "${PARTIES[*]}" 60) || fail 4 "4 peers not converged after catch-up"
echo "  final: $r"
echo "PASS"
