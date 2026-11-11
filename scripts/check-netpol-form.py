#!/usr/bin/env python3
"""Policy-FORM check of every NetworkPolicy on stdin (lead/orchestrator ruling 2026-11-12, all tracks). Usage: check-netpol-form.py <label>
Asserts, over every `from` / `to` element of every rule:
 (1) no EMPTY selector ({} podSelector or namespaceSelector: it would match every pod / every namespace);
 (2) every namespaceSelector pins an exact kubernetes.io/metadata.name (matchLabels, or a single matchExpressions `In` on that key);
 (3) no ipBlock that can mean something IN the cluster: a private/cluster range (10/8, 172.16/12, 192.168/16, 169.254/16, 127/8) is refused; only a public /32
     (the OTHER cluster's LB address) and the CLB health range 100.64.0.0/10 are accepted (this CNI does not match ipBlock after DNAT, so an in-cluster ipBlock
     would silently stay closed).
A `podSelector` with non-empty matchLabels and NO namespaceSelector means the policy's OWN namespace: fine. Exempt (temporary, named): torii-bootstrap (podSelector {}), deleted at S14.G."""
import ipaddress
import sys

import yaml

label = sys.argv[1]
exempt = {"torii-bootstrap"}
NS_KEY = "kubernetes.io/metadata.name"
PRIVATE = [ipaddress.ip_network(n) for n in ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "169.254.0.0/16", "127.0.0.0/8")]
HEALTH = ipaddress.ip_network("100.64.0.0/10")


def peer_violations(where, el):
    out = []
    if "podSelector" in el and el["podSelector"] == {}:
        out.append(f"{where}: empty podSelector {{}} (matches every pod)")
    if "namespaceSelector" in el:
        ns = el["namespaceSelector"]
        ml = ns.get("matchLabels") or {}
        me = ns.get("matchExpressions") or []
        exact = (list(ml) == [NS_KEY] and isinstance(ml[NS_KEY], str) and ml[NS_KEY] != "" and not me) or (
            not ml and len(me) == 1 and me[0].get("key") == NS_KEY and me[0].get("operator") == "In" and bool(me[0].get("values")))
        if not exact:
            out.append(f"{where}: namespaceSelector must pin an exact {NS_KEY} (got {ns})")
    if "ipBlock" in el:
        cidr = ipaddress.ip_network(el["ipBlock"]["cidr"], strict=False)
        if any(cidr.version == p.version and cidr.overlaps(p) for p in PRIVATE):
            out.append(f"{where}: ipBlock {cidr} is a private/in-cluster range (use ns+pod selectors)")
        elif cidr != HEALTH and cidr.prefixlen != 32:
            out.append(f"{where}: ipBlock {cidr} is neither a public /32 nor the CLB health range 100.64.0.0/10")
    return out


bad = []
n = 0
for d in yaml.safe_load_all(sys.stdin.read()):
    if not d or d.get("kind") != "NetworkPolicy" or d["metadata"]["name"] in exempt:
        continue
    n += 1
    for direction, key in (("ingress", "from"), ("egress", "to")):
        for ri, rule in enumerate(d["spec"].get(direction) or []):
            for ei, el in enumerate(rule.get(key) or []):
                bad += peer_violations(f"{d['metadata']['name']}: {direction}[{ri}].{key}[{ei}]", el)
if bad:
    print("\n".join(f"FAIL: netpol-form {label}: {b}" for b in bad), file=sys.stderr)
    sys.exit(1)
print(f"ok:   netpol-form {label}: {n} NetworkPolicies follow the form")
