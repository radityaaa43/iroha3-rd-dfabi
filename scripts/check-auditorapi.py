#!/usr/bin/env python3
"""Check the rendered auditor-client `keygen` / `put` stages (deploy/auditor-sign, analyst OPTION C) on stdin.
Usage: check-auditorapi.py keygen <party> <tools-image> <driver digest> [--replace] <ip/32:port>... | put <party> <tools-image> <driver digest> <cert-file>
The key is made in a pod of the auditor's own namespace and written by that pod into the pre-created EMPTY Secret auditor-client-cert through a Role limited to
get/update/patch on resourceNames [auditor-client-cert] (create / list / watch / delete / other secrets: never). Only the CSR / the public cert is printed.
The pod has TWO pinned images: the DRIVER image (initContainer `openssl`: the key + CSR are made there, into a MEMORY emptyDir) and the TOOLS image (container `run`: kubectl, no openssl)."""
import json
import sys

import yaml

stage, party, image, drv = sys.argv[1:5]
extra = [a for a in sys.argv[5:] if a != "--replace"]
replace = "--replace" in sys.argv[5:]  # keygen rendered with --replace (key ROTATION: the Secret already holds the pair [tls.crt tls.key]; nothing is deleted)
ns = f"rd-iroha3-{party}"
SECRET = "auditor-client-cert"
docs = [d for d in yaml.safe_load_all(sys.stdin.read()) if d]
by = {(d["kind"], d["metadata"]["name"]): d for d in docs}
bad = []
if stage == "keygen":
    want = {("ServiceAccount", "auditor-client-api"), ("Role", "auditor-client-api"), ("RoleBinding", "auditor-client-api"),
            ("NetworkPolicy", "auditor-client-api-egress"), ("Job", "auditor-client-keygen")}
    jname = "auditor-client-keygen"
else:
    want = {("ConfigMap", "auditor-client-crt"), ("Job", "auditor-client-put")}
    jname = "auditor-client-put"
if set(by) != want or len(docs) != len(want):
    bad.append(f"objects: want exactly {sorted(want)}, got {sorted(by)}")
for (k, n), d in by.items():
    if d["metadata"].get("namespace") != ns:
        bad.append(f"{k} {n} in namespace {d['metadata'].get('namespace')}, want {ns}")
flat = json.dumps(docs)
for banned in ("PRIVATE KEY", "nodeName", "hostNetwork", '"kind": "Secret"', "iroha3-role-ca", "iroha3-lensa-ca", "bi-gov", "cluster-admin", "ClusterRole"):
    if banned in flat:
        bad.append(f"rendered objects must not contain {banned!r}")
if stage == "keygen":
    role = by.get(("Role", "auditor-client-api"))
    if role and role["rules"] != [{"apiGroups": [""], "resources": ["secrets"], "resourceNames": [SECRET], "verbs": ["get", "patch", "update"]}]:
        bad.append(f"Role must be EXACTLY get/patch/update on secrets resourceNames [{SECRET}] (no create/list/watch/delete, no other resource): {role['rules']}")
    rb = by.get(("RoleBinding", "auditor-client-api"))
    if rb and (rb["roleRef"] != {"apiGroup": "rbac.authorization.k8s.io", "kind": "Role", "name": "auditor-client-api"}
               or rb["subjects"] != [{"kind": "ServiceAccount", "name": "auditor-client-api", "namespace": ns}]):
        bad.append(f"RoleBinding must bind Role auditor-client-api to ONLY SA auditor-client-api in {ns}: {rb['roleRef']} {rb['subjects']}")
    np = by.get(("NetworkPolicy", "auditor-client-api-egress"))
    if np:
        sp = np["spec"]
        cidrs = list(dict.fromkeys(a.split(":")[0] for a in extra))
        ports = list(dict.fromkeys(int(a.split(":")[1]) for a in extra))
        want_eg = [{"to": [{"ipBlock": {"cidr": c}} for c in cidrs], "ports": [{"protocol": "TCP", "port": p} for p in ports]}]
        if (sp.get("podSelector") != {"matchLabels": {"rd-iroha3/role": "auditor-client-api", "rd/egress-locked": "true"}} or sp.get("policyTypes") != ["Egress"]
                or "ingress" in sp or sp.get("egress") != want_eg):
            bad.append(f"NetworkPolicy auditor-client-api-egress: Egress-only, role=auditor-client-api + rd/egress-locked, ONLY the given API server /32:port (no DNS): {json.dumps(sp)}")
        if ports != [6443]:
            bad.append(f"API server port must be exactly 6443 (the endpoint form; the ClusterIP :443 form is closed on this CNI): {ports}")
        if any(not c.endswith("/32") for c in cidrs):
            bad.append("API server addresses must be /32")
