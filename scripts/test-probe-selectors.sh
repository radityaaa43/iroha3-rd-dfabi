#!/usr/bin/env bash
# Offline test (R17 probe, lead condition): the peer-role egress probe Pod (labels ONLY rd-iroha3/role=peer) must match NO Service selector, no StatefulSet/Deployment/Job/PDB selector in any
# rd-iroha3-<p> namespace render (peers, p2p LB, driver, gateway, auditor, pool-init), so it can never become a p2p LB endpoint or be adopted/deleted by a controller. Every selector is printed.
# It also lists every NetworkPolicy that selects the probe: the set must be exactly the peer policies (no ingress exposure beyond what those give).
set -uo pipefail
cd "$(dirname "$0")/.."
fails=0; fail() { echo "FAIL: $*" >&2; fails=$((fails + 1)); }; ok() { echo "ok:   $*"; }
T=$(mktemp -d); trap 'find "$T" -delete' EXIT
D=sha256:$(printf 'a%.0s' $(seq 1 64)); H=0123abcd; CIDR=203.0.113.10/32
H64=$(printf '0123456789abcdef%.0s' 1 2 3 4)
P="$T/public"; mkdir -p "$P/gateway-ca"
echo 11111111-2222-4333-8444-555555555555 > "$P/chain_id"; printf 'hash:%s#ABCD\n' "${H64^^}" > "$P/genesis.expected_hash"
jq -n '[ "bi","bank-a","bank-b","bank-c" | {party: ., public_key: ("ea0130" + .), pop_hex: "0xaa"} ]' > "$P/peers.json"
jq -n '{"bi":"x","bank-a":"x","bank-b":"x","bank-c":"x","bi-gov":"x"}' > "$P/accounts.json"
for q in bi bank-a bank-b bank-c; do printf -- '-----BEGIN CERTIFICATE-----\nMIIB%s\n-----END CERTIFICATE-----\n' "$q" > "$P/gateway-ca/$q-server-ca.pem"; done
cat > "$T/opa.yaml" <<'YAML'
plugins:
  envoy_ext_authz_grpc:
    addr: 127.0.0.1:9191
    path: gw/allow
keys:
  bi: {algorithm: RS256, key: "-----BEGIN PUBLIC KEY-----\nMIIB\n-----END PUBLIC KEY-----"}
  bank-a: {algorithm: RS256, key: "-----BEGIN PUBLIC KEY-----\nMIIB\n-----END PUBLIC KEY-----"}
  bank-b: {algorithm: RS256, key: "-----BEGIN PUBLIC KEY-----\nMIIB\n-----END PUBLIC KEY-----"}
  bank-c: {algorithm: RS256, key: "-----BEGIN PUBLIC KEY-----\nMIIB\n-----END PUBLIC KEY-----"}
