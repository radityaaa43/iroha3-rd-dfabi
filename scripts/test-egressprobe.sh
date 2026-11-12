#!/usr/bin/env bash
# Offline test of deploy/egress-probe/render.sh (no cluster; python3 + PyYAML). Exit != 0 on any failure.
set -uo pipefail
cd "$(dirname "$0")/.."
R=deploy/egress-probe/render.sh
fails=0
fail() { echo "FAIL: $*" >&2; fails=$((fails + 1)); }
ok() { echo "ok:   $*"; }
T=$(mktemp -d); trap 'find "$T" -delete' EXIT
D=sha256:$(printf 'a%.0s' $(seq 1 64))
refuse() { local label=$1 part=$2; shift 2; local err rc; err=$("$R" "$@" 2>&1 >/dev/null); rc=$?; [[ $rc -eq 2 && $err == *"$part"* ]] && ok "refuses $label (exit 2)" || fail "$label not refused (rc=$rc): $err"; }
refuse "no arguments" "usage"
refuse "an unknown party" "usage" bank-z "$D"
refuse "a tag instead of a digest" "digest" bi "debian:latest"
for p in bi bank-a bank-b bank-c; do
  out=$("$R" "$p" "$D" 2>&1) || { fail "$p: render failed: $out"; continue; }
  python3 -I scripts/check-egressprobe.py "$p" "$D" <<<"$out" || fails=$((fails + 1))
  python3 -I scripts/check-netpol-form.py "egressprobe" <<<"$out" || fails=$((fails + 1))
done
# The in-pod status parser (between the PARSE markers of the rendered loop) on REAL-format fixtures (scripts/fixtures/torii-status: derived from the pinned source,
# see the header of the fixtures' generator in the PR) and on a binary body: counts must come out of the pretty JSON (": " after every key, multi-line), nothing out of
# Norito bytes, and ctype/http/bytes are always shown, never the body.
"$R" bi "$D" | python3 -I -c '
import sys, json
docs = [json.loads(x) for x in sys.stdin.read().split("\n---\n")]
s = [d for d in docs if d["kind"] == "Pod"][0]["spec"]["containers"][0]["command"][2]
a, b = s.index("# PARSE-BEGIN"), s.index("# PARSE-END")
open(sys.argv[1], "w").write(s[a:b])
assert "Accept: application/json" in s, "the probe must request JSON explicitly (default is Norito binary)"
' "$T/parse.sh" && ok "the rendered loop has PARSE markers and requests Accept: application/json" || fail "no PARSE markers / no Accept: application/json in the loop"
chk() { # <fixture> <expected output>
  local got; got=$(bash -c 'source "$1"; parse "$2"' _ "$T/parse.sh" "scripts/fixtures/torii-status/$1" 2>&1)
  [[ $got == "$2" ]] && ok "parse $1 -> $2" || fail "parse $1: got '$got', want '$2'"
}
body_len() { python3 -I -c 'import sys; d=open(sys.argv[1],"rb").read(); print(len(d)-d.index(b"\r\n\r\n")-4)' "scripts/fixtures/torii-status/$1"; }
chk status-json-pretty.http "http=200 ctype=application/json bytes=$(body_len status-json-pretty.http) counts=[peers:3 blocks:1 view_changes:0 ]"
chk status-json-compact.http "http=200 ctype=application/json bytes=$(body_len status-json-compact.http) counts=[peers:3 blocks:1 view_changes:0 ]"
chk status-norito-binary.http "http=200 ctype=application/x-norito bytes=$(body_len status-norito-binary.http) counts=[]"
chk status-401.http "http=401 ctype=application/json bytes=$(body_len status-401.http) counts=[]"
# --role driver: the positive control of the torii-bootstrap deletion (S14.G): ONLY a Pod labelled role=driver (no egress-locked label, no policy, no Secret)
for p in bi bank-a bank-b bank-c; do
  out=$("$R" "$p" "$D" --role driver 2>&1) || { fail "$p --role driver: render failed: $out"; continue; }
  python3 -I scripts/check-egressprobe.py "$p" "$D" driver <<<"$out" || fails=$((fails + 1))
  python3 -I scripts/check-netpol-form.py "egressprobe-driver" <<<"$out" || fails=$((fails + 1))
