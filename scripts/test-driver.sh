#!/usr/bin/env bash
# Offline test of deploy/driver/render.sh (no cluster; python3 + PyYAML). Exit != 0 on any failure.
set -uo pipefail
cd "$(dirname "$0")/.."
R=deploy/driver/render.sh
fails=0
fail() { echo "FAIL: $*" >&2; fails=$((fails + 1)); }
ok() { echo "ok:   $*"; }
T=$(mktemp -d); trap 'rm -r -- "$T"' EXIT
D=sha256:$(printf 'a%.0s' $(seq 1 64))
H64=$(printf '0123456789abcdef%.0s' 1 2 3 4)
P="$T/public"; mkdir "$P"
CHAIN=11111111-2222-4333-8444-555555555555
echo "$CHAIN" > "$P/chain_id"
printf 'hash:%s#ABCD\n' "${H64^^}" > "$P/genesis.expected_hash"
jq -n '[ "bi","bank-a","bank-b","bank-c" | {party: ., public_key: ("ea0130" + .), pop_hex: "0xaa"} ]' > "$P/peers.json"
jq -n '{bi:"ed0120bb","bank-a":"ed0120cc","bank-b":"ed0120dd","bank-c":"ed0120ee","bi-gov":"ed0120ff"}' > "$P/accounts.json"
H8=${H64:0:8}

