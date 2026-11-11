#!/usr/bin/env python3
"""Check rendered namespace manifests on stdin. Usage: check-ns.py <party> | check-ns.py priorityclass"""
import sys

import yaml

what = sys.argv[1]
nsonly = len(sys.argv) > 2 and sys.argv[2] == "ns-only"
docs = [d for d in yaml.safe_load_all(sys.stdin.read()) if d]
bad = []

if what == "priorityclass":
    d = docs[0] if len(docs) == 1 else {}
    if not (d.get("kind") == "PriorityClass" and d["metadata"]["name"] == "rd-iroha3-peer"
            and d.get("value") == 10000 and not d.get("globalDefault", False)):
        bad.append(f"want one PriorityClass rd-iroha3-peer value 10000, not default: {d}")
else:
    ns = f"rd-iroha3-{what}"
    by = {(d["kind"], d["metadata"]["name"]): d for d in docs}

    def need(kind, name):
        if (kind, name) not in by:
            bad.append(f"missing {kind} {name}")
        return by.get((kind, name))

    n = need("Namespace", ns)
    if n:
        lab = n["metadata"].get("labels", {})
        if lab.get("app.kubernetes.io/part-of") != "rd-iroha3" or lab.get("rd-iroha3/party") != what:
            bad.append(f"namespace labels wrong: {lab}")
        # cluster 2 (bank-c) carries `cluster: "2"` (fabricx parity); the live cluster-1 namespaces have no such label
        want_cluster = "2" if what == "bank-c" else None
        if lab.get("cluster") != want_cluster:
            bad.append(f"namespace label cluster is {lab.get('cluster')!r}, want {want_cluster!r}")
    np_ = need("NetworkPolicy", "default-deny-ingress")
    if np_:
        s = np_["spec"]
        if s.get("podSelector") != {} or s.get("policyTypes") != ["Ingress"] or s.get("ingress"):
            bad.append(f"default-deny-ingress needs an empty podSelector, policyTypes [Ingress], no rules: {s}")
    if nsonly:
        if len(docs) != 1 or docs[0]["kind"] != "Namespace":
            bad.append(f"--ns-only must emit exactly the Namespace doc, got {[d['kind'] for d in docs]}")
        for b in bad:
            print(f"FAIL: {what}: {b}", file=sys.stderr)
        print(f"{'FAIL' if bad else 'ok:  '} {what} --ns-only: {len(docs)} object")
        sys.exit(1 if bad else 0)
    need("ServiceAccount", "party-admin")
    role = need("Role", "party-admin")
    if role:
        sec = [r for r in role["rules"] if "secrets" in r.get("resources", [])]
        if len(sec) != 1 or sorted(sec[0]["verbs"]) != ["create", "patch", "update"] or sec[0]["apiGroups"] != [""]:
            bad.append(f"secrets verbs must be exactly create,update,patch in the core group: {sec}")
        # every rule has ONE api group, and each resource sits in its real group
        group_of = {"statefulsets": "apps", "deployments": "apps", "networkpolicies": "networking.k8s.io"}
        got = set()
        for r in role["rules"]:
            if len(r.get("apiGroups", [])) != 1:
                bad.append(f"rule must name exactly one apiGroup: {r}")
                continue
            for res in r["resources"]:
                got.add(res)
                if res in ("pods/exec", "jobs", "*"):
                    bad.append(f"role grants {res}")
                want_group = group_of.get(res, "")
                if r["apiGroups"][0] != want_group:
                    bad.append(f"{res} is in api group {r['apiGroups'][0]!r}, want {want_group!r}")
        logs = [r for r in role["rules"] if "pods/log" in r.get("resources", [])]
        if len(logs) != 1 or sorted(logs[0]["verbs"]) != ["get", "list", "watch"] or logs[0]["resources"] != ["pods/log"]:
            bad.append(f"pods/log needs its own rule with get,list,watch only: {logs}")
        for want in ("statefulsets", "deployments", "services", "configmaps", "persistentvolumeclaims",
                     "networkpolicies", "pods", "pods/log"):
            if want not in got:
                bad.append(f"role lacks {want}")
    rb = need("RoleBinding", "party-admin")
    if rb:
        sub = rb["subjects"][0]
        if (sub["kind"], sub["name"], sub.get("namespace")) != ("ServiceAccount", "party-admin", ns) \
                or rb["roleRef"]["name"] != "party-admin":
            bad.append(f"rolebinding wrong: {rb}")
    for (k, name), d in by.items():
        if k != "Namespace" and d["metadata"].get("namespace") != ns:
            bad.append(f"{k} {name} is in namespace {d['metadata'].get('namespace')}, want {ns}")
    if len(docs) != 5:
        bad.append(f"want exactly 5 objects (Namespace, NetworkPolicy, ServiceAccount, Role, RoleBinding), got {len(docs)}")

for b in bad:
    print(f"FAIL: {what}: {b}", file=sys.stderr)
print(f"{'FAIL' if bad else 'ok:  '} {what}: {len(docs)} objects")
sys.exit(1 if bad else 0)
