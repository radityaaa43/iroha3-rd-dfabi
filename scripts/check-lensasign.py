#!/usr/bin/env python3
"""Check the rendered lensa-sign manifests on stdin. Usage: check-lensasign.py <party> <digest> <csr-file>"""
import json
import sys

import yaml

party, digest, csr_file = sys.argv[1:4]
ns = f"rd-iroha3-{party}"
csr = open(csr_file).read()
docs = [d for d in yaml.safe_load_all(sys.stdin.read()) if d]
by = {(d["kind"], d["metadata"]["name"]): d for d in docs}
bad = []
want = {("ConfigMap", "lensa-csr"), ("Job", "lensa-sign"), ("NetworkPolicy", "lensa-sign-egress")}
if set(by) != want or len(docs) != 3:
    bad.append(f"objects: want exactly {sorted(want)}, got {sorted(by)}")
for (k, n), d in by.items():
    if d["metadata"].get("namespace") != ns:
        bad.append(f"{k} {n} in namespace {d['metadata'].get('namespace')}, want {ns}")
flat = json.dumps(docs)
for banned in ("PRIVATE KEY", "nodeName", "hostNetwork", "serviceAccountName", "ipBlock", "bi-gov", "auditor-key", "iroha3-role-ca", "iroha3-server-ca", "gateway-server"):
    if banned in flat:
        bad.append(f"rendered objects must not contain {banned!r}")
cm = by.get(("ConfigMap", "lensa-csr"))
if cm and (list(cm["data"]) != ["lensa.csr"] or cm["data"]["lensa.csr"].strip() != csr.strip() or "REQUEST" not in cm["data"]["lensa.csr"]):
    bad.append("ConfigMap lensa-csr must hold exactly the given PUBLIC CSR under lensa.csr")
job = by.get(("Job", "lensa-sign"))
if job:
    s = job["spec"]; pod = s["template"]["spec"]; c = pod["containers"][0]
    lab = s["template"]["metadata"]["labels"]
    checks = {
        "labels role=lensa-sign + rd/egress-locked=true": lab.get("rd-iroha3/role") == "lensa-sign" and lab.get("rd/egress-locked") == "true" and lab.get("rd-iroha3/party") == party,
        "backoffLimit 0": s.get("backoffLimit") == 0,
        "bounded activeDeadlineSeconds": isinstance(s.get("activeDeadlineSeconds"), int) and 0 < s["activeDeadlineSeconds"] <= 600,
        "ttlSecondsAfterFinished set": isinstance(s.get("ttlSecondsAfterFinished"), int),
        "restartPolicy Never": pod["restartPolicy"] == "Never",
        "digest-pinned driver image": c["image"] == f"ghcr.io/radityaaa43/iroha3-rd-driver@{digest}",
        "imagePullSecrets ghcr-pull": pod.get("imagePullSecrets") == [{"name": "ghcr-pull"}],
        "no SA token": pod["automountServiceAccountToken"] is False,
        "non-root + seccomp": pod["securityContext"].get("runAsNonRoot") is True and pod["securityContext"].get("seccompProfile") == {"type": "RuntimeDefault"},
        "container hardening": c["securityContext"].get("allowPrivilegeEscalation") is False and c["securityContext"].get("readOnlyRootFilesystem") is True
        and c["securityContext"].get("capabilities", {}).get("drop") == ["ALL"],
        "requests and limits": "requests" in c["resources"] and "limits" in c["resources"],
    }
    for name, good in checks.items():
        if not good:
            bad.append(f"Job lensa-sign: {name}")
    vols = {v["name"]: v for v in pod["volumes"]}
    ca = vols.get("ca", {}).get("secret", {})
    if ca.get("secretName") != "iroha3-lensa-ca" or ca.get("defaultMode") != 0o400 or sorted(i["key"] for i in ca.get("items", [])) != ["ca.crt", "ca.key"]:
        bad.append(f"volume ca must be Secret iroha3-lensa-ca items ca.crt + ca.key mode 0400: {ca}")
    if vols.get("csr", {}).get("configMap", {}).get("name") != "lensa-csr":
        bad.append("volume csr must be ConfigMap lensa-csr")
    if "emptyDir" not in vols.get("tmp", {}):
        bad.append("volume tmp must be an emptyDir")
    if set(vols) != {"ca", "csr", "tmp"}:
        bad.append(f"volumes must be exactly ca, csr, tmp: {sorted(vols)}")
    for m in c.get("volumeMounts", []):
        if m["name"] != "tmp" and m.get("readOnly") is not True:
            bad.append(f"mount {m['name']} must be read-only")
    cmd = " ".join(c.get("command", []) + c.get("args", []))
    for need in ("req -in /csr/lensa.csr -noout -verify", "subject=CN=lensa", "prime256v1", "Requested Extensions", "basicConstraints=CA:FALSE", "extendedKeyUsage=clientAuth",
                 "keyUsage=digitalSignature", "-days 365", "-CAserial /tmp/ca.srl", "verify -CAfile /ca/ca.crt -purpose sslclient", "cat /tmp/lensa.crt"):
        if need not in cmd:
            bad.append(f"signing command lacks {need!r}")
    for banned in ("cat /ca/ca.key", "echo /ca/ca.key", "base64", "/ca/ca.key >"):
        if banned in cmd:
            bad.append(f"signing command must never output the CA key ({banned!r})")
np = by.get(("NetworkPolicy", "lensa-sign-egress"))
if np:
    sp = np["spec"]
    if sp.get("podSelector") != {"matchLabels": {"rd-iroha3/role": "lensa-sign", "rd/egress-locked": "true"}} or sp.get("policyTypes") != ["Egress"] or sp.get("egress") != [] or "ingress" in sp:
        bad.append(f"NetworkPolicy lensa-sign-egress must be Egress-only DENY-ALL (egress: []) for role=lensa-sign: {sp}")
if bad:
    print("\n".join(f"FAIL: lensa-sign {party}: {b}" for b in bad), file=sys.stderr)
    sys.exit(1)
print(f"ok:   lensa-sign {party}: {len(docs)} objects match")
