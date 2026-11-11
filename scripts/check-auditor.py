#!/usr/bin/env python3
"""Check rendered S11/S12 auditor manifests on stdin. Usage: check-auditor.py <party> <digest> <hash8> <chain-id>"""
import json
import sys
import tomllib

import yaml

party, digest, h8, chain = sys.argv[1:5]
ns = f"rd-iroha3-{party}"
key_name = "bi-auditor" if party == "bi" else f"{party}-auditor"
docs = [d for d in yaml.safe_load_all(sys.stdin.read()) if d]
by = {(d["kind"], d["metadata"]["name"]): d for d in docs}
bad = []


def need(kind, name):
    d = by.get((kind, name))
    if d is None:
        bad.append(f"missing {kind} {name}")
    return d


want = {("ConfigMap", "auditor-config"), ("PersistentVolumeClaim", "audit-store"), ("Deployment", "auditor"), ("Service", "auditor"),
        ("NetworkPolicy", "auditor-ingress")}
if set(by) != want or len(docs) != len(want):
    bad.append(f"objects: want exactly {sorted(want)}, got {sorted(by)} ({len(docs)} documents)")
for (k, n), d in by.items():
    if d["metadata"].get("namespace") != ns:
        bad.append(f"{k} {n} is in namespace {d['metadata'].get('namespace')}, want {ns}")
    if d["metadata"].get("labels", {}).get("app.kubernetes.io/part-of") != "rd-iroha3":
        bad.append(f"{k} {n}: label part-of=rd-iroha3 missing")
if any(k == "Secret" for k, _ in by):
    bad.append("a Secret must never be rendered (the org creates its own auditor key Secret with its own kubeconfig)")
flat = json.dumps(docs)
for banned in ("nodeSelector", "nodeName", "affinity", "priorityClassName", "hostNetwork", "bi-auditor-key" if party != "bi" else "@@"):
    if banned in flat:
        bad.append(f"rendered objects must not contain {banned!r}")

cm = need("ConfigMap", "auditor-config")
if cm:
    if set(cm["data"]) != {"rd-dfabi.toml", "peers.json"}:
        bad.append(f"auditor-config keys: {sorted(cm['data'])}")
    else:
        cfg = tomllib.loads(cm["data"]["rd-dfabi.toml"])
        want_cfg = {"chain": chain, "network_id_file": "/genesis/genesis.expected_hash", "peers_json": "/config/peers.json", "key_dir": "/keys", "party": party}
        for k, v in want_cfg.items():
            if cfg.get(k) != v:
                bad.append(f"rd-dfabi.toml {k} = {cfg.get(k)!r}, want {v!r}")
        a = cfg.get("auditor", {})
        if a.get("key_name") != key_name or a.get("listen") != "0.0.0.0:8090" or a.get("store_dir") != "/audit-store":
            bad.append(f"[auditor] key_name/listen/store_dir: {a}")
        if len(a.get("parties", [])) != 4 or not all(p.startswith("ed0120") for p in a.get("parties", [])):
            bad.append("[auditor] parties must be the 4 trading accounts (ed0120 public keys), bi-gov excluded")
        if "seed" in json.dumps(cfg).lower() and "private" in json.dumps(cfg).lower():
            bad.append("the config must hold public values only")
        if sorted(cfg.get("torii", {})) != ["bank-a", "bank-b", "bank-c", "bi"]:
            bad.append(f"torii map: {cfg.get('torii')}")

pvc = need("PersistentVolumeClaim", "audit-store")
if pvc and (pvc["spec"]["resources"]["requests"]["storage"] != "1Gi" or pvc["spec"]["accessModes"] != ["ReadWriteOnce"]):
    bad.append("PVC audit-store: 1Gi ReadWriteOnce")

dep = need("Deployment", "auditor")
if dep:
    s = dep["spec"]
    pod = s["template"]["spec"]
    c = pod["containers"][0]
    role = {"app.kubernetes.io/part-of": "rd-iroha3", "rd-iroha3/party": party, "rd-iroha3/role": "auditor"}
    checks = {
        "digest-pinned image": c["image"] == f"ghcr.io/radityaaa43/iroha3-rd-driver@{digest}",
        "replicas 1 + Recreate (RWO volume, one approver at a time)": s["replicas"] == 1 and s["strategy"] == {"type": "Recreate"},
        "args auditor": c["args"] == ["auditor", "/config/rd-dfabi.toml"],
        "port 8090": [p["containerPort"] for p in c["ports"]] == [8090],
        "role labels": s["template"]["metadata"]["labels"] == role and s["selector"]["matchLabels"] == role,
        "no token": pod["automountServiceAccountToken"] is False,
        "non-root": pod["securityContext"].get("runAsNonRoot") is True and pod["securityContext"].get("runAsUser") == 1001,
        "container hardening": c["securityContext"].get("allowPrivilegeEscalation") is False
        and c["securityContext"].get("readOnlyRootFilesystem") is True
        and c["securityContext"].get("capabilities", {}).get("drop") == ["ALL"],
        "requests and limits": "requests" in c["resources"] and "limits" in c["resources"],
        "imagePullSecret ghcr-pull": pod.get("imagePullSecrets") == [{"name": "ghcr-pull"}],
    }
    for name, good in checks.items():
        if not good:
            bad.append(f"Deployment auditor: {name}")
    secret_vols = [v for v in pod["volumes"] if "secret" in v]
    if len(secret_vols) != 1 or secret_vols[0]["secret"]["secretName"] != f"{key_name}-key":
        bad.append(f"the only Secret volume must be {key_name}-key (the org's OWN auditor key): {secret_vols}")
    else:
        sv = secret_vols[0]["secret"]
        if sorted(i["key"] for i in sv.get("items", [])) != sorted([f"{key_name}.seed", f"{key_name}.hybrid"]) or sv.get("defaultMode") != 0o400:
            bad.append(f"{key_name}-key must project exactly {key_name}.seed and {key_name}.hybrid with mode 0400: {sv}")
    mounts = {m["mountPath"]: m for m in c["volumeMounts"]}
    for path in ("/keys", "/config", "/genesis"):
        if path not in mounts or mounts[path].get("readOnly") is not True:
            bad.append(f"mount {path} must be read-only")
    if "/audit-store" not in mounts or mounts["/audit-store"].get("readOnly"):
        bad.append("/audit-store must be writable")

svc = need("Service", "auditor")
if svc and (svc["spec"]["type"] != "ClusterIP" or svc["spec"]["ports"][0]["port"] != 8090):
    bad.append("Service auditor: ClusterIP 8090")

np = need("NetworkPolicy", "auditor-ingress")
if np:
    if np["spec"]["podSelector"] != {"matchLabels": {"rd-iroha3/role": "auditor"}} or np["spec"]["policyTypes"] != ["Ingress"]:
        bad.append("NetworkPolicy auditor-ingress: selector role=auditor, Ingress only")
    if np["spec"]["ingress"] != [{"from": [{"podSelector": {"matchLabels": {"rd-iroha3/role": "gateway"}}}], "ports": [{"protocol": "TCP", "port": 8090}]}]:
        bad.append(f"NetworkPolicy auditor-ingress: TCP 8090 from the own gateway pods ONLY: {np['spec']['ingress']}")

if bad:
    print("\n".join(f"FAIL: {party}: {b}" for b in bad), file=sys.stderr)
    sys.exit(1)
print(f"ok:   {party}: {len(docs)} objects match")
