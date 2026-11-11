#!/usr/bin/env python3
"""Check a rendered p2p LoadBalancer Service on stdin. Usage: check-p2p.py <party>"""
import sys

import yaml

party = sys.argv[1]
want_ranges = sys.argv[2:]
ns = f"rd-iroha3-{party}"
docs = [d for d in yaml.safe_load_all(sys.stdin.read()) if d]
bad = []
if len(docs) != 1:
    bad.append(f"want exactly 1 object, got {len(docs)}")
else:
    d = docs[0]
    s = d.get("spec", {})
    if d.get("kind") != "Service" or d["metadata"].get("name") != "p2p" or d["metadata"].get("namespace") != ns:
        bad.append(f"want Service p2p in {ns}: {d['kind']} {d['metadata']}")
    if s.get("type") != "LoadBalancer":
        bad.append(f"type must be LoadBalancer: {s.get('type')}")
    if s.get("ports") != [{"name": "p2p", "port": 1337, "targetPort": "p2p", "protocol": "TCP"}]:
        bad.append(f"exactly TCP 1337 -> p2p (never Torii 8080): {s.get('ports')}")
    if s.get("selector") != {"app.kubernetes.io/part-of": "rd-iroha3", "rd-iroha3/party": party, "rd-iroha3/role": "peer"}:
        bad.append(f"selector must pin the own party's peer pod: {s.get('selector')}")
    if s.get("loadBalancerSourceRanges") != want_ranges or not want_ranges or any(not r.endswith("/32") for r in want_ranges):
        bad.append(f"loadBalancerSourceRanges must be exactly the given /32 list {want_ranges}: {s.get('loadBalancerSourceRanges')}")
    if s.get("externalTrafficPolicy") != "Local":
        bad.append("externalTrafficPolicy must be Local (keeps the client source IP for the peers-p2p ipBlock)")
    if "clusterIP" in s and s["clusterIP"] == "None":
        bad.append("a LoadBalancer Service cannot be headless")
    if d["metadata"].get("labels", {}).get("app.kubernetes.io/part-of") != "rd-iroha3":
        bad.append("label part-of=rd-iroha3 missing")
for b in bad:
    print(f"FAIL: {party}: {b}", file=sys.stderr)
print(f"{'FAIL' if bad else 'ok:  '} {party}: p2p Service")
sys.exit(1 if bad else 0)
