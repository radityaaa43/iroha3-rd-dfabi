#!/usr/bin/env python3
"""Check rendered S17 driver manifests on stdin. Usage: check-driver.py <party> <digest> <hash8> <chain-id>"""
import json
import sys
import tomllib

import yaml

party, digest, h8, chain = sys.argv[1:5]
ns = f"rd-iroha3-{party}"
docs = [d for d in yaml.safe_load_all(sys.stdin.read()) if d]
by = {(d["kind"], d["metadata"]["name"]): d for d in docs}
bad = []


def need(kind, name):
    d = by.get((kind, name))
    if d is None:
        bad.append(f"missing {kind} {name}")
    return d


if len(docs) != 4:
    bad.append(f"want exactly 4 objects (ConfigMap, Deployment, Service, NetworkPolicy), got {len(docs)}: {sorted(by)}")
for (k, n), d in by.items():
    if d["metadata"].get("namespace") != ns:
        bad.append(f"{k} {n} is in namespace {d['metadata'].get('namespace')}, want {ns}")
    if d["metadata"].get("labels", {}).get("app.kubernetes.io/part-of") != "rd-iroha3":
        bad.append(f"{k} {n}: label part-of=rd-iroha3 missing")
if any(k == "Secret" for k, _ in by):
    bad.append("a Secret must never be rendered (the bank creates <party>-keys itself, with its own kubeconfig)")

cm = need("ConfigMap", "driver-config")
if cm:
    if set(cm["data"]) != {"rd-dfabi.toml", "peers.json"}:
        bad.append(f"driver-config keys: {sorted(cm['data'])}")
    else:
        cfg = tomllib.loads(cm["data"]["rd-dfabi.toml"])
        want = {
            "chain": chain, "network_id_file": "/genesis/genesis.expected_hash", "client_toml": "/keys/client.toml",
            "peers_json": "/config/peers.json", "key_dir": "/keys", "fee_asset": "6TEAJqbb8oEPmLncoNiMRbLEK6tw",
        }
        for k, v in want.items():
            if cfg.get(k) != v:
                bad.append(f"rd-dfabi.toml {k} = {cfg.get(k)!r}, want {v!r}")
        if cfg.get("assets") != {"rd": "7onbjg2gRXveoAAUFsohCZyGW98t", "dfabi": "4mBWK1JCwQdHLDPpuVKc56eLsXka"}:
            bad.append(f"assets must be the Base58 definition ids: {cfg.get('assets')}")
        if cfg.get("party") != party:  # lead condition (node-build#21): no bank may rely on the default `bi`
            bad.append(f"rd-dfabi.toml party = {cfg.get('party')!r}, want {party!r} (set explicitly per party)")
        if cfg.get("lanes") != {"rd": 1, "dfabi": 2}:
            bad.append(f"lanes: {cfg.get('lanes')}")
        if sorted(cfg.get("torii", {})) != ["bank-a", "bank-b", "bank-c", "bi"]:
            bad.append(f"torii map: {cfg.get('torii')}")
        peers = json.loads(cm["data"]["peers.json"])
        if sorted(p["party"] for p in peers) != ["bank-a", "bank-b", "bank-c", "bi"]:
            bad.append("peers.json must list the 4 parties")
        text = cm["data"]["rd-dfabi.toml"] + cm["data"]["peers.json"]
        for forbidden in ("private_key", "seed", ".note", "BEGIN"):
            if forbidden in text:
                bad.append(f"driver-config must hold public values only (found {forbidden!r})")

