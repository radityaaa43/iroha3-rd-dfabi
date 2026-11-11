#!/usr/bin/env python3
"""Check the rendered egress-probe manifests on stdin. Usage: check-egressprobe.py <party> <digest> [driver]   (driver = the --role driver positive-control Pod only)"""
import json
import sys

import yaml

party, digest = sys.argv[1:3]
drole = len(sys.argv) > 3 and sys.argv[3] == "driver"
pname = "egress-probe-driver" if drole else "egress-probe"
ns = f"rd-iroha3-{party}"
docs = [d for d in yaml.safe_load_all(sys.stdin.read()) if d]
by = {(d["kind"], d["metadata"]["name"]): d for d in docs}
bad = []
want = {("Pod", pname)} if drole else {("Pod", "egress-probe"), ("NetworkPolicy", "egress-probe-egress")}
if set(by) != want or len(docs) != len(want):
    bad.append(f"objects: want exactly {sorted(want)}, got {sorted(by)}")
for (k, n), d in by.items():
    if d["metadata"].get("namespace") != ns:
        bad.append(f"{k} {n} in namespace {d['metadata'].get('namespace')}, want {ns}")
flat = json.dumps(docs)
for banned in ("PRIVATE KEY", "secretName", "secretKeyRef", "nodeName", "hostNetwork", "serviceAccountName", "ipBlock"):
    if banned in flat:
        bad.append(f"rendered objects must not contain {banned!r}")
pod = by.get(("Pod", pname))
if pod:
    lab, s = pod["metadata"]["labels"], pod["spec"]
    c = s["containers"][0]
    checks = {
        "labels": (lab.get("rd-iroha3/role") == "driver" and "rd/egress-locked" not in lab and lab.get("rd-iroha3/party") == party) if drole else
                  (lab.get("rd-iroha3/role") == "egress-probe" and lab.get("rd/egress-locked") == "true" and lab.get("rd-iroha3/party") == party),
        "digest-pinned driver image": c["image"] == f"ghcr.io/radityaaa43/iroha3-rd-driver@{digest}",
        "imagePullSecrets ghcr-pull": s.get("imagePullSecrets") == [{"name": "ghcr-pull"}],
        "imagePullPolicy Always": c.get("imagePullPolicy") == "Always",
        "no SA token": s.get("automountServiceAccountToken") is False,
        "no volumes except emptyDir": all("emptyDir" in v for v in s.get("volumes", [])),
        "non-root + seccomp": s["securityContext"].get("runAsNonRoot") is True and s["securityContext"].get("seccompProfile") == {"type": "RuntimeDefault"},
        "container hardening": c["securityContext"].get("allowPrivilegeEscalation") is False and c["securityContext"].get("readOnlyRootFilesystem") is True
        and c["securityContext"].get("capabilities", {}).get("drop") == ["ALL"],
        "restartPolicy Never": s.get("restartPolicy") == "Never",
        "bounded resources": "requests" in c["resources"] and "limits" in c["resources"],
        "command is a bash loop": c["command"][:2] == ["bash", "-c"],
    }
    for name, good in checks.items():
        if not good:
            bad.append(f"Pod egress-probe: {name}")
    script = c["command"][2]
    for banned in ("seed", "private_key", "Authorization", "balance", "/v1/accounts"):  # the status read prints counts only
        if banned in script:
            bad.append(f"probe loop must read only /status counts, found {banned!r}")
    for need in ("1.1.1.1", "8.8.8.8", "KUBERNETES_SERVICE_HOST", "ghcr.io", "sleep 15", f"{party}-0.{party}.rd-iroha3-{party}.svc.cluster.local",
                 "GET /status HTTP/1.0", "(peers|blocks|view_changes)", "Accept: application/json", "http=", "ctype=", "bytes=", "# PARSE-BEGIN", "# PARSE-END"):
        if need not in script:
            bad.append(f"probe loop lacks {need!r}")
np = by.get(("NetworkPolicy", "egress-probe-egress"))
if np and not drole:
    sp = np["spec"]
    c1 = ("bi", "bank-a", "bank-b")
    gw_ns = c1 if party in c1 else ("bank-c",)
    want_eg = [
        {"to": [{"namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": "kube-system"}}, "podSelector": {"matchLabels": {"k8s-app": "kube-dns"}}}],
         "ports": [{"protocol": "UDP", "port": 53}, {"protocol": "TCP", "port": 53}]},
        {"to": [{"podSelector": {"matchLabels": {"rd-iroha3/role": "peer", "rd-iroha3/party": party}}}], "ports": [{"protocol": "TCP", "port": 8080}]},
        {"to": [{"namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": f"rd-iroha3-{q}"}}, "podSelector": {"matchLabels": {"rd-iroha3/role": "gateway"}}} for q in gw_ns],
         "ports": [{"protocol": "TCP", "port": 8443}]},
    ]
    if sp.get("podSelector") != {"matchLabels": {"rd-iroha3/role": "egress-probe", "rd/egress-locked": "true"}} or sp.get("policyTypes") != ["Egress"] or "ingress" in sp:
        bad.append(f"NetworkPolicy egress-probe-egress: selector role=egress-probe + label, Egress only: {sp.get('podSelector')} {sp.get('policyTypes')}")
    if sp.get("egress") != want_eg:
        bad.append(f"NetworkPolicy egress-probe-egress rules: {json.dumps(sp.get('egress'))}")
if bad:
    print("\n".join(f"FAIL: egress-probe {party}: {b}" for b in bad), file=sys.stderr)
    sys.exit(1)
print(f"ok:   egress-probe {party}: {len(docs)} objects match")
