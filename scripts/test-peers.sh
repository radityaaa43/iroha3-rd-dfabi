#!/usr/bin/env bash
# Offline test of deploy/peers/render.sh (no cluster, no kubectl; needs python3 + PyYAML). Exit != 0 on any failure.
set -uo pipefail
cd "$(dirname "$0")/.."
R=deploy/peers/render.sh
H=a1b2c3d4
CIDR=203.0.113.10/32
fails=0
fail() { echo "FAIL: $*" >&2; fails=$((fails + 1)); }
ok() { echo "ok:   $*"; }

refuse() { # <label> <expected message part> <args...>
  local label=$1 part=$2; shift 2
  local err rc
  err=$("$R" "$@" 2>&1 >/dev/null); rc=$?
  [[ $rc -eq 2 && $err == *"$part"* ]] && ok "refuses $label (exit 2)" || fail "$label not refused as expected (rc=$rc: $err)"
}
refuse "bank-c without --cluster 2" "S8" bank-c $H $CIDR
refuse "--cluster 2 with a cluster-1 party" "bank-c" --cluster 2 bi $H $CIDR
refuse "--cluster 3" "usage" --cluster 3 bank-c $H $CIDR
refuse "no arguments" "usage"
refuse "unknown party" "usage" nobody $H $CIDR
refuse "bad genesis hash" "hash8" bi nothex $CIDR
refuse "bad cidr" "cidr" bi $H not-a-cidr
refuse "a /24 bank-c range" "/32" bi $H 203.0.113.0/24
refuse "0.0.0.0/0" "/32" bi $H 0.0.0.0/0
refuse "missing cidr" "usage" bi $H
refuse "a clb health range other than 100.64.0.0/10" "100.64.0.0/10" --clb-health-cidr 10.0.0.0/8 bi $H $CIDR
refuse "an open clb health range" "100.64.0.0/10" --clb-health-cidr 0.0.0.0/0 bi $H $CIDR
SR=/dev/shm/iroha3-new/tmp/tmp.BAREFwIKTo/ln
refuse "a --state-root outside the assembler localnet dir" "state-root" --state-root /storage bi $H $CIDR
refuse "a --state-root with .." "state-root" --state-root /dev/shm/iroha3-new/tmp/../ln bi $H $CIDR
refuse "an empty --state-root" "state-root" --state-root "" bi $H $CIDR
for p in bi bank-a bank-b; do
  out=$("$R" --state-root $SR "$p" $H $CIDR 2>&1) || { fail "render --state-root $p"; continue; }
  python3 -I scripts/check-peers.py "$p" $H $CIDR state-root:$SR <<<"$out" && ok "$p --state-root: the PVC also at $SR (subPath shm-ln)" || fails=$((fails + 1))
done
out=$("$R" --state-root $SR --cluster 2 bank-c $H $CIDR 2>&1) && python3 -I scripts/check-peers.py bank-c $H $CIDR c2 state-root:$SR <<<"$out" && ok "bank-c --state-root" || fail "bank-c --state-root"
out=$("$R" bi $H $CIDR) && python3 -I scripts/check-peers.py bi $H $CIDR state-root:$SR <<<"$out" >/dev/null 2>&1 && fail "a render without --state-root passes the --state-root checker" || ok "MUTANT: no --state-root FAILS the state-root checker"

for p in bi bank-a bank-b; do
  out=$("$R" "$p" $H $CIDR 2>&1) || { fail "$p: render failed: $out"; continue; }
  grep -q '@[A-Z_]*@' <<<"$out" && fail "$p: unreplaced placeholder in output"
  python3 -I scripts/check-peers.py "$p" $H $CIDR <<<"$out" || fails=$((fails + 1))
  python3 -I scripts/check-netpol-form.py "peers" <<<"$out" || fails=$((fails + 1))
done
for p in bi bank-a bank-b; do # the CLB health-check source is opt-in; Alibaba CLB probes and forwards from 100.64.0.0/10
  out=$("$R" --clb-health-cidr 100.64.0.0/10 "$p" $H $CIDR 2>&1) || { fail "$p: render with --clb-health-cidr failed: $out"; continue; }
  python3 -I scripts/check-peers.py "$p" $H $CIDR clb <<<"$out" || fails=$((fails + 1))
  python3 -I scripts/check-netpol-form.py "peers" <<<"$out" || fails=$((fails + 1))
  [[ $("$R" "$p" $H $CIDR | grep -c '100\.64\.') -eq 0 ]] && ok "$p: default render has no 100.64 element" || fail "$p: default render carries 100.64"
done
# S8: bank-c on cluster 2 (default and with the CLB element)
out=$("$R" --cluster 2 bank-c $H $CIDR 2>&1) || fail "bank-c --cluster 2: render failed: $out"
python3 -I scripts/check-peers.py bank-c $H $CIDR c2 <<<"$out" || fails=$((fails + 1))
python3 -I scripts/check-netpol-form.py "peers" <<<"$out" || fails=$((fails + 1))
grep -q 'alicloud' <<<"$out" && fail "bank-c --cluster 2 still names a cluster-1 StorageClass (alicloud-*)"
out=$("$R" --clb-health-cidr 100.64.0.0/10 --cluster 2 bank-c $H $CIDR 2>&1) || fail "bank-c --cluster 2 --clb-health-cidr: render failed: $out"
python3 -I scripts/check-peers.py bank-c $H $CIDR clb c2 <<<"$out" || fails=$((fails + 1))
python3 -I scripts/check-netpol-form.py "peers" <<<"$out" || fails=$((fails + 1))
# R17 end step: peers-egress (--p2p-egress-cidr = the OTHER cluster's external LB /32 addresses, repeatable)
BANKC_LB=43.106.70.123/32; C1_LBS=(147.139.197.22/32 147.139.195.93/32 8.215.12.88/32)
for p in bi bank-a bank-b; do
  out=$("$R" --p2p-egress-cidr $BANKC_LB "$p" $H $CIDR 2>&1) || { fail "$p --p2p-egress-cidr: render failed: $out"; continue; }
  python3 -I scripts/check-peers.py "$p" $H $CIDR egress:$BANKC_LB <<<"$out" || fails=$((fails + 1))
  python3 -I scripts/check-netpol-form.py "peers-egress" <<<"$out" || fails=$((fails + 1))
