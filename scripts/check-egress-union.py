#!/usr/bin/env python3
"""Union check (R17): for every role given, the Egress-typed NetworkPolicies that SELECT a pod of that role must be EXACTLY the one named policy (the effective egress of a pod is
the UNION of all policies selecting it, so an extra or wildcard policy silently widens it). Input on stdin: rendered YAML/JSON NetworkPolicy documents of one namespace, or a
`kubectl get netpol -o json` List (live use, cluster-admin read-only). Usage: check-egress-union.py <label> <role>=<policy> [<role>=<policy> ...]
A policy selects a role pod when every matchLabels pair of its podSelector is in the pod's labels {rd-iroha3/role: <role>, + the party/part-of labels} and it has no
matchExpressions (an empty podSelector {} selects every pod)."""
import json
import sys

import yaml

label = sys.argv[1]
want = dict(a.split("=", 1) for a in sys.argv[2:])
raw = sys.stdin.read()
docs = []
for d in yaml.safe_load_all(raw):
    if not d:
        continue
    docs += d["items"] if d.get("kind") == "List" else [d]
pols = [d for d in docs if d.get("kind") == "NetworkPolicy"]
bad = []
for role, name in want.items():
    pod = {"rd-iroha3/role": role, "app.kubernetes.io/part-of": "rd-iroha3"}
    if role in ("pool-init", "lensa-sign", "egress-probe"):  # key-mounting / locked pods carry the rd/egress-locked label their own policy selects
        pod["rd/egress-locked"] = "true"
    sel = []
    for p in pols:
        spec = p["spec"]
        if "Egress" not in (spec.get("policyTypes") or []):
            continue
        ps = spec.get("podSelector", {})
        if ps.get("matchExpressions") or not all(pod.get(k) == v for k, v in (ps.get("matchLabels") or {}).items()):
            continue
        sel.append(p["metadata"]["name"])
    if sel != [name]:
        bad.append(f"role {role}: Egress policies selecting it = {sel or 'NONE'}, want exactly ['{name}']")
if bad:
    print("\n".join(f"FAIL: egress-union {label}: {b}" for b in bad), file=sys.stderr)
    sys.exit(1)
print(f"ok:   egress-union {label}: " + ", ".join(f"{r}->{n}" for r, n in want.items()))