refuse() { # <label> <expected message part> <args...>
  local label=$1 part=$2; shift 2
  local err rc
  err=$("$R" "$@" 2>&1 >/dev/null); rc=$?
  [[ $rc -eq 2 && $err == *"$part"* ]] && ok "refuses $label (exit 2)" || fail "$label not refused as expected (rc=$rc: $err)"
}
refuse "no arguments" "usage"
refuse "an unknown party" "usage" nobody "$D" "$P"
refuse "a tag instead of a digest" "digest" bi "debian:latest" "$P"
refuse "a short digest" "digest" bi "sha256:abc" "$P"
refuse "a missing public dir" "public dir" bi "$D" "$T/none"
mkdir "$T/p2"; cp "$P/chain_id" "$P/peers.json" "$T/p2/"; refuse "a public dir without genesis.expected_hash" "genesis.expected_hash" bi "$D" "$T/p2"
mkdir "$T/p3"; cp "$P"/* "$T/p3/"; : > "$T/p3/x.seed"; refuse "a public dir holding a seed" "private material" bi "$D" "$T/p3"

for p in bi bank-a bank-b bank-c; do
  out=$("$R" "$p" "$D" "$P" 2>&1) || { fail "$p: render failed: $out"; continue; }
  grep -q '@[A-Z_]*@' <<<"$out" && fail "$p: unreplaced placeholder in output"
  python3 -I scripts/check-driver.py "$p" "$D" "$H8" "$CHAIN" <<<"$out" || fails=$((fails + 1))
  python3 -I scripts/check-netpol-form.py "driver" <<<"$out" || fails=$((fails + 1))
done
# --audit-tls: [audit] 2-of-3 through the gateways, [tls], client-cert Secret volume, public server CAs ConfigMap
mkdir -p "$P/gateway-ca"
for q in bi bank-a bank-b bank-c; do printf -- '-----BEGIN CERTIFICATE-----\nMIIB%s\n-----END CERTIFICATE-----\n' "$q" > "$P/gateway-ca/$q-server-ca.pem"; done
for p in bi bank-a bank-b; do  # cluster 1: the three auditors are in the same cluster (names resolve); bank-c needs --remote-gw (below)
  out=$("$R" "$p" "$D" "$P" --audit-tls 2>&1) || { fail "$p --audit-tls: render failed: $out"; continue; }
  python3 -I scripts/check-driver.py "$p" "$D" "$H8" "$CHAIN" tls <<<"$out" || fails=$((fails + 1))
  python3 -I scripts/check-netpol-form.py "driver" <<<"$out" || fails=$((fails + 1))
done
# --audit-tls with the gateways of the OTHER cluster as explicit /32 ipBlocks (driver-egress)
for p in bi bank-a bank-b; do
  out=$("$R" "$p" "$D" "$P" --audit-tls --remote-gw-cidr 203.0.113.10/32 --remote-gw-cidr 203.0.113.11/32 2>&1) || { fail "$p --remote-gw-cidr: render failed: $out"; continue; }
  python3 -I scripts/check-driver.py "$p" "$D" "$H8" "$CHAIN" tls 203.0.113.10/32 203.0.113.11/32 <<<"$out" || fails=$((fails + 1))
  python3 -I scripts/check-netpol-form.py "driver" <<<"$out" || fails=$((fails + 1))
done
# bank-c (cluster 2) reaches the three cluster-1 auditors only by their external gateway LB addresses: --remote-gw <party>=<ip> emits [tls.resolve] (host -> ip:8443) AND the same ip as a /32 in driver-egress
GW=(--remote-gw bi=203.0.113.20 --remote-gw bank-a=203.0.113.21 --remote-gw bank-b=203.0.113.22)
GWT=(gw:bi=203.0.113.20 gw:bank-a=203.0.113.21 gw:bank-b=203.0.113.22)
out=$("$R" bank-c "$D" "$P" --audit-tls "${GW[@]}" 2>&1) || fail "bank-c --remote-gw: render failed: $out"
python3 -I scripts/check-driver.py bank-c "$D" "$H8" "$CHAIN" tls "${GWT[@]}" <<<"$out" || fails=$((fails + 1))
python3 -I scripts/check-netpol-form.py "driver" <<<"$out" || fails=$((fails + 1))
out2=$("$R" bank-c "$D" "$P" --audit-tls --remote-gw-cidr 203.0.113.10/32 "${GW[@]}" 2>&1) || fail "bank-c --remote-gw + --remote-gw-cidr: render failed: $out2"
python3 -I scripts/check-driver.py bank-c "$D" "$H8" "$CHAIN" tls 203.0.113.10/32 "${GWT[@]}" <<<"$out2" || fails=$((fails + 1))
refuse "bank-c --audit-tls without --remote-gw" "remote-gw" bank-c "$D" "$P" --audit-tls
refuse "bank-c --audit-tls with only --remote-gw-cidr" "remote-gw" bank-c "$D" "$P" --audit-tls --remote-gw-cidr 203.0.113.10/32
refuse "bank-c --remote-gw missing bank-b" "bank-b" bank-c "$D" "$P" --audit-tls --remote-gw bi=203.0.113.20 --remote-gw bank-a=203.0.113.21
refuse "a duplicated --remote-gw party" "twice" bank-c "$D" "$P" --audit-tls "${GW[@]}" --remote-gw bi=203.0.113.23
refuse "--remote-gw for the auditor-less bank-c itself" "bi, bank-a or bank-b" bank-c "$D" "$P" --audit-tls "${GW[@]}" --remote-gw bank-c=203.0.113.24
refuse "--remote-gw for a cluster-1 driver" "bank-c" bi "$D" "$P" --audit-tls "${GW[@]}"
refuse "--remote-gw without --audit-tls" "usage" bank-c "$D" "$P" "${GW[@]}"
refuse "--remote-gw with a private address" "public" bank-c "$D" "$P" --audit-tls --remote-gw bi=10.0.0.5 --remote-gw bank-a=203.0.113.21 --remote-gw bank-b=203.0.113.22
refuse "--remote-gw with a CIDR instead of an address" "ipv4" bank-c "$D" "$P" --audit-tls --remote-gw bi=203.0.113.20/32 --remote-gw bank-a=203.0.113.21 --remote-gw bank-b=203.0.113.22
refuse "--remote-gw without a party" "must be" bank-c "$D" "$P" --audit-tls --remote-gw 203.0.113.20
# MUTANTS of the bank-c render: each must FAIL the checker
python3 -I scripts/check-driver.py bank-c "$D" "$H8" "$CHAIN" tls "${GWT[@]}" <<<"${out//203.0.113.21:8443/203.0.113.99:8443}" >/dev/null 2>&1 && fail "MUTANT: a wrong resolve address passed" || ok "MUTANT: a wrong [tls.resolve] address FAILS the checker"
python3 -I scripts/check-driver.py bank-c "$D" "$H8" "$CHAIN" tls "${GWT[@]}" <<<"$(python3 -I -c 'import sys; sys.stdout.write(sys.stdin.read().replace("\\n\\\"gateway.rd-iroha3-bank-b.svc.cluster.local\\\" = \\\"203.0.113.22:8443\\\"", ""))' <<<"$out")" >/dev/null 2>&1 && fail "MUTANT: a missing resolve entry passed" || ok "MUTANT: a missing [tls.resolve] entry FAILS the checker"
python3 -I scripts/check-driver.py bank-c "$D" "$H8" "$CHAIN" tls <<<"$out" >/dev/null 2>&1 && fail "MUTANT: bank-c without gw tokens passed" || ok "MUTANT: a bank-c render checked without --remote-gw FAILS the checker"
refuse "a remote gateway CIDR that is not a /32" "/32" bi "$D" "$P" --audit-tls --remote-gw-cidr 10.0.0.0/8
refuse "a remote gateway CIDR without a mask" "/32" bi "$D" "$P" --audit-tls --remote-gw-cidr 203.0.113.10
refuse "--remote-gw-cidr without --audit-tls" "usage" bi "$D" "$P" --remote-gw-cidr 203.0.113.10/32
mkdir "$T/p4"; cp "$P/chain_id" "$P/genesis.expected_hash" "$P/peers.json" "$T/p4/"
refuse "--audit-tls without the public server CAs" "server-ca" bi "$D" "$T/p4" --audit-tls
refuse "an unknown extra flag" "usage" bi "$D" "$P" --frob
a=$("$R" bi "$D" "$P"); b=$("$R" bi "$D" "$P")
[[ $a == "$b" ]] && ok "render is deterministic" || fail "render differs between runs"
before=$(find "$T" -type f | sort | xargs cksum)
"$R" bi "$D" "$P" >/dev/null; [[ $(find "$T" -type f | sort | xargs cksum) == "$before" ]] && ok "writes nothing" || fail "files changed"
# --mint-enabled (W0b, K6): the BI driver enables POST /mint; caps in an [auditor] table (required keys listen, store_dir, max_rd, max_dfabi, parties: node-build config.rs:96-118)
for mode in "" "--audit-tls"; do
  out=$("$R" bi "$D" "$P" $mode --mint-enabled --mint-max-rd 1000000000 --mint-max-dfabi 1000000 2>&1) || { fail "bi $mode --mint-enabled: render failed: $out"; continue; }
  python3 -I scripts/check-driver.py bi "$D" "$H8" "$CHAIN" $([[ -n $mode ]] && echo tls) mint:1000000000:1000000 <<<"$out" || fails=$((fails + 1))
done
refuse "--mint-enabled for bank-a (BI only)" "bi" bank-a "$D" "$P" --mint-enabled --mint-max-rd 1 --mint-max-dfabi 1
refuse "--mint-enabled without caps" "mint-max" bi "$D" "$P" --mint-enabled
refuse "--mint-enabled with a zero cap" "positive" bi "$D" "$P" --mint-enabled --mint-max-rd 0 --mint-max-dfabi 1
refuse "--mint-enabled with a non-numeric cap" "positive" bi "$D" "$P" --mint-enabled --mint-max-rd abc --mint-max-dfabi 1
refuse "--mint-enabled with a cap above 2^63" "positive" bi "$D" "$P" --mint-enabled --mint-max-rd 99999999999999999999 --mint-max-dfabi 1
refuse "--mint-max-rd without --mint-enabled" "usage" bi "$D" "$P" --mint-max-rd 5
mkdir "$T/p_acc"; cp "$P/chain_id" "$P/genesis.expected_hash" "$P/peers.json" "$T/p_acc/"; refuse "--mint-enabled without accounts.json" "accounts.json" bi "$D" "$T/p_acc" --mint-enabled --mint-max-rd 1 --mint-max-dfabi 1
# the plain render must NOT carry mint (checker mutant: a render with mint_enabled but checked as plain)
"$R" bi "$D" "$P" --mint-enabled --mint-max-rd 5 --mint-max-dfabi 5 | python3 -I scripts/check-driver.py bi "$D" "$H8" "$CHAIN" >/dev/null 2>&1 && fail "MUTANT: mint render accepted by the plain checker" || ok "MUTANT: a --mint-enabled render FAILS the plain checker"
"$R" bi "$D" "$P" --mint-enabled --mint-max-rd 5 --mint-max-dfabi 5 | python3 -I scripts/check-driver.py bi "$D" "$H8" "$CHAIN" mint:7:7 >/dev/null 2>&1 && fail "MUTANT: wrong caps accepted" || ok "MUTANT: wrong caps FAIL the mint checker"
# R17 end step MUTANTS of the rendered driver-egress policy (D2 shape, --audit-tls): each must make the checker FAIL
dmut() { # <label> <mode: plain|tls> <python statement on policy dict p>
  local good m args=(); [[ $2 == tls ]] && args=(--audit-tls)
  good=$("$R" bi "$D" "$P" "${args[@]}")
  m=$(python3 -I -c '
import sys, json, yaml
docs = [d for d in yaml.safe_load_all(sys.stdin.read()) if d]
for p in docs:
    if p["kind"] == "NetworkPolicy" and p["metadata"]["name"] == "driver-egress": exec(sys.argv[1])
print("\n---\n".join(json.dumps(d) for d in docs))' "$3" <<<"$good")
  python3 -I scripts/check-driver.py bi "$D" "$H8" "$CHAIN" $([[ $2 == tls ]] && echo tls) <<<"$m" >/dev/null 2>&1 && fail "MUTANT $1 passed the driver checker" || ok "MUTANT: $1 FAILS the driver checker ($2)"
}
# MUTANT: client.toml read through the Secret volume (symlink) instead of the subPath mount must FAIL the checker
good=$("$R" bi "$D" "$P")
m=$(python3 -I -c '
import sys, json, yaml
docs = [d for d in yaml.safe_load_all(sys.stdin.read()) if d]
for d in docs:
    if d["kind"] == "Deployment":
        c = d["spec"]["template"]["spec"]["containers"][0]; c["volumeMounts"] = [x for x in c["volumeMounts"] if x["mountPath"] != "/client/client.toml"]
print("\n---\n".join(json.dumps(d) for d in docs))' <<<"$good")
python3 -I scripts/check-driver.py bi "$D" "$H8" "$CHAIN" <<<"$m" >/dev/null 2>&1 && fail "MUTANT: no client.toml subPath mount passed" || ok "MUTANT: a driver without the client.toml subPath mount FAILS the checker"
for mode in plain tls; do
  dmut "an extra destination ipBlock 8.8.8.8/32" $mode 'p["spec"]["egress"].append({"to": [{"ipBlock": {"cidr": "8.8.8.8/32"}}], "ports": [{"protocol": "TCP", "port": 443}]})'
  dmut "a wildcard namespace selector on the Torii rule" $mode 'p["spec"]["egress"][1]["to"][0]["namespaceSelector"] = {}'
  dmut "an empty podSelector on the Torii rule" $mode 'p["spec"]["egress"][1]["to"][0]["podSelector"] = {}'
  dmut "an extra port 443 on the Torii rule" $mode 'p["spec"]["egress"][1]["ports"].append({"protocol": "TCP", "port": 443})'
done
dmut "the gateway rule missing from the --audit-tls policy" tls 'p["spec"]["egress"].pop()'
# --aps (APS all-flows, plan 2026-11-13-04): [aps] (BI coordinator, banks coordinator_url), 2Gi/3Gi, BI gw-tls sidecar. Banks: ConfigMap aps-pools from the operator's PUBLIC pools.json (bundles forced to []) + pools-seed init
# copy into /pools. BI (lead decision): NO ConfigMap; the PVC pools-index (deploy/pool-init) rw at /pools = pools_file, key_dir /pools/keys with the Secret's bi.seed/bi.note LINKED in (never copied), strategy Recreate (RWO)
PL="$T/pools.json"
jq -n --arg a "$(printf '7e%.0s' $(seq 1 32))" --arg b "$(printf 'e6%.0s' $(seq 1 32))" --arg o1 "$(printf 'ab%.0s' $(seq 1 32))" --arg o2 "$(printf 'cd%.0s' $(seq 1 32))" \
  '[$a, $b] | map({pool_id: ., route: "cm91dGU=", policy: "cG9saWN5", governance: "Z292ZXJuYW5jZQ==", origin: [$o1, $o2], bundles: [{id: $o1, height: 7}]}) | {rd: .[0], dfabi: .[1]}' > "$PL"  # a live index in the input: the bank render must force bundles to []
APS=(--aps --aps-pools "$PL"); APSBI=(--aps); BCGW=203.0.113.30
for p in bank-a bank-b; do
  out=$("$R" "$p" "$D" "$P" --audit-tls "${APS[@]}" 2>&1) || { fail "$p --aps: render failed: $out"; continue; }
  python3 -I scripts/check-driver.py "$p" "$D" "$H8" "$CHAIN" tls "aps:$PL" <<<"$out" || fails=$((fails + 1))
  python3 -I scripts/check-netpol-form.py "driver" <<<"$out" || fails=$((fails + 1))
done
for mode in "" "mint"; do  # BI: the coordinator, with and without the mint caps
  margs=(); mtok=(); [[ -n $mode ]] && { margs=(--mint-enabled --mint-max-rd 1000000000 --mint-max-dfabi 1000000); mtok=(mint:1000000000:1000000); }
  out=$("$R" bi "$D" "$P" --audit-tls "${APSBI[@]}" --remote-gw bank-c=$BCGW "${margs[@]}" 2>&1) || { fail "bi --aps $mode: render failed: $out"; continue; }
  python3 -I scripts/check-driver.py bi "$D" "$H8" "$CHAIN" tls "gw:bank-c=$BCGW" aps:pvc "${mtok[@]}" <<<"$out" || fails=$((fails + 1))
  python3 -I scripts/check-netpol-form.py "driver" <<<"$out" || fails=$((fails + 1))
done
out=$("$R" bank-c "$D" "$P" --audit-tls "${GW[@]}" "${APS[@]}" 2>&1) || fail "bank-c --aps: render failed: $out"
python3 -I scripts/check-driver.py bank-c "$D" "$H8" "$CHAIN" tls "${GWT[@]}" "aps:$PL" <<<"$out" || fails=$((fails + 1))
python3 -I scripts/check-netpol-form.py "driver" <<<"$out" || fails=$((fails + 1))
a=$("$R" bi "$D" "$P" --audit-tls "${APSBI[@]}" --remote-gw bank-c=$BCGW); b=$("$R" bi "$D" "$P" --audit-tls "${APSBI[@]}" --remote-gw bank-c=$BCGW)
[[ -n $a && $a == "$b" ]] && ok "the --aps render is deterministic" || fail "the --aps render differs between runs or is empty"
refuse "--aps without --audit-tls" "audit-tls" bank-a "$D" "$P" "${APS[@]}"
refuse "--aps without --aps-pools" "aps-pools" bank-a "$D" "$P" --audit-tls --aps
refuse "--aps-pools without --aps" "usage" bank-a "$D" "$P" --audit-tls --aps-pools "$PL"
refuse "--aps with a missing pools file" "not found" bank-a "$D" "$P" --audit-tls --aps --aps-pools "$T/none.json"
refuse "BI --aps without --remote-gw bank-c" "bank-c" bi "$D" "$P" --audit-tls "${APSBI[@]}"
refuse "BI --aps with a private bank-c address" "public" bi "$D" "$P" --audit-tls "${APSBI[@]}" --remote-gw bank-c=10.0.0.5
refuse "BI --aps with a second --remote-gw party" "bank-c=<ipv4> only" bi "$D" "$P" --audit-tls "${APSBI[@]}" --remote-gw bank-c=$BCGW --remote-gw bank-a=203.0.113.21
refuse "BI --aps with --aps-pools (BI keeps its pools on the PVC pools-index)" "pools-index" bi "$D" "$P" --audit-tls "${APS[@]}" --remote-gw bank-c=$BCGW
refuse "--remote-gw bank-c=<ip> for BI without --aps" "driver only" bi "$D" "$P" --audit-tls --remote-gw bank-c=$BCGW
refuse "--remote-gw bank-c=<ip> for a bank" "bi, bank-a or bank-b" bank-a "$D" "$P" --audit-tls "${APS[@]}" --remote-gw bank-c=$BCGW
refuse "bank-c --aps with --remote-gw bank-c" "bi, bank-a or bank-b" bank-c "$D" "$P" --audit-tls "${APS[@]}" "${GW[@]}" --remote-gw bank-c=$BCGW
for spec in 'a pools file with an extra secret field|.rd.seed = "x"' 'a pools file without dfabi|del(.dfabi)' 'a pools file with a third pool|.x = .rd' 'a pool_id that is not 64 hex|.rd.pool_id = "7e"' 'a pools file without origin|del(.rd.origin)' 'a pools file with 3 origin commitments|.rd.origin += ["ab"]'; do
  label=${spec%%|*}; filter=${spec#*|}
  jq "$filter" "$PL" > "$T/bad.json"
  err=$("$R" bank-a "$D" "$P" --audit-tls --aps --aps-pools "$T/bad.json" 2>&1 >/dev/null); rc=$?
  [[ $rc -eq 2 && $err == *"Pool"* ]] && ok "refuses $label (exit 2)" || fail "$label not refused as expected (rc=$rc: $err)"
done
apsmut() { # <label> <party> <python statement on the rendered docs list>
  local p=$2 good m ptok rargs=(--audit-tls "${APS[@]}") cargs=(tls)
  [[ $p == bi ]] && { rargs=(--audit-tls "${APSBI[@]}" --remote-gw bank-c=$BCGW); cargs+=("gw:bank-c=$BCGW"); }
  [[ $p == bi ]] && ptok=aps:pvc || ptok="aps:$PL"
  good=$("$R" "$p" "$D" "$P" "${rargs[@]}")
  m=$(python3 -I -c '
import sys, json, yaml
docs = [d for d in yaml.safe_load_all(sys.stdin.read()) if d]
exec(sys.argv[1])
print("\n---\n".join(json.dumps(d) for d in docs))' "$3" <<<"$good") || { fail "MUTANT $1: the mutation script itself failed"; return; }
  python3 -I scripts/check-driver.py "$p" "$D" "$H8" "$CHAIN" "${cargs[@]}" "$ptok" <<<"$m" >/dev/null 2>&1 && fail "MUTANT $1 passed the driver checker" || ok "MUTANT: $1 FAILS the driver checker (--aps $p)"
}
DEP='dep = next(d for d in docs if d["kind"] == "Deployment"); ps = dep["spec"]["template"]["spec"]; '
CFG='cfg = next(d for d in docs if d["metadata"]["name"] == "driver-config"); '
GWE='gwe = next(d for d in docs if d["metadata"]["name"] == "driver-gw-envoy"); e = json.loads(gwe["data"]["envoy.yaml"]); '
apsmut "the driver memory limit 1Gi" bank-a "$DEP"'ps["containers"][0]["resources"]["limits"]["memory"] = "1Gi"'
apsmut "the driver memory request 64Mi" bank-a "$DEP"'ps["containers"][0]["resources"]["requests"]["memory"] = "64Mi"'
apsmut "the pools-seed init container dropped" bank-a "$DEP"'ps.pop("initContainers")'
apsmut "ConfigMap aps-pools missing" bank-a 'docs[:] = [d for d in docs if d["metadata"]["name"] != "aps-pools"]'
apsmut "a secret field in aps-pools" bank-a 'a = next(d for d in docs if d["metadata"]["name"] == "aps-pools"); p = json.loads(a["data"]["pools.json"]); p["rd"]["seed"] = "x"; a["data"]["pools.json"] = json.dumps(p)'
apsmut "a pool id changed in aps-pools" bank-a 'a = next(d for d in docs if d["metadata"]["name"] == "aps-pools"); p = json.loads(a["data"]["pools.json"]); p["rd"]["pool_id"] = "0" * 64; a["data"]["pools.json"] = json.dumps(p)'
apsmut "/pools mounted read-only" bank-a "$DEP"'next(m for m in ps["containers"][0]["volumeMounts"] if m["mountPath"] == "/pools")["readOnly"] = True'
apsmut "a bank rendered as the coordinator" bank-a "$CFG"'cfg["data"]["rd-dfabi.toml"] = cfg["data"]["rd-dfabi.toml"].replace("coordinator_url = \"https://gateway.rd-iroha3-bi.svc.cluster.local:8443\"", "coordinator = true")'
apsmut "the BI coordinator_url pointing at another gateway" bank-a "$CFG"'cfg["data"]["rd-dfabi.toml"] = cfg["data"]["rd-dfabi.toml"].replace("gateway.rd-iroha3-bi.svc", "gateway.rd-iroha3-bank-a.svc")'
apsmut "the BI driver without coordinator = true" bi "$CFG"'cfg["data"]["rd-dfabi.toml"] = cfg["data"]["rd-dfabi.toml"].replace("coordinator = true", "coordinator = false")'
apsmut "the BI driver [torii] left on the direct Torii (no sidecar path)" bi "$CFG"'cfg["data"]["rd-dfabi.toml"] = cfg["data"]["rd-dfabi.toml"].replace("http://127.0.0.1:18104/", "http://bank-c-0.bank-c.rd-iroha3-bank-c.svc.cluster.local:8080/")'
apsmut "the BI gw-tls sidecar dropped" bi "$DEP"'ps["initContainers"] = [i for i in ps["initContainers"] if i["name"] != "gw-tls"]'
apsmut "the BI gw-tls sidecar a plain init container (no restartPolicy Always)" bi "$DEP"'next(i for i in ps["initContainers"] if i["name"] == "gw-tls").pop("restartPolicy")'
apsmut "the BI gw-tls sidecar on a loopback port that is not 18101-18104" bi "$GWE"'e["static_resources"]["listeners"][3]["address"]["socket_address"]["port_value"] = 18199; gwe["data"]["envoy.yaml"] = json.dumps(e)'
apsmut "the BI gw-tls listener on 0.0.0.0" bi "$GWE"'e["static_resources"]["listeners"][0]["address"]["socket_address"]["address"] = "0.0.0.0"; gwe["data"]["envoy.yaml"] = json.dumps(e)'
apsmut "the BI gw-tls bank-c upstream not the --remote-gw address" bi "$GWE"'gwe["data"]["envoy.yaml"] = gwe["data"]["envoy.yaml"].replace("203.0.113.30", "203.0.113.99")'
apsmut "the BI driver-egress without the bank-c /32" bi 'e = next(d for d in docs if d["metadata"]["name"] == "driver-egress"); e["spec"]["egress"][2]["to"].pop()'
apsmut "the BI driver-egress with an extra ipBlock" bi 'e = next(d for d in docs if d["metadata"]["name"] == "driver-egress"); e["spec"]["egress"][2]["to"].append({"ipBlock": {"cidr": "8.8.8.8/32"}})'
apsmut "a gw-tls sidecar on a bank driver" bank-a "$DEP"'ps["initContainers"].append({"name": "gw-tls", "image": "x", "restartPolicy": "Always"})'
apsmut "a bank aps-pools carrying a bundle index (bundles not forced to [])" bank-a 'a = next(d for d in docs if d["metadata"]["name"] == "aps-pools"); p = json.loads(a["data"]["pools.json"]); p["rd"]["bundles"] = [{"id": "ab", "height": 7}]; a["data"]["pools.json"] = json.dumps(p)'
apsmut "the BI pools volume an emptyDir instead of the PVC pools-index" bi "$DEP"'v = next(v for v in ps["volumes"] if v["name"] == "pools"); v.pop("persistentVolumeClaim"); v["emptyDir"] = {}'
apsmut "the BI pools PVC of another name" bi "$DEP"'next(v for v in ps["volumes"] if v["name"] == "pools")["persistentVolumeClaim"]["claimName"] = "pools"'
apsmut "the BI Deployment without strategy Recreate (RWO volume)" bi "$DEP"'dep["spec"].pop("strategy")'
apsmut "the BI /pools mounted read-only" bi "$DEP"'next(m for m in ps["containers"][0]["volumeMounts"] if m["mountPath"] == "/pools")["readOnly"] = True'
apsmut "a ConfigMap aps-pools rendered for BI" bi 'docs.append({"apiVersion": "v1", "kind": "ConfigMap", "metadata": {"name": "aps-pools", "namespace": "rd-iroha3-bi", "labels": {"app.kubernetes.io/part-of": "rd-iroha3"}}, "data": {"pools.json": "{}"}})'
apsmut "the BI key_dir left on /keys" bi "$CFG"'cfg["data"]["rd-dfabi.toml"] = cfg["data"]["rd-dfabi.toml"].replace("/pools/keys", "/keys")'
apsmut "the BI key files COPIED into /pools/keys instead of linked" bi "$DEP"'i = next(i for i in ps["initContainers"] if i["name"] == "pools-link"); i["command"][-1] = i["command"][-1].replace("ln -s", "cp")'
apsmut "the BI note link missing" bi "$DEP"'i = next(i for i in ps["initContainers"] if i["name"] == "pools-link"); i["command"][-1] = i["command"][-1].replace("bi.note", "x.note")'
apsmut "the BI pools-link init container dropped" bi "$DEP"'ps["initContainers"] = [i for i in ps["initContainers"] if i["name"] != "pools-link"]'
apsmut "the BI pools-link not mounting the Secret read-only" bi "$DEP"'i = next(i for i in ps["initContainers"] if i["name"] == "pools-link"); next(m for m in i["volumeMounts"] if m["mountPath"] == "/keys")["readOnly"] = False'
# the plain render must NOT carry --aps, and an --aps render is not a plain one
"$R" bank-a "$D" "$P" --audit-tls | python3 -I scripts/check-driver.py bank-a "$D" "$H8" "$CHAIN" tls "aps:$PL" >/dev/null 2>&1 && fail "MUTANT: a plain render passed the --aps checker" || ok "MUTANT: a plain render FAILS the --aps checker"
"$R" bank-a "$D" "$P" --audit-tls "${APS[@]}" | python3 -I scripts/check-driver.py bank-a "$D" "$H8" "$CHAIN" tls >/dev/null 2>&1 && fail "MUTANT: an --aps render passed the plain checker" || ok "MUTANT: an --aps render FAILS the plain checker"
if (( fails )); then echo "FAILED: $fails check(s)" >&2; exit 1; fi
echo "PASS"