dep = need("Deployment", "driver")
if dep:
    s = dep["spec"]
    pod = s["template"]["spec"]
    c = pod["containers"][0]
    checks = {
        "1 replica": s["replicas"] == 1,
        "image pinned by digest": c["image"] == f"ghcr.io/radityaaa43/iroha3-rd-driver@{digest}",
        "pullPolicy IfNotPresent": c.get("imagePullPolicy") == "IfNotPresent",
        "imagePullSecrets ghcr-pull": pod.get("imagePullSecrets") == [{"name": "ghcr-pull"}],
        "args server --listen": c["args"] == ["server", "/config/rd-dfabi.toml", "--listen", "0.0.0.0:8091"],
        "port 8091": [p["containerPort"] for p in c["ports"]] == [8091],
        "no token": pod["automountServiceAccountToken"] is False,
        "non-root": pod["securityContext"].get("runAsNonRoot") is True and pod["securityContext"].get("runAsUser") == 1001,
        "seccomp": pod["securityContext"].get("seccompProfile", {}).get("type") == "RuntimeDefault",
        "container hardening": c["securityContext"].get("allowPrivilegeEscalation") is False
        and c["securityContext"].get("readOnlyRootFilesystem") is True
        and c["securityContext"].get("capabilities", {}).get("drop") == ["ALL"],
        "requests": c["resources"]["requests"] == {"cpu": "50m", "memory": "64Mi"},
        "limits": "cpu" in c["resources"]["limits"] and "memory" in c["resources"]["limits"],
        "healthz probes": c["livenessProbe"]["httpGet"]["path"] == "/healthz" and c["readinessProbe"]["httpGet"]["path"] == "/healthz",
        # ANALYST Q10: the server answers ONE request at a time, so /healthz is unanswered while a /dvp-native waits for Applied
        # (up to client.toml status_timeout_ms = 300 s). Liveness must outlast that (no kill mid-request); readiness fails fast so
        # the Service stops routing to a busy driver.
        "liveness outlasts a long request": c["livenessProbe"]["periodSeconds"] * c["livenessProbe"]["failureThreshold"] + c["livenessProbe"].get("timeoutSeconds", 1) >= 240,
        "readiness fails fast": c["readinessProbe"]["periodSeconds"] * c["readinessProbe"]["failureThreshold"] <= 15 and c["readinessProbe"].get("timeoutSeconds", 1) <= 2,
        "role label driver": s["template"]["metadata"]["labels"].get("rd-iroha3/role") == "driver"
        and s["template"]["metadata"]["labels"].get("rd-iroha3/party") == party,
        "no zone or node pin": not any(k in pod for k in ("nodeName", "nodeSelector")) and "nodeAffinity" not in pod.get("affinity", {}),
    }
    for name, good in checks.items():
        if not good:
            bad.append(f"Deployment driver: {name}")
    vols = {v["name"]: v for v in pod["volumes"]}
    secret_vols = [v for v in pod["volumes"] if "secret" in v]
    if len(secret_vols) != 1 or secret_vols[0]["secret"]["secretName"] != f"{party}-keys":
        bad.append(f"the only Secret volume must be {party}-keys: {secret_vols}")
    else:
        sv = secret_vols[0]["secret"]
        if sorted(i["key"] for i in sv.get("items", [])) != sorted([f"{party}.seed", f"{party}.note", "client.toml"]) or sv.get("defaultMode") != 0o400:
            bad.append(f"{party}-keys must project exactly {party}.seed, {party}.note, client.toml with mode 0400: {sv}")
    if any("bi-auditor-key" in json.dumps(v) or "auditor" in json.dumps(v) for v in pod["volumes"]):
        bad.append("the auditor key must never be mounted")
    mounts = {m["mountPath"]: m for m in c["volumeMounts"]}
    for path in ("/keys", "/config", "/genesis"):
        if path not in mounts or mounts[path].get("readOnly") is not True:
            bad.append(f"volume mount {path} must exist and be readOnly")
    if vols.get("genesis", {}).get("configMap", {}).get("name") != f"genesis-{h8}":
        bad.append(f"genesis volume must be ConfigMap genesis-{h8}")
    if vols.get("config", {}).get("configMap", {}).get("name") != "driver-config":
        bad.append("config volume must be ConfigMap driver-config")

svc = need("Service", "driver")
if svc:
    if svc["spec"].get("type", "ClusterIP") != "ClusterIP" or [p["port"] for p in svc["spec"]["ports"]] != [8091]:
        bad.append(f"Service driver: ClusterIP, port 8091 only: {svc['spec']}")
    if svc["spec"]["selector"] != {"app.kubernetes.io/part-of": "rd-iroha3", "rd-iroha3/party": party, "rd-iroha3/role": "driver"}:
        bad.append(f"Service driver selector: {svc['spec']['selector']}")

np = need("NetworkPolicy", "driver-ingress")
if np:
    spec = np["spec"]
    ing = spec["ingress"]
    if spec["podSelector"] != {"matchLabels": {"rd-iroha3/role": "driver"}} or spec["policyTypes"] != ["Ingress"]:
        bad.append(f"driver-ingress podSelector/policyTypes: {spec}")
    if not (len(ing) == 1 and ing[0]["ports"] == [{"protocol": "TCP", "port": 8091}]
            and ing[0]["from"] == [{"podSelector": {"matchLabels": {"rd-iroha3/role": "gateway"}}}]):
        bad.append(f"driver-ingress must admit only the gateway pods of the own namespace on TCP 8091: {ing}")

for b in bad:
    print(f"FAIL: {party}: {b}", file=sys.stderr)
print(f"{'FAIL' if bad else 'ok:  '} {party}: {len(docs)} objects")
sys.exit(1 if bad else 0)