job = by.get(("Job", jname))
if job:
    s = job["spec"]; pod = s["template"]["spec"]; c = pod["containers"][0]
    ics = pod.get("initContainers", [])
    ic = ics[0] if len(ics) == 1 else {"image": "", "command": [], "securityContext": {}, "resources": {}, "volumeMounts": [], "name": ""}
    lab = s["template"]["metadata"]["labels"]
    checks = {
        "labels role=auditor-client-api + rd/egress-locked=true + party": lab.get("rd-iroha3/role") == "auditor-client-api" and lab.get("rd/egress-locked") == "true" and lab.get("rd-iroha3/party") == party,
        "backoffLimit 0": s.get("backoffLimit") == 0,
        "bounded activeDeadlineSeconds": isinstance(s.get("activeDeadlineSeconds"), int) and 0 < s["activeDeadlineSeconds"] <= 600,
        "ttlSecondsAfterFinished set": isinstance(s.get("ttlSecondsAfterFinished"), int),
        "restartPolicy Never": pod["restartPolicy"] == "Never",
        "digest-pinned tools image, exactly the given one": c["image"] == image and "@sha256:" in c["image"],
        "exactly one initContainer `openssl` = the digest-pinned driver image": len(ics) == 1 and ic["name"] == "openssl" and ic["image"] == f"ghcr.io/radityaaa43/iroha3-rd-driver@{drv}",
        "initContainer hardening + resources": ic["securityContext"].get("allowPrivilegeEscalation") is False and ic["securityContext"].get("readOnlyRootFilesystem") is True
        and ic["securityContext"].get("capabilities", {}).get("drop") == ["ALL"] and "requests" in ic["resources"] and "limits" in ic["resources"] and not ic.get("env"),
        "imagePullSecrets ghcr-pull": pod.get("imagePullSecrets") == [{"name": "ghcr-pull"}],
        "dedicated SA, token mounted only here": pod.get("serviceAccountName") == "auditor-client-api" and pod.get("automountServiceAccountToken") is True,
        "non-root + seccomp": pod["securityContext"].get("runAsNonRoot") is True and pod["securityContext"].get("seccompProfile") == {"type": "RuntimeDefault"},
        "container hardening": c["securityContext"].get("allowPrivilegeEscalation") is False and c["securityContext"].get("readOnlyRootFilesystem") is True
        and c["securityContext"].get("capabilities", {}).get("drop") == ["ALL"],
        "requests and limits": "requests" in c["resources"] and "limits" in c["resources"],
        "no env secrets": [e["name"] for e in c.get("env", [])] == ["HOME"] and not c.get("envFrom"),
    }
    for name, good in checks.items():
        if not good:
            bad.append(f"Job {jname}: {name}")
    vols = {v["name"]: v for v in pod["volumes"]}
    if "emptyDir" not in vols.get("tmp", {}) or vols["tmp"]["emptyDir"].get("medium") != "Memory":
        bad.append("volume tmp must be a Memory emptyDir (the key never touches a disk)")
    if "emptyDir" not in vols.get("work", {}) or vols["work"]["emptyDir"].get("medium") != "Memory":
        bad.append("volume work (key + CSR hand-over between the two containers) must be a Memory emptyDir")
    allowed = {"tmp", "work"} if stage == "keygen" else {"tmp", "work", "crt"}
    if set(vols) != allowed or any("secret" in v or "persistentVolumeClaim" in v or "hostPath" in v for v in vols.values()):
        bad.append(f"volumes must be exactly {sorted(allowed)}, none a Secret/PVC/hostPath: {sorted(vols)}")
    for m in c.get("volumeMounts", []):
        if m["name"] != "tmp" and m.get("readOnly") is not True:
            bad.append(f"main container mount {m['name']} must be read-only")
    cmd = " ".join(c.get("command", []) + c.get("args", []))
    icmd = " ".join(ic.get("command", []))
    if "openssl" in cmd:
        bad.append("the tools image has no openssl: the main container script must not call it (the initContainer does)")
    for banned in ("kubectl", "curl", "wget", "cat /work", "echo", "base64"):
        if banned in icmd:
            bad.append(f"the openssl initContainer holds the key: it must not contain {banned!r}")
    if stage == "keygen":
        guard = ('test "$n" = 2', "refusing to replace") if replace else ('test "$n" = 0', "refusing to overwrite a key")
        if replace and ('test "$n" = 0' in cmd or "refusing to overwrite a key" in cmd):
            bad.append("--replace must not keep the empty-Secret guard")
        if not replace and "refusing to replace" in cmd:
            bad.append("the replace guard only with --replace")
        need = ("{{if .data}}{{len .data}}{{else}}0{{end}}", *guard, "base64 -w0 /work/tls.key", "--patch-file /tmp/patch.json", '{"data":{"tls.key":',
                "cat /work/auditor-client.csr", "{{range $k, $v := .data}}{{$k}} {{end}}")
        for n in ("-newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes", f"-subj '/CN={party}-auditor'", "-keyout /work/tls.key", "-out /work/auditor-client.csr", "umask 077"):
            if n not in icmd:
                bad.append(f"initContainer script lacks {n!r}")
    else:
        need = ('{"data":{"tls.crt":', "--patch-file /tmp/patch.json", "{{range $k, $v := .data}}{{$k}} {{end}}")
        if f"subject=CN={party}-auditor" not in icmd:
            bad.append("the put initContainer must check the certificate subject")
    for n in need:
        if n not in cmd:
            bad.append(f"script lacks {n!r}")
    # the key / any secret value is never printed, put into an argv, or exported: names only
    for banned in ("cat /tmp/tls.key", "cat /work/tls.key", "echo $", "echo \"", "-o yaml", "-o json", "-o jsonpath", "--output", " -p ", "--patch '", '--patch "', "base64 -d", "--decode", "curl", "wget", "kubectl delete", "kubectl replace", "kubectl create", "kubectl apply"):
        if banned in cmd:
            bad.append(f"script must never contain {banned!r}")
    if stage == "keygen" and "tls.crt" in cmd:
        bad.append("the keygen Job writes ONLY tls.key")
    if stage == "put":
        if "tls.key" in cmd or "/tmp/tls.key" in cmd:
            bad.append("the put Job writes ONLY tls.crt and never touches the key")
        cm = by.get(("ConfigMap", "auditor-client-crt"))
        if cm and (list(cm["data"]) != ["tls.crt"] or cm["data"]["tls.crt"].count("BEGIN") != 1 or "PRIVATE" in cm["data"]["tls.crt"]):
            bad.append("ConfigMap auditor-client-crt must hold exactly one PUBLIC certificate under tls.crt")
        if cm and extra and cm["data"]["tls.crt"].strip() != open(extra[0]).read().strip():
            bad.append("ConfigMap auditor-client-crt differs from the given certificate file")
if bad:
    print("\n".join(f"FAIL: auditor-api {stage} {party}: {b}" for b in bad), file=sys.stderr)
    sys.exit(1)
print(f"ok:   auditor-api {stage} {party}: {len(docs)} objects match")
