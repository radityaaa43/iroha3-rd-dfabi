#!/usr/bin/env bash
# Offline test of deploy/aps-run/render.sh (no cluster; python3 + PyYAML). Exit != 0 on any failure.
set -uo pipefail
cd "$(dirname "$0")/.."
R=deploy/aps-run/render.sh
fails=0
fail() { echo "FAIL: $*" >&2; fails=$((fails + 1)); }
ok() { echo "ok:   $*"; }
T=$(mktemp -d); trap 'rm -r -- "$T"' EXIT
D=sha256:$(printf 'a%.0s' $(seq 1 64))
P="$T/public"; mkdir -p "$P/gateway-ca"
echo 11111111-2222-4333-8444-555555555555 > "$P/chain_id"
printf 'hash:%s#ABCD\n' "$(printf '0123456789ABCDEF%.0s' 1 2 3 4)" > "$P/genesis.expected_hash"
jq -n '[ "bi","bank-a","bank-b","bank-c" | {party: ., public_key: ("ea0130" + .), pop_hex: "0xaa"} ]' > "$P/peers.json"
for q in bi bank-a bank-b bank-c; do printf -- '-----BEGIN CERTIFICATE-----\nMIIB%s\n-----END CERTIFICATE-----\n' "$q" > "$P/gateway-ca/$q-server-ca.pem"; done
IP=203.0.113.9
PAY=(pay --asset rd --from bi --to bi --amount 7)
refuse() { local label=$1 part=$2; shift 2; local err rc; err=$("$R" "$@" 2>&1 >/dev/null); rc=$?; [[ $rc -eq 2 && $err == *"$part"* ]] && ok "refuses $label (exit 2)" || fail "$label not refused as expected (rc=$rc: $err)"; }
refuse "no arguments" "usage"
refuse "a tag instead of a digest" "digest" debian:latest "$P" red1 "$IP" "${PAY[@]}"
refuse "a bad run name" "name" "$D" "$P" "Bad_Name" "$IP" "${PAY[@]}"
refuse "a private bank-c address" "public" "$D" "$P" red1 10.0.0.5 "${PAY[@]}"
refuse "a command other than pay/wallet/pool-history" "command" "$D" "$P" red1 "$IP" pool-init --rd-reserve 1 --dfabi-reserve 1
refuse "a payment to a party other than bi" "bi" "$D" "$P" red1 "$IP" pay --asset rd --from bi --to bank-a --amount 7
refuse "a non-numeric amount" "amount" "$D" "$P" red1 "$IP" pay --asset rd --from bi --to bi --amount 7x
mkdir "$T/p3"; cp -r "$P"/* "$T/p3/"; : > "$T/p3/x.seed"; refuse "a public dir holding a seed" "private material" "$D" "$T/p3" red1 "$IP" "${PAY[@]}"
out=$("$R" "$D" "$P" red1 "$IP" "${PAY[@]}" 2>&1) || fail "render failed: $out"
python3 -I scripts/check-apsrun.py "$D" red1 "$IP" "${PAY[@]}" <<<"$out" || fails=$((fails + 1))
python3 -I scripts/check-netpol-form.py "apsrun" <<<"$out" || fails=$((fails + 1))
out2=$("$R" "$D" "$P" w1 "$IP" wallet --party bi 2>&1) || fail "wallet render failed: $out2"
python3 -I scripts/check-apsrun.py "$D" w1 "$IP" wallet --party bi <<<"$out2" || fails=$((fails + 1))
mut() { # <label> <python statement on the doc list docs>
  local m; m=$(python3 -I -c 'import sys,json; docs=[json.loads(x) for x in sys.stdin.read().split("\n---\n")]; exec(sys.argv[1]); print("\n---\n".join(json.dumps(d) for d in docs))' "$2" <<<"$out")
  python3 -I scripts/check-apsrun.py "$D" red1 "$IP" "${PAY[@]}" <<<"$m" >/dev/null 2>&1 && fail "MUTANT $1 passed" || ok "MUTANT: $1 FAILS the checker"
}
mut "the bi-gov seed mounted" 'j=[d for d in docs if d["kind"]=="Job"][0]; j["spec"]["template"]["spec"]["volumes"].append({"name":"gov","secret":{"secretName":"bi-gov-key"}})'
mut "a direct Torii URL instead of the sidecar" 'c=[d for d in docs if d["metadata"]["name"]=="aps-run-config"][0]; c["data"]["rd-dfabi.toml"]=c["data"]["rd-dfabi.toml"].replace("http://127.0.0.1:18102/","http://bank-a-0.bank-a.rd-iroha3-bank-a.svc.cluster.local:8080/")'
mut "a sidecar listener on 0.0.0.0" 'import yaml; c=[d for d in docs if d["metadata"]["name"]=="aps-run-gw-envoy"][0]; c["data"]["envoy.yaml"]=c["data"]["envoy.yaml"].replace("127.0.0.1","0.0.0.0",1)'
mut "an egress to any Torii :8080" 'n=[d for d in docs if d["kind"]=="NetworkPolicy"][0]; n["spec"]["egress"].append({"to":[{"podSelector":{"matchLabels":{"rd-iroha3/role":"peer"}}}],"ports":[{"protocol":"TCP","port":8080}]})'
mut "backoffLimit 1" 'j=[d for d in docs if d["kind"]=="Job"][0]; j["spec"]["backoffLimit"]=1'
a=$("$R" "$D" "$P" red1 "$IP" "${PAY[@]}"); b=$("$R" "$D" "$P" red1 "$IP" "${PAY[@]}")
[[ -n $a && $a == "$b" ]] && ok "render is deterministic" || fail "render differs between runs or is empty"
if (( fails )); then echo "FAILED: $fails check(s)" >&2; exit 1; fi
echo "PASS"
