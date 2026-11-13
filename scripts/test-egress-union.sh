#!/usr/bin/env bash
# Offline test of scripts/check-egress-union.py on the REAL renders of one namespace (peers + driver + gateway + auditor [+ pool-init in bi]): each role is selected by exactly its own Egress
# policy; mutants (an extra policy, a wildcard policy, an allow-all, a missing policy) must FAIL. The same checker reads a live `get netpol -o json` List in the apply texts.
set -uo pipefail
cd "$(dirname "$0")/.."
C=scripts/check-egress-union.py
fails=0; fail() { echo "FAIL: $*" >&2; fails=$((fails + 1)); }; ok() { echo "ok:   $*"; }
T=$(mktemp -d); trap 'find "$T" -delete' EXIT
D=sha256:$(printf 'a%.0s' $(seq 1 64)); H=0123abcd; CIDR=203.0.113.10/32
H64=$(printf '0123456789abcdef%.0s' 1 2 3 4)
P="$T/public"; mkdir -p "$P/gateway-ca"
echo 11111111-2222-4333-8444-555555555555 > "$P/chain_id"; printf 'hash:%s#ABCD\n' "${H64^^}" > "$P/genesis.expected_hash"
jq -n '[ "bi","bank-a","bank-b","bank-c" | {party: ., public_key: ("ea0130" + .), pop_hex: "0xaa"} ]' > "$P/peers.json"
jq -n '{"bi":"ed0120b1","bank-a":"ed0120b2","bank-b":"ed0120b3","bank-c":"ed0120b4","bi-gov":"ed0120b5"}' > "$P/accounts.json"
for q in bi bank-a bank-b bank-c; do printf -- '-----BEGIN CERTIFICATE-----\nMIIB%s\n-----END CERTIFICATE-----\n' "$q" > "$P/gateway-ca/$q-server-ca.pem"; done
EI=envoyproxy/envoy@sha256:$(printf 'b%.0s' $(seq 1 64)); OI=openpolicyagent/opa@sha256:$(printf 'c%.0s' $(seq 1 64))
DX=()  # extra driver render args (the --aps loop below)
ns_render() { # <party> -> all renders of that namespace on stdout
  local p=$1
  deploy/peers/render.sh --p2p-egress-cidr 198.51.100.7/32 "$p" $H $CIDR
  echo "---"; deploy/driver/render.sh "$p" "$D" "$P" --audit-tls ${DX[@]+"${DX[@]}"}
  echo "---"; deploy/gateway/render.sh "$p" --envoy-image "$EI" --opa-image "$OI"
  echo "---"; deploy/auditor/render.sh "$p" "$D" "$P"
  if [[ $p == bi ]]; then echo "---"; deploy/pool-init/render.sh "$D" "$P" 1000 100; fi
}
for p in bi bank-a bank-b; do
  out=$(ns_render "$p" 2>&1) || { fail "$p: a render failed: ${out:0:300}"; continue; }
  roles=(peer=peers-egress driver=driver-egress gateway=gateway-egress auditor=auditor-egress); [[ $p == bi ]] && roles+=(pool-init=pool-init-egress)
  python3 -I "$C" "$p" "${roles[@]}" <<<"$out" || fails=$((fails + 1))
done
# --aps (APS all-flows): the driver of every party still has exactly driver-egress selecting it (BI: also the bank-c /32 of the gw-tls sidecar); bank-c as well
jq -n '{rd: {pool_id: ("7e" * 32), route: "cm91dGU=", policy: "cG9saWN5", governance: "Z292ZXJuYW5jZQ==", origin: [("ab" * 32), ("cd" * 32)], bundles: []}} | .dfabi = .rd' > "$T/pools.json"
for p in bi bank-a bank-b; do
  DX=(--aps --aps-pools "$T/pools.json"); [[ $p == bi ]] && DX=(--aps --remote-gw bank-c=203.0.113.30)  # BI keeps its pools on the PVC: no --aps-pools
  out=$(ns_render "$p" 2>&1) || { fail "$p --aps: a render failed: ${out:0:300}"; continue; }
  roles=(peer=peers-egress driver=driver-egress gateway=gateway-egress auditor=auditor-egress); [[ $p == bi ]] && roles+=(pool-init=pool-init-egress)
  python3 -I "$C" "$p-aps" "${roles[@]}" <<<"$out" || fails=$((fails + 1))