done
# --role peer: the positive/negative control of peers-egress (R17): ONLY a Pod labelled rd-iroha3/role=peer (nothing else), remote P2P /32 values from the command line
declare -A REM=([bi]="43.106.70.123/32" [bank-a]="43.106.70.123/32" [bank-b]="43.106.70.123/32" [bank-c]="147.139.197.22/32 147.139.195.93/32 8.215.12.88/32")
for p in bi bank-a bank-b bank-c; do
  args=(); rem=(); for r in ${REM[$p]}; do args+=(--remote-p2p "$r"); rem+=("${r%/32}"); done
  out=$("$R" "$p" "$D" --role peer "${args[@]}" 2>&1) || { fail "$p --role peer: render failed: $out"; continue; }
  python3 -I scripts/check-egressprobe.py "$p" "$D" peer "${rem[@]}" <<<"$out" || fails=$((fails + 1))
  python3 -I scripts/check-netpol-form.py "egressprobe-peer" <<<"$out" || fails=$((fails + 1))
done
# MUTANTS of the peer-role Pod: any extra label (party/part-of => matches the Service/StatefulSet selectors) or a container port must FAIL the checker
peer_out=$("$R" bi "$D" --role peer --remote-p2p 43.106.70.123/32)
mutant() { # <label> <python statement on pod d>
  python3 -I -c '
import sys, yaml
d = yaml.safe_load(sys.stdin.read()); exec(sys.argv[1]); print(yaml.safe_dump(d))' "$2" <<<"$peer_out" | python3 -I scripts/check-egressprobe.py bi "$D" peer 43.106.70.123 >/dev/null 2>&1 && fail "MUTANT $1 passed" || ok "MUTANT: $1 FAILS the peer-role checker"
}
mutant "a peer-role probe also labelled rd-iroha3/party" 'd["metadata"]["labels"]["rd-iroha3/party"] = "bi"'
mutant "a peer-role probe also labelled app.kubernetes.io/part-of" 'd["metadata"]["labels"]["app.kubernetes.io/part-of"] = "rd-iroha3"'
mutant "a peer-role probe with a container port" 'd["spec"]["containers"][0]["ports"] = [{"containerPort": 1337}]'
mutant "a peer-role probe with a service account token" 'd["spec"]["automountServiceAccountToken"] = True'
# --role gateway: control of gateway-egress (R17): ONLY a Pod labelled role=gateway + app.kubernetes.io/name=gateway (W1 admits that name; no Service/Deployment selector matches it)
for p in bi bank-a bank-b bank-c; do
  out=$("$R" "$p" "$D" --role gateway 2>&1) || { fail "$p --role gateway: render failed: $out"; continue; }
  python3 -I scripts/check-egressprobe.py "$p" "$D" gateway <<<"$out" || fails=$((fails + 1))
  python3 -I scripts/check-netpol-form.py "egressprobe-gateway" <<<"$out" || fails=$((fails + 1))
done
# --role lb: the LB/ACL functional proof: egress = ONLY the target LB /32 on 8443 (its own policy), no DNS, no token, deadline
for p in bi bank-c; do
  out=$("$R" "$p" "$D" --role lb --lb-target 43.106.70.123/32 --lb-target 147.139.197.22/32 2>&1) || { fail "$p --role lb: render failed: $out"; continue; }
  python3 -I scripts/check-egressprobe.py "$p" "$D" lb 43.106.70.123 147.139.197.22 <<<"$out" || fails=$((fails + 1))
  python3 -I scripts/check-netpol-form.py "egressprobe-lb" <<<"$out" || fails=$((fails + 1))
