#!/usr/bin/env python3
"""Check the rendered pull-test manifests on stdin. Usage: check-pulltest.py <party> <driver sha256:digest> <envoy repo@sha256:digest> <tools repo@sha256:digest>
Pod pull-test (one container per image, each `exit 0`) + NetworkPolicy pull-test-egress (deny-all, selected by role=pull-test + rd/egress-locked). The kubelet pulls the images; the pod needs no network."""
import json
import sys

import yaml

party, drv, envoy, tools = sys.argv[1:5]
ns = f"rd-iroha3-{party}"
docs = [d for d in yaml.safe_load_all(sys.stdin.read()) if d]
by = {(d["kind"], d["metadata"]["name"]): d for d in docs}
bad = []
want = {("Pod", "pull-test"), ("NetworkPolicy", "pull-test-egress")}
if set(by) != want or len(docs) != 2:
    bad.append(f"objects: want exactly {sorted(want)}, got {sorted(by)}")
for (k, n), d in by.items():
    if d["metadata"].get("namespace") != ns:
        bad.append(f"{k} {n} in namespace {d['metadata'].get('namespace')}, want {ns}")
flat = json.dumps(docs)
for banned in ("PRIVATE KEY", "nodeName", "hostNetwork", "secretName", "secretKeyRef", "serviceAccountName", "hostPath", "ipBlock", "persistentVolumeClaim", "\"env\"", "envFrom"):
    if banned in flat:
        bad.append(f"rendered objects must not contain {banned!r}")
pod = by.get(("Pod", "pull-test"))
if pod:
    lab, s = pod["metadata"]["labels"], pod["spec"]
    images = [f"ghcr.io/radityaaa43/iroha3-rd-driver@{drv}", envoy, tools]
    cs = s["containers"]
    checks = {
        "labels role=pull-test + rd/egress-locked=true + part-of + party": lab == {"app.kubernetes.io/part-of": "rd-iroha3", "rd-iroha3/party": party, "rd-iroha3/role": "pull-test", "rd/egress-locked": "true"},
        "exactly the 3 images, by digest, in order": [c["image"] for c in cs] == images and all("@sha256:" in c["image"] for c in cs),
        "imagePullPolicy Always on every container": all(c.get("imagePullPolicy") == "Always" for c in cs),
        "every container only exits 0": all(c.get("command") == ["/bin/sh", "-c", "exit 0"] for c in cs),
        "imagePullSecrets ghcr-pull": s.get("imagePullSecrets") == [{"name": "ghcr-pull"}],
        "restartPolicy Never": s.get("restartPolicy") == "Never",
        "bounded activeDeadlineSeconds": isinstance(s.get("activeDeadlineSeconds"), int) and 0 < s["activeDeadlineSeconds"] <= 900,
        "no SA token": s.get("automountServiceAccountToken") is False,
        "no volumes, no ports": not s.get("volumes") and all(not c.get("ports") and not c.get("volumeMounts") for c in cs),
        "non-root + seccomp": s["securityContext"].get("runAsNonRoot") is True and s["securityContext"].get("seccompProfile") == {"type": "RuntimeDefault"},
        "container hardening + resources": all(c["securityContext"].get("allowPrivilegeEscalation") is False and c["securityContext"].get("readOnlyRootFilesystem") is True
                                               and c["securityContext"].get("capabilities", {}).get("drop") == ["ALL"] and "requests" in c["resources"] and "limits" in c["resources"] for c in cs),
        "container names": [c["name"] for c in cs] == ["driver", "envoy", "tools"],
    }
    for name, good in checks.items():
        if not good:
            bad.append(f"Pod pull-test: {name}")
np = by.get(("NetworkPolicy", "pull-test-egress"))
if np:
    sp = np["spec"]
    if sp.get("podSelector") != {"matchLabels": {"rd-iroha3/role": "pull-test", "rd/egress-locked": "true"}} or sp.get("policyTypes") != ["Egress"] or sp.get("egress") != [] or "ingress" in sp:
        bad.append(f"NetworkPolicy pull-test-egress must be Egress-only DENY-ALL (egress: []) for role=pull-test + rd/egress-locked: {sp}")
if bad:
    print("\n".join(f"FAIL: pull-test {party}: {b}" for b in bad), file=sys.stderr)
    sys.exit(1)
print(f"ok:   pull-test {party}: {len(docs)} objects match")
