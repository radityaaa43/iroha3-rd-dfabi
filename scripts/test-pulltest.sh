#!/usr/bin/env bash
# Offline test of deploy/pull-test/render.sh (S13 gate G5: pull test of the EXACT images): refusals, determinism, checker on bi/bank-a/bank-b, mutants.
set -uo pipefail
cd "$(dirname "$0")/.."
R=deploy/pull-test/render.sh; C=scripts/check-pulltest.py
fails=0; fail() { echo "FAIL: $*" >&2; fails=$((fails + 1)); }; ok() { echo "ok:   $*"; }
D=sha256:$(printf 'a%.0s' $(seq 1 64)); EV=envoyproxy/envoy@sha256:$(printf 'b%.0s' $(seq 1 64)); TL=docker.io/alpine/k8s@sha256:$(printf 'c%.0s' $(seq 1 64))
refuse() { local label=$1 part=$2; shift 2; local err rc; err=$("$R" "$@" 2>&1 >/dev/null); rc=$?; [[ $rc -eq 2 && $err == *"$part"* ]] && ok "refuses $label (exit 2)" || fail "$label not refused (rc=$rc): $err"; }
refuse "no arguments" "usage"
refuse "bank-c (no auditor there)" "usage" bank-c "$D" "$EV" "$TL"
refuse "an unknown party" "usage" nobody "$D" "$EV" "$TL"
refuse "a tag driver image" "driver" bi debian:latest "$EV" "$TL"
refuse "an envoy image by tag" "envoy" bi "$D" envoyproxy/envoy:v1.30.0 "$TL"
refuse "a tools image by tag" "tools" bi "$D" "$EV" docker.io/alpine/k8s:1.34.13
for p in bi bank-a bank-b; do
  out=$("$R" "$p" "$D" "$EV" "$TL" 2>&1) || { fail "$p: render failed: $out"; continue; }
  python3 -I "$C" "$p" "$D" "$EV" "$TL" <<<"$out" || fails=$((fails + 1))
  python3 -I scripts/check-netpol-form.py "pulltest" <<<"$out" || fails=$((fails + 1))
done
a=$("$R" bi "$D" "$EV" "$TL"); b=$("$R" bi "$D" "$EV" "$TL")
[[ -n $a && $a == "$b" ]] && ok "render is deterministic" || fail "render differs between runs or is empty"
mut() { # <label> <python on docs by (kind,name)>
  python3 -I -c '
import sys, yaml
docs = [d for d in yaml.safe_load_all(sys.stdin.read()) if d]
by = {(d["kind"], d["metadata"]["name"]): d for d in docs}
exec(sys.argv[1]); print(yaml.safe_dump_all(docs))' "$2" <<<"$a" | python3 -I "$C" bi "$D" "$EV" "$TL" >/dev/null 2>&1 && fail "MUTANT $1 passed" || ok "MUTANT: $1 FAILS"
}
P='by[("Pod","pull-test")]["spec"]'
mut "an image by tag" "$P"'["containers"][1]["image"] = "envoyproxy/envoy:v1.30.0"'
mut "imagePullPolicy IfNotPresent (a cached image would pass unseen)" "$P"'["containers"][0]["imagePullPolicy"] = "IfNotPresent"'
mut "a container that runs something else" "$P"'["containers"][2]["command"] = ["/bin/sh", "-c", "sleep 3600"]'
mut "an SA token" "$P"'["automountServiceAccountToken"] = True'
mut "a nodeName" "$P"'["nodeName"] = "node-1"'
mut "a Secret volume" "$P"'["volumes"] = [{"name": "s", "secret": {"secretName": "bi-keys"}}]'
mut "a fourth container" "$P"'["containers"].append(dict($P["containers"][0], name="x"))'
mut "the pod without rd/egress-locked" 'by[("Pod","pull-test")]["metadata"]["labels"].pop("rd/egress-locked")'
mut "the NetworkPolicy opening DNS" 'by[("NetworkPolicy","pull-test-egress")]["spec"]["egress"] = [{"ports": [{"protocol": "UDP", "port": 53}]}]'
if (( fails )); then echo "FAILED: $fails check(s)" >&2; exit 1; fi
echo "PASS"