done
DX=()
# bank-c (cluster 2): peers + driver + gateway only (no auditor/pool-init there)
out=$( { deploy/peers/render.sh --cluster 2 --p2p-egress-cidr 198.51.100.7/32 bank-c $H $CIDR; echo "---"; deploy/driver/render.sh bank-c "$D" "$P" --audit-tls --remote-gw bi=203.0.113.20 --remote-gw bank-a=203.0.113.21 --remote-gw bank-b=203.0.113.22; echo "---"; deploy/gateway/render.sh bank-c --envoy-image "$EI" --opa-image "$OI" --cluster 2 --lb-acl acl-x --lb-range 203.0.113.9/32; } 2>&1) || fail "bank-c: a render failed: ${out:0:300}"
python3 -I "$C" bank-c peer=peers-egress driver=driver-egress gateway=gateway-egress <<<"$out" || fails=$((fails + 1))
# MUTANTS on the bi namespace
good=$(ns_render bi 2>&1)
extra() { printf '%s\n---\n%s\n' "$good" "$1"; }
mk() { cat <<YAML
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: $1, namespace: rd-iroha3-bi}
spec: {podSelector: $2, policyTypes: [Egress], egress: $3}
YAML
}
roles=(peer=peers-egress driver=driver-egress gateway=gateway-egress auditor=auditor-egress pool-init=pool-init-egress)
python3 -I "$C" m "${roles[@]}" <<<"$(extra "$(mk extra-peer '{matchLabels: {rd-iroha3/role: peer}}' '[{to: [{ipBlock: {cidr: 8.8.8.8/32}}]}]')")" >/dev/null 2>&1 && fail "MUTANT extra policy on peers passed" || ok "MUTANT: a second Egress policy selecting the peers FAILS the union"
python3 -I "$C" m "${roles[@]}" <<<"$(extra "$(mk allow-all '{}' '[{}]')")" >/dev/null 2>&1 && fail "MUTANT allow-all {} passed" || ok "MUTANT: an allow-all Egress policy with podSelector {} FAILS the union (selects every role)"
python3 -I "$C" m "${roles[@]}" <<<"$(extra "$(mk wide-driver '{matchLabels: {app.kubernetes.io/part-of: rd-iroha3}}' '[]')")" >/dev/null 2>&1 && fail "MUTANT part-of wildcard passed" || ok "MUTANT: a part-of=rd-iroha3 Egress policy FAILS the union"
no_driver=$(python3 -I -c '
import sys, json, yaml
docs = [d for d in yaml.safe_load_all(sys.stdin.read()) if d and not (d["kind"] == "NetworkPolicy" and d["metadata"]["name"] == "driver-egress")]
print("\n---\n".join(json.dumps(d) for d in docs))' <<<"$good")
python3 -I "$C" m "${roles[@]}" <<<"$no_driver" >/dev/null 2>&1 && fail "MUTANT missing driver-egress passed" || ok "MUTANT: a missing driver-egress FAILS the union (role selected by NONE)"
# blind spot (fabric): a baseline like allow-dns-egress (podSelector by matchExpressions, egress [{}]) selects every UNLOCKED pod but the role check skipped matchExpressions policies
python3 -I "$C" m "${roles[@]}" <<<"$(extra "$(mk allow-dns-egress '{matchExpressions: [{key: rd/egress-locked, operator: DoesNotExist}]}' '[{}]')")" >/dev/null 2>&1 && fail "MUTANT matchExpressions allow-all baseline passed" || ok "MUTANT: an Egress policy with matchExpressions (allow-dns-egress style) FAILS"
python3 -I "$C" m "${roles[@]}" <<<"$(extra "$(mk empty-sel '{}' '[]')")" >/dev/null 2>&1 && fail "MUTANT empty-selector Egress policy passed" || ok "MUTANT: an Egress policy with an empty podSelector FAILS"
python3 -I "$C" m "${roles[@]}" <<<"$(extra "$(mk allow-all-other '{matchLabels: {rd-iroha3/role: unrelated}}' '[{}]')")" >/dev/null 2>&1 && fail "MUTANT egress [{}] on another role passed" || ok "MUTANT: an Egress policy with egress [{}] FAILS even for a role we do not list"
python3 -I "$C" m peer=peers-egress <<<"$(extra "$(mk ingress-only '{}' '[]' | sed 's/policyTypes: \[Egress\]/policyTypes: [Ingress]/')")" >/dev/null 2>&1 && ok "an Ingress-only policy with podSelector {} does NOT count (not Egress-typed)" || fail "an Ingress-only policy was counted"
live=$(python3 -I -c '
import sys, json, yaml
docs = [d for d in yaml.safe_load_all(sys.stdin.read()) if d]
print(json.dumps({"kind": "List", "items": docs}))' <<<"$good")
python3 -I "$C" live "${roles[@]}" <<<"$live" >/dev/null 2>&1 && ok "a kubectl-style List input is read (live use)" || fail "the List input form was not read"
if (( fails )); then echo "FAILED: $fails check(s)" >&2; exit 1; fi
echo "PASS"