YAML
EI=envoyproxy/envoy@sha256:$(printf 'b%.0s' $(seq 1 64)); OI=openpolicyagent/opa@sha256:$(printf 'c%.0s' $(seq 1 64))
ns_render() { # <party> -> every render of that namespace, plus the peer-role probe
  local p=$1 c2=() gw2=() rem=43.106.70.123/32
  [[ $p == bank-c ]] && { c2=(--cluster 2); gw2=(--cluster 2 --lb-acl acl-test --lb-range 198.51.100.7/32); rem=147.139.197.22/32; }
  deploy/peers/render.sh "${c2[@]}" --p2p-egress-cidr 198.51.100.7/32 "$p" $H $CIDR
  echo "---"; deploy/p2p/render.sh "${c2[@]}" --acl-id acl-test --external-cidr 198.51.100.7/32 "$p"
  echo "---"; deploy/driver/render.sh "$p" "$D" "$P" --audit-tls
  echo "---"; deploy/gateway/render.sh "$p" --envoy-image "$EI" --opa-image "$OI" --opa-config "$T/opa.yaml" "${gw2[@]}"
  if [[ $p != bank-c ]]; then echo "---"; deploy/auditor/render.sh "$p" "$D" "$P"; fi
  if [[ $p == bi ]]; then echo "---"; deploy/pool-init/render.sh "$D" "$P" 1000 100; fi
  echo "---"; deploy/egress-probe/render.sh "$p" "$D" --role peer --remote-p2p "$rem" | python3 -I -c 'import sys,json;print(__import__("yaml").safe_dump(json.loads(sys.stdin.read())))'
}
cat > "$T/sel.py" <<'PY'
import sys
import yaml
party = sys.argv[1]
docs = [d for d in yaml.safe_load_all(sys.stdin.read()) if d]
probe = [d for d in docs if d["kind"] == "Pod" and d["metadata"]["name"] == "egress-probe-peer"]
assert len(probe) == 1, "exactly one egress-probe-peer Pod"
pl = probe[0]["metadata"]["labels"]
bad = []
n = 0
for d in docs:
    k, name, spec = d["kind"], d["metadata"]["name"], d.get("spec", {})
    sel = None
    if k == "Service":
        sel = spec.get("selector")
    elif k in ("StatefulSet", "Deployment", "Job", "ReplicaSet", "DaemonSet", "PodDisruptionBudget"):
        sel = (spec.get("selector") or {}).get("matchLabels")
        if (spec.get("selector") or {}).get("matchExpressions"):
            bad.append(f"{k}/{name}: matchExpressions selector (cannot prove it misses the probe)")
    if sel is None:
        continue
    n += 1
    hit = bool(sel) and all(pl.get(a) == b for a, b in sel.items())
    print(f"  selector {party} {k}/{name}: {sel}  matches probe {pl}: {hit}")
    if hit or not sel:
        bad.append(f"{k}/{name} selector {sel} matches the peer-role probe {pl}")
# NetworkPolicies selecting the probe, by direction
ing, eg = [], []
for d in docs:
    if d["kind"] != "NetworkPolicy":
        continue
    sp = d["spec"]
    ps = sp.get("podSelector", {})
    if ps.get("matchExpressions") or not all(pl.get(a) == b for a, b in (ps.get("matchLabels") or {}).items()):
        continue
    for t in sp.get("policyTypes") or []:
        (ing if t == "Ingress" else eg).append(d["metadata"]["name"])
print(f"  policies selecting the probe {party}: ingress={sorted(ing)} egress={sorted(eg)}")
if sorted(eg) != ["peers-egress"]:
    bad.append(f"egress policies selecting the probe: {sorted(eg)}, want exactly ['peers-egress']")
if sorted(ing) != ["peers-p2p", "peers-torii", "torii-bootstrap"]:
    bad.append(f"ingress policies selecting the probe: {sorted(ing)}, want the three peer ingress policies")
if bad:
    print("\n".join(f"FAIL: probe-selectors {party}: {b}" for b in bad), file=sys.stderr)
    sys.exit(1)
print(f"ok:   probe-selectors {party}: {n} selectors checked, none matches the peer-role probe")
PY
for p in bi bank-a bank-b bank-c; do
  out=$(ns_render "$p" 2>&1) || { fail "$p: a render failed: ${out:0:300}"; continue; }
  python3 -I "$T/sel.py" "$p" <<<"$out" || fails=$((fails + 1))
done
# MUTANT: a probe that carries the labels of a Service selector (part-of + party + role) MUST be caught
out=$(ns_render bi 2>&1)
mut=$(python3 -I -c '
import sys, yaml
docs = [d for d in yaml.safe_load_all(sys.stdin.read()) if d]
for d in docs:
    if d["kind"] == "Pod" and d["metadata"]["name"] == "egress-probe-peer":
        d["metadata"]["labels"].update({"app.kubernetes.io/part-of": "rd-iroha3", "rd-iroha3/party": "bi"})
print(yaml.safe_dump_all(docs))' <<<"$out")
msg=$(python3 -I "$T/sel.py" bi <<<"$mut" 2>&1 >/dev/null); [[ $msg == *"matches the peer-role probe"* ]] && ok "MUTANT: a probe labelled part-of+party+role (the p2p Service / StatefulSet selector) FAILS the selector test" || fail "MUTANT probe with part-of+party+role labels not caught for the right reason: ${msg:0:200}"
if (( fails )); then echo "FAILED: $fails check(s)" >&2; exit 1; fi
echo "PASS"
