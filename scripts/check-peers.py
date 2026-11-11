#!/usr/bin/env python3
"""Check rendered peer manifests on stdin. Usage: check-peers.py <party> <hash8> <bankc-cidr>"""
import sys

import yaml

party, h8, cidr = sys.argv[1:4]
flags = sys.argv[4:]
clb = "clb" in flags  # --clb-health-cidr 100.64.0.0/10 requested
c2 = "c2" in flags  # --cluster 2 (bank-c): no PriorityClass, no cluster-1 node exclusion, StorageClass fabricx-essd (WaitForFirstConsumer)
ns = f"rd-iroha3-{party}"
docs = [d for d in yaml.safe_load_all(sys.stdin.read()) if d]
by = {(d["kind"], d["metadata"]["name"]): d for d in docs}
bad = []


def need(kind, name):
    if (kind, name) not in by:
        bad.append(f"missing {kind} {name}")
    return by.get((kind, name))


sts = need("StatefulSet", party)
if sts:
    s = sts["spec"]
    pod = s["template"]["spec"]
    c = pod["containers"][0]
    checks = {
        "serviceName": s["serviceName"] == party,
        "replicas 1": s["replicas"] == 1,
        "OnDelete": s["updateStrategy"]["type"] == "OnDelete",
        "image": c["image"] == "ghcr.io/radityaaa43/iroha3-rd-node:071e281e-stark",
        "init image": pod["initContainers"][0]["image"] == c["image"],
        "imagePullSecrets ghcr-pull": pod.get("imagePullSecrets") == [{"name": "ghcr-pull"}],
        "priorityClassName": ("priorityClassName" not in pod) if c2 else pod["priorityClassName"] == "rd-iroha3-peer",
        "args": c["args"] == ["--sora", "--config", "/config/peer.toml"],
        "startup /livez": c["startupProbe"]["httpGet"]["path"] == "/livez",
        "liveness /livez": c["livenessProbe"]["httpGet"]["path"] == "/livez",
        "readiness /readyz": c["readinessProbe"]["httpGet"]["path"] == "/readyz",
        "requests": c["resources"]["requests"] == {"cpu": "250m", "memory": "512Mi" if c2 else "1Gi"},
        "limits": c["resources"]["limits"] == {"cpu": "2000m", "memory": "3Gi"},
        "peer secret": any(v.get("secret", {}).get("secretName") == f"peer-{party}" for v in pod["volumes"]),
        "genesis configmap": any(v.get("configMap", {}).get("name") == f"genesis-{h8}" for v in pod["volumes"]),
        "pvc 5Gi essd": s["volumeClaimTemplates"][0]["spec"]["storageClassName"] == ("fabricx-essd" if c2 else "alicloud-essd-wffc")
        and s["volumeClaimTemplates"][0]["spec"]["resources"]["requests"]["storage"] == "5Gi",
        "init resources": all(k in pod["initContainers"][0].get("resources", {}) for k in ("requests", "limits")),
        "excluded nodes": ("nodeAffinity" not in pod.get("affinity", {})) if c2 else any(
            e.get("key") == "kubernetes.io/hostname" and e.get("operator") == "NotIn"
            and sorted(e.get("values", [])) == ["member-16033-node", "member-16034-node"]
            for t in pod.get("affinity", {}).get("nodeAffinity", {}).get("requiredDuringSchedulingIgnoredDuringExecution", {}).get("nodeSelectorTerms", [])
            for e in t.get("matchExpressions", [])),
        "soft anti-affinity across rd-iroha3 namespaces": any(
            t.get("podAffinityTerm", {}).get("topologyKey") == "kubernetes.io/hostname"
            and t["podAffinityTerm"].get("labelSelector", {}).get("matchLabels") == {"app.kubernetes.io/part-of": "rd-iroha3", "rd-iroha3/role": "peer"}
            and t["podAffinityTerm"].get("namespaceSelector", {}).get("matchLabels") == {"app.kubernetes.io/part-of": "rd-iroha3"}
            for t in pod.get("affinity", {}).get("podAntiAffinity", {}).get("preferredDuringSchedulingIgnoredDuringExecution", [])),
        "no token": pod["automountServiceAccountToken"] is False,
        "role label": s["template"]["metadata"]["labels"].get("rd-iroha3/role") == "peer"
        and s["template"]["metadata"]["labels"].get("rd-iroha3/party") == party,
    }
    for name, good in checks.items():
        if not good:
            bad.append(f"StatefulSet {party}: {name}")