done
args=(); for c in "${C1_LBS[@]}"; do args+=(--p2p-egress-cidr "$c"); done
out=$("$R" --cluster 2 "${args[@]}" bank-c $H $CIDR 2>&1) || fail "bank-c --p2p-egress-cidr: render failed: $out"
python3 -I scripts/check-peers.py bank-c $H $CIDR c2 egress:$(IFS=,; echo "${C1_LBS[*]}") <<<"$out" || fails=$((fails + 1))
python3 -I scripts/check-netpol-form.py "peers-egress-c2" <<<"$out" || fails=$((fails + 1))
refuse "a /24 --p2p-egress-cidr" "/32" --p2p-egress-cidr 203.0.113.0/24 bi $H $CIDR
refuse "--p2p-egress-cidr without a value" "usage" --p2p-egress-cidr
# MUTANTS of the rendered bi peers-egress policy: each must make the checker FAIL (extra destination, wildcard namespace, empty podSelector, extra port)
good=$("$R" --p2p-egress-cidr $BANKC_LB bi $H $CIDR)
mut() { # <label> <python expression on policy dict p>
  local m; m=$(python3 -I -c '
import sys, json, yaml
docs = [d for d in yaml.safe_load_all(sys.stdin.read()) if d]
for p in docs:
    if p["kind"] == "NetworkPolicy" and p["metadata"]["name"] == "peers-egress": exec(sys.argv[1])
print("\n---\n".join(json.dumps(d) for d in docs))' "$2" <<<"$good")
  python3 -I scripts/check-peers.py bi $H $CIDR egress:$BANKC_LB <<<"$m" >/dev/null 2>&1 && fail "MUTANT $1 passed the peers checker" || ok "MUTANT: $1 FAILS the peers checker"
}
mut "an extra egress destination (ipBlock 8.8.8.8/32)" 'p["spec"]["egress"][2]["to"].append({"ipBlock": {"cidr": "8.8.8.8/32"}})'
mut "an extra rule to the whole internet (to omitted)" 'p["spec"]["egress"].append({"ports": [{"protocol": "TCP", "port": 443}]})'
mut "a wildcard namespace selector" 'p["spec"]["egress"][1]["to"][0]["namespaceSelector"] = {}'
mut "an empty podSelector in a rule" 'p["spec"]["egress"][3]["to"][0]["podSelector"] = {}'
mut "an extra port 443 on the P2P rule" 'p["spec"]["egress"][1]["ports"].append({"protocol": "TCP", "port": 443})'
mut "the other cluster LB replaced by a cluster-internal range" 'p["spec"]["egress"][2]["to"] = [{"ipBlock": {"cidr": "10.200.0.0/16"}}]'
# R22 MUTANTS of the StatefulSet pod affinity: the anti-affinity must be REQUIRED, hostname, over the rd-iroha3 namespaces
sts_mut() { # <label> <python statement on the pod spec dict a (pod["spec"]["affinity"]["podAntiAffinity"])>
  local m; m=$(python3 -I -c '
import sys, json, yaml
docs = [d for d in yaml.safe_load_all(sys.stdin.read()) if d]
for d in docs:
    if d["kind"] == "StatefulSet":
        a = d["spec"]["template"]["spec"]["affinity"]["podAntiAffinity"]; exec(sys.argv[1])
print("\n---\n".join(json.dumps(d) for d in docs))' "$2" <<<"$good")
  python3 -I scripts/check-peers.py bi $H $CIDR egress:$BANKC_LB <<<"$m" >/dev/null 2>&1 && fail "MUTANT $1 passed the peers checker" || ok "MUTANT: $1 FAILS the peers checker"
}
sts_mut "the anti-affinity back to soft (preferred only)" 'a["preferredDuringSchedulingIgnoredDuringExecution"] = [{"weight": 100, "podAffinityTerm": a.pop("requiredDuringSchedulingIgnoredDuringExecution")[0]}]'
sts_mut "the required term on topologyKey zone instead of hostname" 'a["requiredDuringSchedulingIgnoredDuringExecution"][0]["topologyKey"] = "topology.kubernetes.io/zone"'
sts_mut "the required term without the namespaceSelector (own namespace only)" 'a["requiredDuringSchedulingIgnoredDuringExecution"][0].pop("namespaceSelector")'
sts_mut "the required term plus a leftover soft term" 'a["preferredDuringSchedulingIgnoredDuringExecution"] = [{"weight": 1, "podAffinityTerm": a["requiredDuringSchedulingIgnoredDuringExecution"][0]}]'
if (( fails )); then echo "FAILED: $fails check(s)" >&2; exit 1; fi
echo "PASS"
