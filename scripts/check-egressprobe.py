#!/usr/bin/env python3
"""Check the rendered egress-probe manifests on stdin. Usage: check-egressprobe.py <party> <digest> [driver | peer <remote ip>... | gateway | lb <target ip>... | auditor <bank-c gateway-lb ip>]
(driver = the --role driver Pod only; peer = the --role peer Pod only, labelled ONLY rd-iroha3/role=peer, with the given remote P2P /32 addresses;
gateway = the --role gateway Pod only, labelled ONLY role=gateway + app.kubernetes.io/name=gateway; lb = the --role lb Pod + its own egress policy: ONLY the target LB /32 on 8443;
auditor = the --role auditor Pod only, labelled EXACTLY the auditor pod labels role=auditor + rd/egress-locked=true, selected by the REAL auditor-egress)"""
import json
import sys

import yaml

party, digest = sys.argv[1:3]
role = sys.argv[3] if len(sys.argv) > 3 else ""
remotes = sys.argv[4:]
dmin = role == "driver-min"  # label ONLY rd-iroha3/role=driver: admitted by peers-torii/driver-egress, matches NO Service/Deployment selector
drole, prole, grole, lrole, arole = role in ("driver", "driver-min"), role == "peer", role == "gateway", role == "lb", role == "auditor"
pname = "egress-probe-driver-min" if dmin else "egress-probe-driver" if drole else "egress-probe-peer" if prole else "egress-probe-gateway" if grole else "egress-probe-auditor" if arole else "lb-probe" if lrole else "egress-probe"
C1 = ("bi", "bank-a", "bank-b")
same = C1 if party in C1 else ("bank-c",)
foreign = {"bi": "bank-a", "bank-a": "bank-b", "bank-b": "bi"}.get(party)  # ring inside cluster 1; bank-c has no other namespace on its cluster
ns = f"rd-iroha3-{party}"
docs = [d for d in yaml.safe_load_all(sys.stdin.read()) if d]
by = {(d["kind"], d["metadata"]["name"]): d for d in docs}
bad = []
want = {("Pod", pname)} if (drole or prole or grole or arole) else {("Pod", "lb-probe"), ("NetworkPolicy", "lb-probe-egress")} if lrole else {("Pod", "egress-probe"), ("NetworkPolicy", "egress-probe-egress")}
if set(by) != want or len(docs) != len(want):
    bad.append(f"objects: want exactly {sorted(want)}, got {sorted(by)}")
for (k, n), d in by.items():
    if d["metadata"].get("namespace") != ns:
        bad.append(f"{k} {n} in namespace {d['metadata'].get('namespace')}, want {ns}")
flat = json.dumps(docs)
for banned in ("PRIVATE KEY", "secretName", "secretKeyRef", "nodeName", "hostNetwork", "serviceAccountName", "ipBlock"):
    if banned == "ipBlock" and lrole:  # the LB probe's own policy allows exactly the other cluster's LB /32 (checked below)
        continue
    if banned in flat:
        bad.append(f"rendered objects must not contain {banned!r}")
