#!/usr/bin/env bash
# Offline test of scripts/check-rbac-exec.py: (1) EVERY tracked manifest of this repo passes (a new Role anywhere that grants pods/exec|attach|portforward, a wildcard resource or
# unnamed secrets get/list/watch fails CI); (2) mutants must FAIL; (3) the auditor client-key render (named single-Secret rule) passes.
set -uo pipefail
cd "$(dirname "$0")/.."
C=scripts/check-rbac-exec.py
fails=0; fail() { echo "FAIL: $*" >&2; fails=$((fails + 1)); }; ok() { echo "ok:   $*"; }
T=$(mktemp -d); trap 'find "$T" -delete' EXIT
# (1) the repo tree itself
mapfile -t tracked < <(git ls-files '*.yaml' '*.yml' '*.tpl' '*.json')
python3 -I "$C" repo-tree "${tracked[@]}" || fails=$((fails + 1))
# (2) mutants
role() { cat <<YAML
apiVersion: rbac.authorization.k8s.io/v1
kind: ${3:-Role}
metadata: {name: m, namespace: x}
rules:
  - apiGroups: [""]
    resources: $1
    verbs: $2
YAML
}
mut() { # <label> <resources> <verbs> [kind] [extra rule line]
  python3 -I "$C" m <<<"$(role "$2" "$3" "${4:-Role}")" >/dev/null 2>&1 && fail "MUTANT $1 passed" || ok "MUTANT: $1 FAILS"
}
mut "pods/exec create" "[pods/exec]" "[create]"
mut "pods/attach create" "[pods/attach]" "[create]"
mut "pods/portforward create" "[pods/portforward]" "[create]"
mut "pods/* wildcard subresource" "[pods/*]" "[create]"
mut "wildcard resource" "['*']" "[get]"
mut "secrets get without resourceNames" "[secrets]" "[get]"
mut "secrets list without resourceNames" "[secrets]" "[list]"
mut "secrets watch without resourceNames" "[secrets]" "[watch]"
mut "secrets with wildcard verbs" "[secrets]" "['*']"
mut "a ClusterRole with pods/exec" "[pods/exec]" "[create]" ClusterRole
mut "the old gha-deployer shape (pods + pods/exec + secrets get,list)" "[pods, pods/exec, secrets]" "[get, list, create]"
python3 -I "$C" m <<<"$(role '[secrets]' '[create, update, patch]')" >/dev/null 2>&1 && ok "secrets create/update/patch (write-only) is allowed" || fail "write-only secrets rule was refused"
python3 -I "$C" m <<<"$(role '[secrets]' '[get, patch, update]' | sed 's/^    verbs:/    resourceNames: [one]\n    verbs:/')" >/dev/null 2>&1 && ok "a named single-Secret get is allowed" || fail "a resourceNames-limited rule was refused"
# an UNPARSEABLE file that declares a Role must FAIL (no silent skip), a template placeholder line is tolerated
printf 'kind: Role\nrules:\n  - resources: [pods/exec]\n   bad: [\n' > "$T/broken.yaml"
python3 -I "$C" m "$T/broken.yaml" >/dev/null 2>&1 && fail "MUTANT unparseable file declaring a Role passed" || ok "MUTANT: an unparseable file that declares a Role FAILS (no silent skip)"
printf 'apiVersion: rbac.authorization.k8s.io/v1\nkind: Role\nmetadata:\n  name: p@PARTY@\n  @CLUSTER_LABEL@\nrules:\n  - apiGroups: [""]\n    resources: [pods/exec]\n    verbs: [create]\n' > "$T/tpl.yaml.tpl"
python3 -I "$C" m "$T/tpl.yaml.tpl" >/dev/null 2>&1 && fail "MUTANT templated Role with pods/exec passed" || ok "MUTANT: a templated Role (@PLACEHOLDER@ lines) with pods/exec FAILS"
# a List input (live use: kubectl get role -A -o json) and a JSON input
python3 -I "$C" m <<<"{\"kind\":\"List\",\"items\":[{\"kind\":\"Role\",\"metadata\":{\"name\":\"j\"},\"rules\":[{\"apiGroups\":[\"\"],\"resources\":[\"pods/exec\"],\"verbs\":[\"create\"]}]}]}" >/dev/null 2>&1 && fail "MUTANT JSON List with pods/exec passed" || ok "MUTANT: a kubectl-style JSON List with pods/exec FAILS"
# (3) the auditor client-key render (R13 Role: named single-Secret rule)
D=sha256:$(printf 'a%.0s' $(seq 1 64)); TI=docker.io/alpine/k8s@sha256:$(printf 'b%.0s' $(seq 1 64))
out=$(deploy/auditor-sign/render.sh keygen bi "$TI" "$D" --apiserver 172.24.11.240/32:6443 2>&1) && python3 -I "$C" auditor-keygen <<<"$out" || fail "the auditor keygen render was refused: $out"
nn=$(python3 -I -c '
import sys, yaml
docs = [d for d in yaml.safe_load_all(sys.stdin.read()) if d]
for d in docs:
    if d["kind"] == "Role": d["rules"][0].pop("resourceNames")
print(yaml.safe_dump_all(docs))' <<<"$out")
python3 -I "$C" m <<<"$nn" >/dev/null 2>&1 && fail "MUTANT keygen Role without resourceNames passed" || ok "MUTANT: the keygen Role without resourceNames FAILS"
if (( fails )); then echo "FAILED: $fails check(s)" >&2; exit 1; fi
echo "PASS"
