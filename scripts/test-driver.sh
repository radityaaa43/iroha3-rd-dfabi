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
for mode in plain tls; do
  dmut "an extra destination ipBlock 8.8.8.8/32" $mode 'p["spec"]["egress"].append({"to": [{"ipBlock": {"cidr": "8.8.8.8/32"}}], "ports": [{"protocol": "TCP", "port": 443}]})'
  dmut "a wildcard namespace selector on the Torii rule" $mode 'p["spec"]["egress"][1]["to"][0]["namespaceSelector"] = {}'
  dmut "an empty podSelector on the Torii rule" $mode 'p["spec"]["egress"][1]["to"][0]["podSelector"] = {}'
  dmut "an extra port 443 on the Torii rule" $mode 'p["spec"]["egress"][1]["ports"].append({"protocol": "TCP", "port": 443})'
done
dmut "the gateway rule missing from the --audit-tls policy" tls 'p["spec"]["egress"].pop()'
if (( fails )); then echo "FAILED: $fails check(s)" >&2; exit 1; fi
echo "PASS"