pod = by.get(("Pod", pname))
if pod:
    lab, s = pod["metadata"]["labels"], pod["spec"]
    c = s["containers"][0]
    checks = {
        "labels": (lab == {"rd-iroha3/role": "driver"}) if dmin else
                  (lab.get("rd-iroha3/role") == "driver" and "rd/egress-locked" not in lab and lab.get("rd-iroha3/party") == party) if drole else
                  (lab == {"rd-iroha3/role": "peer"}) if prole else  # ONLY role=peer: no part-of/party, so no StatefulSet/Service selector (all need part-of+party+role) can match it
                  (lab == {"rd-iroha3/role": "gateway", "app.kubernetes.io/name": "gateway"}) if grole else  # no part-of/party: the gateway Service/Deployment selectors cannot match it
                  (lab == {"rd-iroha3/role": "lb-probe"}) if lrole else
                  (lab == {"rd-iroha3/role": "auditor", "rd/egress-locked": "true"}) if arole else  # EXACTLY the auditor pod labels (no part-of/party: no Service/Deployment selector matches it)
                  (lab.get("rd-iroha3/role") == "egress-probe" and lab.get("rd/egress-locked") == "true" and lab.get("rd-iroha3/party") == party),
        "no container ports": not c.get("ports"),
        "deadline 1800 s": s.get("activeDeadlineSeconds") == 1800 if (grole or lrole or arole) else True,
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
    base = ("1.1.1.1", "8.8.8.8", "KUBERNETES_SERVICE_HOST", "ghcr.io", "sleep 15", f"{party}-0.{party}.rd-iroha3-{party}.svc.cluster.local")
    status = ("GET /status HTTP/1.0", "(peers|blocks|view_changes)", "Accept: application/json", "http=", "ctype=", "bytes=", "# PARSE-BEGIN", "# PARSE-END")
    if lrole:  # open nothing but the target LB(s) on 8443
        need = ("for t in " + " ".join(remotes), "8443")
        for n in ("1.1.1.1", "8.8.8.8", "KUBERNETES_SERVICE_HOST", "ghcr.io", "getent", "GET /status"):
            if n in script:
                bad.append(f"lb-role probe must only connect to the LB target(s): found {n!r}")
    elif grole:  # R17 gateway-egress controls: positive = own peer 8080, own driver 8091, the OPA bundle-server Service :80; negative = internet/apiserver/ghcr (+ foreign peer, also ingress-denied)
        need = base + (f"driver.rd-iroha3-{party}.svc.cluster.local", f"bundle-server.rd-zeto-{party}.svc.cluster.local", "8091", "8080")
        need += (f"{foreign}-0.{foreign}.rd-iroha3-{foreign}.svc.cluster.local",) if foreign else ()
        if "GET /status" in script:
            bad.append("gateway-role probe must not read /status")
    elif arole:  # auditor-egress controls: positive = the 3 same-cluster gateways :8443 (by name) + bank-c's gateway-lb /32 :8443; negative = own Torii :8080, internet/apiserver/ghcr
        need = base + tuple(f"gateway.rd-iroha3-{q}.svc.cluster.local" for q in ("bi", "bank-a", "bank-b")) + ("for r in " + " ".join(remotes), "8443", "8080")
        if "GET /status" in script:
            bad.append("auditor-role probe must not read /status")
    elif prole:  # NEW connections: every same-cluster peer on 1337 and 8080, every remote LB /32 on 1337 (positive); foreign driver (negative, also ingress-denied)
        need = base + tuple(f"{q}-0.{q}.rd-iroha3-{q}.svc.cluster.local" for q in same) + ("for r in " + " ".join(remotes), "1337", "8080")
        need += (f"driver.rd-iroha3-{foreign}.svc.cluster.local",) if foreign else ()
        if "GET /status" in script:
            bad.append("peer-role probe must not read /status")
    else:
        need = base + status
        if drole and foreign:  # negative targets of driver-egress: another party's peer Torii and driver
            need += (f"{foreign}-0.{foreign}.rd-iroha3-{foreign}.svc.cluster.local", f"driver.rd-iroha3-{foreign}.svc.cluster.local")
    if "st() {" in script and 'st() { [ "$(tcp "$1" 8080)" = OPEN ] ||' not in script:
        bad.append("the status read must be guarded by the timeout-bounded tcp check (an unguarded /dev/tcp connect hangs ~130 s when the policy drops the SYN: the loop must stay ~31 s)")
    for n in need:
        if n not in script:
            bad.append(f"probe loop lacks {n!r}")
    if (prole or lrole or arole) and not remotes:
        bad.append("peer/lb-role check needs at least one target ip argument")
np = by.get(("NetworkPolicy", "lb-probe-egress" if lrole else "egress-probe-egress"))
if np and lrole:
    sp = np["spec"]
    want_eg = [{"to": [{"ipBlock": {"cidr": f"{t}/32"}} for t in remotes], "ports": [{"protocol": "TCP", "port": 8443}]}]
    if sp.get("podSelector") != {"matchLabels": {"rd-iroha3/role": "lb-probe"}} or sp.get("policyTypes") != ["Egress"] or "ingress" in sp:
        bad.append(f"NetworkPolicy lb-probe-egress: selector role=lb-probe, Egress only: {sp.get('podSelector')} {sp.get('policyTypes')}")
    if sp.get("egress") != want_eg:
        bad.append(f"NetworkPolicy lb-probe-egress must allow ONLY the target LB /32(s) on TCP 8443 (no DNS, nothing else): {json.dumps(sp.get('egress'))}")
elif np and not (drole or prole or grole or arole):
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
