#!/usr/bin/env bash
# Offline test of scripts/check-netpol-form.py: each of the three form rules FAILS on a mutant, good policies pass. The renders are checked by their own test
# scripts (each pipes its rendered output through the form checker).
set -uo pipefail
cd "$(dirname "$0")/.."
C=scripts/check-netpol-form.py
fails=0
fail() { echo "FAIL: $*" >&2; fails=$((fails + 1)); }
ok() { echo "ok:   $*"; }
mk() { # <name> <to-element json>
  printf '{"apiVersion":"networking.k8s.io/v1","kind":"NetworkPolicy","metadata":{"name":"%s"},"spec":{"podSelector":{"matchLabels":{"a":"b"}},"policyTypes":["Egress"],"egress":[{"to":[%s]}]}}' "$1" "$2"
}
run() { python3 -I "$C" t <<<"$(mk m "$1")" >/dev/null 2>&1; }
GOOD='{"namespaceSelector":{"matchLabels":{"kubernetes.io/metadata.name":"rd-iroha3-bi"}},"podSelector":{"matchLabels":{"rd-iroha3/role":"gateway"}}}'
run "$GOOD" && ok "ns+pod selectors with an exact namespace pass" || fail "good policy rejected"
run '{"podSelector":{"matchLabels":{"rd-iroha3/role":"peer"}}}' && ok "podSelector with labels and no namespaceSelector (own namespace) passes" || fail "own-namespace pod target rejected"
run '{"ipBlock":{"cidr":"203.0.113.10/32"}}' && ok "a public /32 (other cluster LB) passes" || fail "public /32 rejected"
run '{"ipBlock":{"cidr":"100.64.0.0/10"}}' && ok "the CLB health range passes" || fail "100.64.0.0/10 rejected"
run '{"podSelector":{}}' && fail "MUTANT empty podSelector passed" || ok "MUTANT: empty podSelector {} FAILS"
run '{"namespaceSelector":{},"podSelector":{"matchLabels":{"a":"b"}}}' && fail "MUTANT empty namespaceSelector passed" || ok "MUTANT: empty namespaceSelector {} FAILS"
run '{"namespaceSelector":{"matchLabels":{"team":"x"}},"podSelector":{"matchLabels":{"a":"b"}}}' && fail "MUTANT namespaceSelector without metadata.name passed" || ok "MUTANT: namespaceSelector without kubernetes.io/metadata.name FAILS"
run '{"ipBlock":{"cidr":"10.200.0.0/16"}}' && fail "MUTANT in-cluster ipBlock passed" || ok "MUTANT: ipBlock 10.200.0.0/16 (in-cluster) FAILS"
run '{"ipBlock":{"cidr":"172.24.0.0/16"}}' && fail "MUTANT pod-CIDR ipBlock passed" || ok "MUTANT: ipBlock 172.24.0.0/16 (pod range) FAILS"
run '{"ipBlock":{"cidr":"8.8.8.0/24"}}' && fail "MUTANT public /24 passed" || ok "MUTANT: a public /24 FAILS (only /32 or 100.64.0.0/10)"
if (( fails )); then echo "FAILED: $fails check(s)" >&2; exit 1; fi
echo "PASS"
