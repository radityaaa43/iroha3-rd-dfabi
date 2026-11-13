#!/usr/bin/env bash
# Offline test of deploy/gateway/render.sh (no cluster, no docker; python3 + PyYAML). Exit != 0 on any failure.
set -uo pipefail
cd "$(dirname "$0")/.."
R=deploy/gateway/render.sh
fails=0
fail() { echo "FAIL: $*" >&2; fails=$((fails + 1)); }
ok() { echo "ok:   $*"; }
T=$(mktemp -d); trap 'rm -r -- "$T"' EXIT
EI=example.io/envoy@sha256:$(printf 'e%.0s' $(seq 1 64))
OI=example.io/opa@sha256:$(printf 'f%.0s' $(seq 1 64))
ACL=acl-d9ji5nwbqutwulof33ydb

refuse() { # <label> <expected message part> <args...>
  local label=$1 part=$2; shift 2
  local err rc
  err=$("$R" "$@" 2>&1 >/dev/null); rc=$?
  [[ $rc -eq 2 && $err == *"$part"* ]] && ok "refuses $label (exit 2)" || fail "$label not refused as expected (rc=$rc: $err)"
}
base=(--envoy-image "$EI" --opa-image "$OI")
refuse "no arguments" "usage"
refuse "an unknown party" "usage" nobody "${base[@]}"
refuse "an envoy tag instead of a digest" "digest" bi --envoy-image envoy:v1 --opa-image "$OI"
refuse "an opa tag instead of a digest" "digest" bi --envoy-image "$EI" --opa-image opa:latest
refuse "the old --opa-config (iroha3 has its own policy, no besu bundle)" "usage" bi "${base[@]}" --opa-config /dev/null
refuse "bank-c on cluster 1" "cluster" bank-c "${base[@]}" --cluster 1
refuse "bi on cluster 2" "cluster" bi "${base[@]}" --cluster 2
refuse "cluster 2 without --lb-acl" "lb-acl" bank-c "${base[@]}" --cluster 2 --lb-range 47.237.84.150/32
refuse "cluster 2 without --lb-range" "lb-range" bank-c "${base[@]}" --cluster 2 --lb-acl "$ACL"
refuse "cluster 1 with an LB acl but no range" "lb-range" bi "${base[@]}" --lb-acl "$ACL"
refuse "cluster 1 with an LB range but no acl" "lb-acl" bi "${base[@]}" --lb-range 47.237.84.150/32
refuse "a bad acl id" "lb-acl" bank-c "${base[@]}" --cluster 2 --lb-acl "x;y" --lb-range 47.237.84.150/32
refuse "a range that is not a /32" "lb-range" bank-c "${base[@]}" --cluster 2 --lb-acl "$ACL" --lb-range 10.0.0.0/8

for p in bi bank-a bank-b; do
  out=$("$R" "$p" "${base[@]}" 2>&1) || { fail "$p: render failed: $out"; continue; }
  grep -q '@[A-Z_]*@' <<<"$out" && fail "$p: unreplaced placeholder in output"
  python3 -I scripts/check-gateway.py "$p" 1 "$EI" "$OI" <<<"$out" || fails=$((fails + 1))
  python3 -I scripts/check-netpol-form.py "gateway" <<<"$out" || fails=$((fails + 1))
done
# cluster 1 WITH the cross-cluster gateway LB (ACL-first, PLAN S14 "one external listener per namespace"): NodePort + LB
for p in bi bank-a bank-b; do
  out=$("$R" "$p" "${base[@]}" --lb-acl "$ACL" --lb-range 47.237.62.1/32 2>&1) || { fail "$p with LB: render failed: $out"; continue; }
  python3 -I scripts/check-gateway.py "$p" 1 "$EI" "$OI" lb <<<"$out" || fails=$((fails + 1))
  python3 -I scripts/check-netpol-form.py "gateway" <<<"$out" || fails=$((fails + 1))
