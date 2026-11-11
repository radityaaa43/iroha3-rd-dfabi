#!/usr/bin/env python3
"""Check the rendered S13 pool-init manifests on stdin. Usage: check-poolinit.py <digest> <hash8> <chain-id> <rd-reserve> <dfabi-reserve>"""
import json
import sys
import tomllib

import yaml

digest, h8, chain, rd, dfabi = sys.argv[1:6]
ns = "rd-iroha3-bi"
docs = [d for d in yaml.safe_load_all(sys.stdin.read()) if d]
by = {(d["kind"], d["metadata"]["name"]): d for d in docs}
bad = []
want = {("ConfigMap", "pool-init-config"), ("PersistentVolumeClaim", "pools-index"), ("Job", "pool-init")}
if set(by) != want or len(docs) != 3:
    bad.append(f"objects: want exactly {sorted(want)}, got {sorted(by)}")
for (k, n), d in by.items():
    if d["metadata"].get("namespace") != ns:
        bad.append(f"{k} {n} is in namespace {d['metadata'].get('namespace')}, want {ns}")
    if d["metadata"].get("labels", {}).get("app.kubernetes.io/part-of") != "rd-iroha3":
        bad.append(f"{k} {n}: label part-of=rd-iroha3 missing")
flat = json.dumps(docs)
for banned in ("bi-auditor-key", "nodeSelector", "nodeName", "affinity", "hostNetwork", "PRIVATE KEY"):
    if banned in flat:
        bad.append(f"rendered objects must not contain {banned!r}")
if any(k == "Secret" for k, _ in by):
    bad.append("a Secret must never be rendered")

cm = by.get(("ConfigMap", "pool-init-config"))
if cm:
    cfg = tomllib.loads(cm["data"]["rd-dfabi.toml"])
    urls = [f"https://gateway.rd-iroha3-{p}.svc.cluster.local:8443" for p in ("bi", "bank-a", "bank-b")]
    want_cfg = {"chain": chain, "network_id_file": "/genesis/genesis.expected_hash", "party": "bi", "client_toml": "/work/client.toml",
                "key_dir": "/keys", "pools_file": "/pools/pools.json"}
    for k, v in want_cfg.items():
        if cfg.get(k) != v:
            bad.append(f"rd-dfabi.toml {k} = {cfg.get(k)!r}, want {v!r}")
    if cfg.get("audit") != {"min_approvals": 2, "auditor_urls": urls}:
        bad.append(f"[audit] must be 2-of-3 through the three gateways: {cfg.get('audit')}")
    if cfg.get("tls") != {"client_cert": "/tls/client/tls.crt", "client_key": "/tls/client/tls.key", "server_ca_dir": "/tls/cas"}:
        bad.append(f"[tls]: {cfg.get('tls')}")
    if cfg.get("assets") != {"rd": "7onbjg2gRXveoAAUFsohCZyGW98t", "dfabi": "4mBWK1JCwQdHLDPpuVKc56eLsXka"}:
        bad.append(f"assets: {cfg.get('assets')}")
    if cfg.get("torii", {}).get("bi") != "http://bi-0.bi.rd-iroha3-bi.svc.cluster.local:8080/":
        bad.append("torii.bi must be the own peer (the sponsor submits to the acting party's Torii)")
    if cfg.get("mint_enabled"):
        bad.append("mint_enabled must not be set on the pool-init config")

pvc = by.get(("PersistentVolumeClaim", "pools-index"))
if pvc and (pvc["spec"]["resources"]["requests"]["storage"] != "1Gi" or pvc["spec"]["accessModes"] != ["ReadWriteOnce"]):
    bad.append("PVC pools-index: 1Gi ReadWriteOnce")

job = by.get(("Job", "pool-init"))
if job:
    s = job["spec"]
    pod = s["template"]["spec"]
    c = pod["containers"][0]
    checks = {
        "backoffLimit 0 (a failed run is never retried)": s.get("backoffLimit") == 0,
        "bounded activeDeadlineSeconds": isinstance(s.get("activeDeadlineSeconds"), int) and 0 < s["activeDeadlineSeconds"] <= 3600,
        "ttlSecondsAfterFinished set": isinstance(s.get("ttlSecondsAfterFinished"), int),
        "restartPolicy Never": pod["restartPolicy"] == "Never",
        "digest-pinned image": c["image"] == f"ghcr.io/radityaaa43/iroha3-rd-driver@{digest}",
        "imagePullSecret ghcr-pull": pod.get("imagePullSecrets") == [{"name": "ghcr-pull"}],
        "no token": pod["automountServiceAccountToken"] is False,
        "role label pool-init": s["template"]["metadata"]["labels"].get("rd-iroha3/role") == "pool-init",
        "non-root": pod["securityContext"].get("runAsNonRoot") is True and pod["securityContext"].get("runAsUser") == 1001,
        "container hardening": c["securityContext"].get("allowPrivilegeEscalation") is False and c["securityContext"].get("readOnlyRootFilesystem") is True
        and c["securityContext"].get("capabilities", {}).get("drop") == ["ALL"],
        "requests and limits": "requests" in c["resources"] and "limits" in c["resources"],
    }
    for name, good in checks.items():
        if not good:
            bad.append(f"Job pool-init: {name}")
    cmd = " ".join(c.get("command", []) + c.get("args", []))
    for need in ("keys client-toml /work bi-gov", "--network-id-file /genesis/genesis.expected_hash", "pool-init /config/rd-dfabi.toml", f"--rd-reserve {rd}", f"--dfabi-reserve {dfabi}", "rm -f /work/bi-gov.seed"):
        if need not in cmd:
            bad.append(f"command lacks {need!r}")
    vols = {v["name"]: v for v in pod["volumes"]}
    secrets = {v["secret"]["secretName"]: v["secret"] for v in vols.values() if "secret" in v}
    if set(secrets) != {"bi-gov-key", "bi-keys", "iroha3-client-cert"}:
        bad.append(f"Secret volumes must be exactly bi-gov-key, bi-keys, iroha3-client-cert: {sorted(secrets)}")
    else:
        if [i["key"] for i in secrets["bi-gov-key"]["items"]] != ["bi-gov.seed"] or secrets["bi-gov-key"]["defaultMode"] != 0o400:
            bad.append("bi-gov-key: only bi-gov.seed, mode 0400")
        if [i["key"] for i in secrets["bi-keys"]["items"]] != ["bi.note"] or secrets["bi-keys"]["defaultMode"] != 0o400:
            bad.append("bi-keys: ONLY bi.note (the BI seed stays out of this Job), mode 0400")
    if vols.get("work", {}).get("emptyDir") is None:
        bad.append("work must be an emptyDir (the derived client.toml never persists)")
    if vols.get("pools", {}).get("persistentVolumeClaim", {}).get("claimName") != "pools-index":
        bad.append("pools must be PVC pools-index")
    if vols.get("server-cas", {}).get("configMap", {}).get("name") != "gateway-server-cas":
        bad.append("server-cas must be the existing ConfigMap gateway-server-cas (driver render --audit-tls)")
    for m in c["volumeMounts"]:
        if m["name"] not in ("work", "pools") and m.get("readOnly") is not True:
            bad.append(f"mount {m['name']} must be read-only")

if bad:
    print("\n".join(f"FAIL: pool-init: {b}" for b in bad), file=sys.stderr)
    sys.exit(1)
print(f"ok:   pool-init: {len(docs)} objects match")