svc = need("Service", party)
if svc:
    p = {x["name"]: x["port"] for x in svc["spec"]["ports"]}
    if svc["spec"].get("clusterIP") != "None" or not svc["spec"].get("publishNotReadyAddresses") or p != {"p2p": 1337, "api": 8080}:
        bad.append(f"Service {party}: headless, publishNotReadyAddresses, ports p2p 1337 + api 8080 expected: {svc['spec']}")
p2p = need("NetworkPolicy", "peers-p2p")
if p2p:
    ing = p2p["spec"]["ingress"]
    ports_ok = all(r["ports"] == [{"protocol": "TCP", "port": 1337}] for r in ing) and len(ing) == 1
    frm = ing[0]["from"] if ing else []
    ns_rule = [f for f in frm if "namespaceSelector" in f]
    ip_rule = [f for f in frm if "ipBlock" in f]
    want_ips = [cidr] + (["100.64.0.0/10"] if clb else [])
    if not (ports_ok and len(frm) == 1 + len(want_ips) and len(ns_rule) == 1
            and [r["ipBlock"]["cidr"] for r in ip_rule] == want_ips
            and ns_rule[0]["namespaceSelector"]["matchLabels"] == {"app.kubernetes.io/part-of": "rd-iroha3"}
            and ns_rule[0]["podSelector"]["matchLabels"] == {"rd-iroha3/role": "peer"}):
        bad.append(f"peers-p2p must allow TCP 1337 from peer pods of rd-iroha3 namespaces and from {want_ips} only: {ing}")
    if p2p["spec"]["policyTypes"] != ["Ingress"]:
        bad.append("peers-p2p policyTypes")
tor = need("NetworkPolicy", "peers-torii")
if tor:
    ing = tor["spec"]["ingress"]
    # ANALYST Q4(d): the gateway pods of the own namespace, and the peer pods of exactly the namespaces of the same cluster (the
    # peers poll each other's Torii for telemetry, network/s5.py:361): namespace NAMES plus the pod label, never a wide selector.
    cluster_ns = ["rd-iroha3-bank-a", "rd-iroha3-bank-b", "rd-iroha3-bi"]
    # The party's OWN clients (driver, auditor, pool-init Job) reach its own Torii inside ONE namespace: they lost that path when
    # torii-bootstrap goes (S14). Not another party: principle 6 is untouched.
    want_from = [{"podSelector": {"matchLabels": {"rd-iroha3/role": "gateway"}}},
                 {"podSelector": {"matchExpressions": [{"key": "rd-iroha3/role", "operator": "In", "values": ["auditor", "driver", "pool-init"]}]}}]
    if not c2:  # bank-c (cluster 2) has no same-cluster peer to poll: gateway pods only
        want_from.append({"namespaceSelector": {"matchExpressions": [{"key": "kubernetes.io/metadata.name", "operator": "In", "values": cluster_ns}]},
                          "podSelector": {"matchLabels": {"rd-iroha3/role": "peer"}}})
    if not (len(ing) == 1 and ing[0]["ports"] == [{"protocol": "TCP", "port": 8080}] and ing[0]["from"] == want_from):
        bad.append(f"peers-torii must allow TCP 8080 from the own gateway pods{"" if c2 else f" and from the peer pods of exactly {cluster_ns}"}: {ing}")
boot = need("NetworkPolicy", "torii-bootstrap")
if boot:
    ing = boot["spec"]["ingress"]
    if not (len(ing) == 1 and ing[0]["ports"] == [{"protocol": "TCP", "port": 8080}] and ing[0]["from"] == [{"podSelector": {}}]):
        bad.append(f"torii-bootstrap must allow TCP 8080 from any pod of the own namespace: {ing}")
    if boot["metadata"].get("labels", {}).get("rd-iroha3/temporary") != "true" or "S14" not in boot["metadata"].get("annotations", {}).get("rd-iroha3/delete-at", ""):
        bad.append("torii-bootstrap must carry label rd-iroha3/temporary=true and annotation rd-iroha3/delete-at naming S14")
for (k, name), d in by.items():
    if d["metadata"].get("namespace") != ns:
        bad.append(f"{k} {name} is in namespace {d['metadata'].get('namespace')}, want {ns}")
if len(docs) != 5:
    bad.append(f"want exactly 5 objects (StatefulSet, Service, 3 NetworkPolicies), got {len(docs)}")
for b in bad:
    print(f"FAIL: {party}: {b}", file=sys.stderr)
print(f"{'FAIL' if bad else 'ok:  '} {party}: {len(docs)} objects")
sys.exit(1 if bad else 0)