done
out=$("$R" bank-c "${base[@]}" --cluster 2 --lb-acl "$ACL" --lb-range 47.237.84.150/32 2>&1) || fail "bank-c: render failed: $out"
python3 -I scripts/check-gateway.py bank-c 2 "$EI" "$OI" <<<"$out" || fails=$((fails + 1))
python3 -I scripts/check-netpol-form.py "gateway" <<<"$out" || fails=$((fails + 1))
grep -q "47.237.84.150/32" <<<"$out" && grep -q "$ACL" <<<"$out" && ok "bank-c carries the existing ACL id and source range" || fail "bank-c: ACL id or range missing"
a=$("$R" bi "${base[@]}"); b=$("$R" bi "${base[@]}")
[[ -n $a && $a == "$b" ]] && ok "render is deterministic" || fail "render differs between runs or is empty"
before=$(find "$T" -type f | sort | xargs cksum)
"$R" bi "${base[@]}" >/dev/null; [[ $(find "$T" -type f | sort | xargs cksum) == "$before" ]] && ok "writes nothing" || fail "files changed"
# R22 MUTANTS of the gateway Deployment affinity: exactly one PREFERRED hostname term; required or missing or other topology must FAIL
gw_mut() { # <label> <python statement on the pod spec dict ps>
  local m; m=$("$R" bi "${base[@]}" | python3 -I -c '
import sys, json, yaml
docs = [d for d in yaml.safe_load_all(sys.stdin.read()) if d]
for d in docs:
    if d["kind"] == "Deployment":
        ps = d["spec"]["template"]["spec"]; exec(sys.argv[1])
print("\n---\n".join(json.dumps(d) for d in docs))' "$2")
  python3 -I scripts/check-gateway.py bi 1 "$EI" "$OI" <<<"$m" >/dev/null 2>&1 && fail "MUTANT $1 passed the gateway checker" || ok "MUTANT: $1 FAILS the gateway checker"
}
gw_mut "the gateway anti-affinity made REQUIRED" 'a = ps["affinity"]["podAntiAffinity"]; a["requiredDuringSchedulingIgnoredDuringExecution"] = [a.pop("preferredDuringSchedulingIgnoredDuringExecution")[0]["podAffinityTerm"]]'
gw_mut "the gateway affinity missing" 'ps.pop("affinity")'
gw_mut "the gateway term on topologyKey zone" 'ps["affinity"]["podAntiAffinity"]["preferredDuringSchedulingIgnoredDuringExecution"][0]["podAffinityTerm"]["topologyKey"] = "topology.kubernetes.io/zone"'
gw_mut "a nodeAffinity added to the gateway" 'ps["affinity"]["nodeAffinity"] = {"requiredDuringSchedulingIgnoredDuringExecution": {"nodeSelectorTerms": []}}'
rt_mut() { # <label> <python statement on the envoy route list rs>
  local m; m=$("$R" bi "${base[@]}" | python3 -I -c '
import sys, json, yaml
docs = [d for d in yaml.safe_load_all(sys.stdin.read()) if d]
for d in docs:
    if d["kind"] == "ConfigMap" and d["metadata"]["name"] == "gateway-envoy":
        e = json.loads(d["data"]["envoy.yaml"]); rs = e["static_resources"]["listeners"][0]["filter_chains"][0]["filters"][0]["typed_config"]["route_config"]["virtual_hosts"][0]["routes"]
        exec(sys.argv[1]); d["data"]["envoy.yaml"] = json.dumps(e)
print("\n---\n".join(json.dumps(d) for d in docs))' "$2") || { fail "MUTANT $1: the mutation script itself failed"; return; }
  python3 -I scripts/check-gateway.py bi 1 "$EI" "$OI" <<<"$m" >/dev/null 2>&1 && fail "MUTANT $1 passed the gateway checker" || ok "MUTANT: $1 FAILS the gateway checker"
}
# APS routes: /aps/ prefix -> the own driver, 600 s (a bundle takes ~100-200 s; the default 60 s torii route would cut it)
for p in bi bank-a bank-b; do
  "$R" "$p" "${base[@]}" | python3 -I -c 'import sys, json, yaml
for d in yaml.safe_load_all(sys.stdin.read()):
    if d and d["metadata"]["name"] == "gateway-envoy":
        rs = json.loads(d["data"]["envoy.yaml"])["static_resources"]["listeners"][0]["filter_chains"][0]["filters"][0]["typed_config"]["route_config"]["virtual_hosts"][0]["routes"]
        assert any(r["match"] == {"prefix": "/aps/"} and r["route"] == {"cluster": "driver", "timeout": "600s", "idle_timeout": "600s"} for r in rs)' && ok "$p: /aps/ routes to the driver with a 600s timeout and idle_timeout" || fail "$p: no /aps/ -> driver 600s route"
done
rt_mut "the /aps/ route dropped" 'rs[:] = [r for r in rs if r["match"] != {"prefix": "/aps/"}]'
rt_mut "the /aps/ route timeout 330s" 'next(r for r in rs if r["match"] == {"prefix": "/aps/"})["route"]["timeout"] = "330s"'
rt_mut "the /aps/ route idle_timeout dropped" 'next(r for r in rs if r["match"] == {"prefix": "/aps/"})["route"].pop("idle_timeout")'
rt_mut "the /aps/ route idle_timeout 300s" 'next(r for r in rs if r["match"] == {"prefix": "/aps/"})["route"]["idle_timeout"] = "300s"'
rt_mut "the /aps/ route to torii" 'next(r for r in rs if r["match"] == {"prefix": "/aps/"})["route"]["cluster"] = "torii"'
rt_mut "the /aps/ route after the default prefix /" 'rs.append(rs.pop(next(i for i, r in enumerate(rs) if r["match"] == {"prefix": "/aps/"})))'
pol_mut() { # <label> <python statement on the gateway-policy data dict pd>
  local m; m=$("$R" bi "${base[@]}" | python3 -I -c '
import sys, json, yaml
docs = [d for d in yaml.safe_load_all(sys.stdin.read()) if d]
for d in docs:
    if d["kind"] == "ConfigMap" and d["metadata"]["name"] == "gateway-policy":
        pd = d["data"]; exec(sys.argv[1])
print("\n---\n".join(json.dumps(d) for d in docs))' "$2")
  python3 -I scripts/check-gateway.py bi 1 "$EI" "$OI" <<<"$m" >/dev/null 2>&1 && fail "MUTANT $1 passed the gateway checker" || ok "MUTANT: $1 FAILS the gateway checker"
}
pol_mut "the /transfer row dropped from the shipped policy" 'pd["iroha3.rego"] = pd["iroha3.rego"].replace(", \"/transfer\"", "")'
pol_mut "a Lensa CA missing from data.json" 'x = json.loads(pd["data.json"]); x["iroha3_config"]["iroha3_ca"]["lensa"].pop("bank-c"); pd["data.json"] = json.dumps(x)'
pol_mut "the APS rows 16-18 dropped from the shipped policy" 'pd["iroha3.rego"] = pd["iroha3.rego"].replace("/aps/submit", "/aps/x")'
pol_mut "the APS row 19 dropped from the shipped policy" 'pd["iroha3.rego"] = pd["iroha3.rego"].replace("/aps/bundles", "/aps/x")'
pol_mut "the policy ConfigMap without data.json" 'pd.pop("data.json")'
if (( fails )); then echo "FAILED: $fails check(s)" >&2; exit 1; fi
echo "PASS"