done
refuse "--role lb without a target" "usage" bi "$D" --role lb
refuse "--role lb with a wide CIDR" "/32" bi "$D" --role lb --lb-target 10.0.0.0/8
refuse "--role lb with a private address" "public" bi "$D" --role lb --lb-target 10.1.2.3/32
refuse "--lb-target without --role lb" "usage" bi "$D" --lb-target 43.106.70.123/32
refuse "--role lb with --remote-p2p" "usage" bi "$D" --role lb --remote-p2p 43.106.70.123/32
refuse "--role peer with --lb-target" "usage" bi "$D" --role peer --lb-target 43.106.70.123/32
refuse "--role gateway with a target" "usage" bi "$D" --role gateway --lb-target 43.106.70.123/32
gw_out=$("$R" bi "$D" --role gateway); lb_out=$("$R" bi "$D" --role lb --lb-target 43.106.70.123/32)
mutate() { # <label> <manifest text> <checker args> <python statement on doc d of kind Pod|NetworkPolicy>
  python3 -I -c '
import sys, yaml
docs = [d for d in yaml.safe_load_all(sys.argv[2]) if d]
for d in docs: exec(sys.argv[1])
print(yaml.safe_dump_all(docs))' "$4" "$2" | python3 -I scripts/check-egressprobe.py bi "$D" $3 >/dev/null 2>&1 && fail "MUTANT $1 passed" || ok "MUTANT: $1 FAILS the checker"
}
mutate "a gateway-role probe also labelled part-of/party (matches the gateway Service)" "$gw_out" "gateway" 'd["metadata"]["labels"].update({"app.kubernetes.io/part-of": "rd-iroha3", "rd-iroha3/party": "bi"})'
mutate "a gateway-role probe without the W1 name label" "$gw_out" "gateway" 'd["metadata"]["labels"].pop("app.kubernetes.io/name")'
mutate "a gateway-role probe without the deadline" "$gw_out" "gateway" 'd["spec"].pop("activeDeadlineSeconds")'
mutate "a gateway-role probe with a container port" "$gw_out" "gateway" 'd["spec"]["containers"][0]["ports"] = [{"containerPort": 8443}]'
mutate "an lb probe policy with an extra DNS rule" "$lb_out" "lb 43.106.70.123" 'd["kind"] == "NetworkPolicy" and d["spec"]["egress"].append({"to": [{"namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": "kube-system"}}}], "ports": [{"protocol": "UDP", "port": 53}]})'
mutate "an lb probe policy with a wider ipBlock" "$lb_out" "lb 43.106.70.123" 'd["kind"] == "NetworkPolicy" and d["spec"]["egress"][0]["to"].append({"ipBlock": {"cidr": "8.8.8.8/32"}})'
mutate "an lb probe policy on another port" "$lb_out" "lb 43.106.70.123" 'd["kind"] == "NetworkPolicy" and d["spec"]["egress"][0]["ports"].append({"protocol": "TCP", "port": 443})'
mutate "an lb probe also labelled role=peer-ish extra label" "$lb_out" "lb 43.106.70.123" 'd["kind"] == "Pod" and d["metadata"]["labels"].update({"rd-iroha3/party": "bi"})'
mutate "an lb probe without the deadline" "$lb_out" "lb 43.106.70.123" 'd["kind"] == "Pod" and d["spec"].pop("activeDeadlineSeconds")'
refuse "--role peer without a remote /32" "usage" bi "$D" --role peer
refuse "--role peer with a wide CIDR" "/32" bi "$D" --role peer --remote-p2p 10.0.0.0/8
refuse "--role peer with a private address" "public" bi "$D" --role peer --remote-p2p 10.1.2.3/32
refuse "--remote-p2p without --role peer" "usage" bi "$D" --remote-p2p 43.106.70.123/32
# --role driver-min: the P-pos of S14.G once gateways are live: label ONLY rd-iroha3/role=driver (no part-of/party): no Service `driver` endpoint, admitted by peers-torii and selected by driver-egress
for p in bi bank-a bank-b bank-c; do
  out=$("$R" "$p" "$D" --role driver-min 2>&1) || { fail "$p --role driver-min: render failed: $out"; continue; }
  python3 -I scripts/check-egressprobe.py "$p" "$D" driver-min <<<"$out" || fails=$((fails + 1))
  python3 -I scripts/check-netpol-form.py "egressprobe-driver-min" <<<"$out" || fails=$((fails + 1))
done
dm_out=$("$R" bi "$D" --role driver-min)
python3 -I -c '
import sys, yaml
d = yaml.safe_load(sys.stdin.read()); d["metadata"]["labels"].update({"app.kubernetes.io/part-of": "rd-iroha3", "rd-iroha3/party": "bi"}); print(yaml.safe_dump(d))' <<<"$dm_out" | python3 -I scripts/check-egressprobe.py bi "$D" driver-min >/dev/null 2>&1 && fail "MUTANT driver-min probe with part-of+party labels passed" || ok "MUTANT: a driver-min probe also labelled part-of+party (matches Service driver) FAILS the checker"
refuse "--role driver-min with a target" "usage" bi "$D" --role driver-min --lb-target 43.106.70.123/32
refuse "an unknown --role" "usage" bi "$D" --role frob
refuse "--role without a value" "usage" bi "$D" --role
a=$("$R" bi "$D"); b=$("$R" bi "$D")
[[ -n $a && $a == "$b" ]] && ok "render is deterministic" || fail "render differs between runs or is empty"
if (( fails )); then echo "FAILED: $fails check(s)" >&2; exit 1; fi
echo "PASS"
