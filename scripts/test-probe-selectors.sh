#!/usr/bin/env bash
# Offline test (R17 probes, lead condition): the peer-, gateway- and lb-role egress probe Pods (peer: labels ONLY rd-iroha3/role=peer; gateway: role=gateway + app.kubernetes.io/name=gateway;
# lb: role=lb-probe) must match NO Service selector, no StatefulSet/Deployment/Job/PDB selector in any rd-iroha3-<p> namespace render (peers, p2p LB, driver, gateway, auditor, pool-init),
# so a probe can never become a Service endpoint (real traffic to a probe) or be adopted/deleted by a controller. Every selector is printed.
# It also lists every NetworkPolicy that selects each probe: the sets must be exactly the expected ones (no exposure beyond what those give).
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
EI=envoyproxy/envoy@sha256:$(printf 'b%.0s' $(seq 1 64)); OI=openpolicyagent/opa@sha256:$(printf 'c%.0s' $(seq 1 64))
ns_render() { # <party> -> every render of that namespace (no probe)
  local p=$1 c2=() gw2=() gwr=()
  [[ $p == bank-c ]] && { c2=(--cluster 2); gw2=(--cluster 2 --lb-acl acl-test --lb-range 198.51.100.7/32); gwr=(--remote-gw bi=203.0.113.20 --remote-gw bank-a=203.0.113.21 --remote-gw bank-b=203.0.113.22);}
  deploy/peers/render.sh "${c2[@]}" --p2p-egress-cidr 198.51.100.7/32 "$p" $H $CIDR
  echo "---"; deploy/p2p/render.sh "${c2[@]}" --acl-id acl-test --external-cidr 198.51.100.7/32 "$p"
  echo "---"; deploy/driver/render.sh "$p" "$D" "$P" --audit-tls "${gwr[@]}"
  echo "---"; deploy/gateway/render.sh "$p" --envoy-image "$EI" --opa-image "$OI" "${gw2[@]}"
  if [[ $p != bank-c ]]; then echo "---"; deploy/auditor/render.sh "$p" "$D" "$P"; fi
  if [[ $p == bi ]]; then echo "---"; deploy/pool-init/render.sh "$D" "$P" 1000 100; fi
}
probe_docs() { # <party> <peer|gateway|lb> -> the probe's own documents as YAML
  local p=$1 k=$2 rem=43.106.70.123; [[ $p == bank-c ]] && rem=147.139.197.22
  local extra=(); [[ $k == peer ]] && extra=(--remote-p2p "$rem/32"); [[ $k == lb ]] && extra=(--lb-target "$rem/32")
  deploy/egress-probe/render.sh "$p" "$D" --role "$k" "${extra[@]}" | python3 -I -c 'import sys,json,yaml;print(yaml.safe_dump_all([json.loads(x) for x in sys.stdin.read().split("\n---\n")]))'
}
cat > "$T/sel.py" <<'PY'
import sys
import yaml
party, kind = sys.argv[1], sys.argv[2]
PODNAME = {"peer": "egress-probe-peer", "gateway": "egress-probe-gateway", "lb": "lb-probe", "driver-min": "egress-probe-driver-min"}[kind]
WANT = {  # kind: (ingress policies selecting the probe, egress policies selecting the probe)
    "peer": (["peers-p2p", "peers-torii", "torii-bootstrap"], ["peers-egress"]),
    "gateway": (["gateway-ingress"], ["gateway-egress"]),
    "lb": ([], ["lb-probe-egress"]),
    "driver-min": (["driver-ingress"], ["driver-egress"]),
}[kind]
docs = [d for d in yaml.safe_load_all(sys.stdin.read()) if d]
probe = [d for d in docs if d["kind"] == "Pod" and d["metadata"]["name"] == PODNAME]
assert len(probe) == 1, f"exactly one {PODNAME} Pod"
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
    print(f"  selector {party} {k}/{name}: {sel}  matches {kind} probe {pl}: {hit}")
    if hit or not sel:
        bad.append(f"{k}/{name} selector {sel} matches the {kind}-role probe {pl}")
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
print(f"  policies selecting the {kind} probe {party}: ingress={sorted(ing)} egress={sorted(eg)}")
if sorted(eg) != sorted(WANT[1]):
    bad.append(f"egress policies selecting the {kind} probe: {sorted(eg)}, want exactly {WANT[1]}")
if sorted(ing) != sorted(WANT[0]):
    bad.append(f"ingress policies selecting the {kind} probe: {sorted(ing)}, want {WANT[0]}")
if bad:
    print("\n".join(f"FAIL: probe-selectors {party} {kind}: {b}" for b in bad), file=sys.stderr)
    sys.exit(1)
print(f"ok:   probe-selectors {party} {kind}: {n} selectors checked, none matches the {kind}-role probe")
PY
for p in bi bank-a bank-b bank-c; do
  base=$(ns_render "$p" 2>&1) || { fail "$p: a render failed: ${base:0:300}"; continue; }
  for k in peer gateway lb driver-min; do
    out=$(printf '%s\n---\n%s\n' "$base" "$(probe_docs "$p" "$k" 2>&1)")
    python3 -I "$T/sel.py" "$p" "$k" <<<"$out" || fails=$((fails + 1))
  done
done
# MUTANTS: a probe that carries the labels of a Service/Deployment selector (part-of + party + role [+ name]) MUST be caught, for each kind
base=$(ns_render bi 2>&1)
for k in peer gateway; do
  mut=$(python3 -I -c '
import sys, yaml
docs = [d for d in yaml.safe_load_all(sys.stdin.read()) if d]
for d in docs:
    if d["kind"] == "Pod" and d["metadata"]["name"].startswith("egress-probe-"):
        d["metadata"]["labels"].update({"app.kubernetes.io/part-of": "rd-iroha3", "rd-iroha3/party": "bi", "app.kubernetes.io/name": "gateway", "rd-iroha3/role": sys.argv[1]})
print(yaml.safe_dump_all(docs))' "$([[ $k == peer ]] && echo peer || echo gateway)" <<<"$(printf '%s\n---\n%s\n' "$base" "$(probe_docs bi "$k")")")
  msg=$(python3 -I "$T/sel.py" bi "$k" <<<"$mut" 2>&1 >/dev/null); [[ $msg == *"matches the $k-role probe"* ]] && ok "MUTANT: a $k probe labelled part-of+party+name+role (a Service/Deployment selector) FAILS the selector test" || fail "MUTANT $k probe with Service-selector labels not caught for the right reason: ${msg:0:200}"
done
if (( fails )); then echo "FAILED: $fails check(s)" >&2; exit 1; fi
echo "PASS"
