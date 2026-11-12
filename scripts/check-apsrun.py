#!/usr/bin/env python3
"""Check the rendered aps-run Job manifests on stdin (S13 RED / S15 coordinator). Usage: check-apsrun.py <digest> <name> <bank-c-gw-ip> <rd-dfabi args...>"""
import json
import sys
import tomllib

import yaml

digest, name, bankc_ip, *args = sys.argv[1:]
ns = "rd-iroha3-bi"
PARTIES = ["bi", "bank-a", "bank-b", "bank-c"]
ENVOY = "envoyproxy/envoy@sha256:b1f389c3a6148e85e9de364cb867aa2e5802153abb37ad80f1f2241d693da32a"
docs = [d for d in yaml.safe_load_all(sys.stdin.read()) if d]
by = {(d["kind"], d["metadata"]["name"]): d for d in docs}
bad = []
job = f"aps-run-{name}"
want = {("ConfigMap", "aps-run-config"), ("ConfigMap", "aps-run-gw-envoy"), ("Job", job), ("NetworkPolicy", "aps-run-egress")}
if set(by) != want or len(docs) != len(want):
    bad.append(f"objects: want exactly {sorted(want)}, got {sorted(by)}")
for (k, n), d in by.items():
    if d["metadata"].get("namespace") != ns:
        bad.append(f"{k} {n}: namespace {d['metadata'].get('namespace')}, want {ns}")
flat = json.dumps(docs)
for banned in ("nodeSelector", "nodeName", "hostNetwork", "PRIVATE KEY", "bi-gov", "auditor-key", "auditor-client-cert"):
    if banned in flat:
        bad.append(f"rendered objects must not contain {banned!r}")
cm = by.get(("ConfigMap", "aps-run-config"))
if cm:
    cfg = tomllib.loads(cm["data"]["rd-dfabi.toml"])
    loop = {p: f"http://127.0.0.1:{18101 + i}/" for i, p in enumerate(PARTIES)}
    if cfg.get("torii") != loop:
        bad.append(f"[torii] must be the four loopback listeners of the gw-tls sidecar (all four parties through their gateways), got {cfg.get('torii')}")
    for k, v in {"party": "bi", "key_dir": "/pools/keys", "pools_file": "/pools/pools.json", "client_toml": "/client/client.toml",
                 "account_domain": "wonderland.universal"}.items():
        if cfg.get(k) != v:
            bad.append(f"rd-dfabi.toml {k} = {cfg.get(k)!r}, want {v!r}")
    urls = [f"https://gateway.rd-iroha3-{p}.svc.cluster.local:8443" for p in ("bi", "bank-a", "bank-b")]
    if cfg.get("audit") != {"min_approvals": 2, "auditor_urls": urls}:
        bad.append(f"[audit] must be 2-of-3 through the three gateways: {cfg.get('audit')}")
    want_tls = {"client_cert": "/tls/client/tls.crt", "client_key": "/tls/client/tls.key", "server_ca_dir": "/tls/cas"}
    if cfg.get("tls") != want_tls:
        bad.append(f"[tls] (the /approve calls) must be {want_tls}, got {cfg.get('tls')}")
env = by.get(("ConfigMap", "aps-run-gw-envoy"))
if env:
    e = yaml.safe_load(env["data"]["envoy.yaml"])["static_resources"]
    lst = {l["name"]: l["address"]["socket_address"] for l in e["listeners"]}
    if lst != {f"to-{p}": {"address": "127.0.0.1", "port_value": 18101 + i} for i, p in enumerate(PARTIES)}:
        bad.append(f"sidecar listeners must be 127.0.0.1:18101-18104 only: {lst}")
    for c in e["clusters"]:
        q = c["name"][3:]
        tls = c["transport_socket"]["typed_config"]["common_tls_context"]
        if tls["validation_context"]["trusted_ca"]["filename"] != f"/server-cas/{q}-server-ca.pem":
            bad.append(f"cluster {c['name']}: must pin {q}'s own server CA")
        addr = c["load_assignment"]["endpoints"][0]["lb_endpoints"][0]["endpoint"]["address"]["socket_address"]["address"]
        if addr != (bankc_ip if q == "bank-c" else f"gateway.rd-iroha3-{q}.svc.cluster.local"):
            bad.append(f"cluster {c['name']}: upstream {addr}")
j = by.get(("Job", job))
if j:
    sp = j["spec"]
    if sp.get("backoffLimit") != 0:
        bad.append("Job: backoffLimit 0 (a retry would start a NEW bundle)")
    pod = sp["template"]["spec"]
    labels = sp["template"]["metadata"]["labels"]
    if labels.get("rd/egress-locked") != "true" or labels.get("rd-iroha3/role") != "aps-run":
        bad.append("Job pod: labels rd-iroha3/role=aps-run and rd/egress-locked=true")
    side = [c for c in pod.get("initContainers", []) if c["name"] == "gw-tls"]
    if len(side) != 1 or side[0].get("restartPolicy") != "Always" or side[0]["image"] != ENVOY:
        bad.append("gw-tls must be a native sidecar (initContainer, restartPolicy Always) on the pinned envoy image")
    main = [c for c in pod["containers"] if c["name"] == "aps-run"]
    if len(main) != 1 or main[0]["image"] != f"ghcr.io/radityaaa43/iroha3-rd-driver@{digest}":
        bad.append("container aps-run must run the pinned driver image")
    else:
        cmd = " ".join(main[0]["command"])
        if not cmd.endswith("rd-dfabi " + args[0] + " /config/rd-dfabi.toml " + " ".join(args[1:])):
            bad.append(f"command must end with the given rd-dfabi args: {cmd[-200:]}")
        for need in ("ln -s /keys/bi.seed /pools/keys/bi.seed", "test -f /pools/pools.json"):
            if need not in cmd:
                bad.append(f"command lacks {need!r}")
        mounts = {m["mountPath"]: m for m in main[0]["volumeMounts"]}
        if mounts.get("/client/client.toml", {}).get("subPath") != "client.toml":
            bad.append("client.toml must be a subPath mount (iroha rejects a Secret-volume symlink)")
    vols = {v["name"]: v for v in pod["volumes"]}
    secrets = {v["secret"]["secretName"]: v["secret"] for v in vols.values() if "secret" in v}
    if set(secrets) != {"bi-keys", "iroha3-client-cert"}:
        bad.append(f"Secret volumes must be exactly bi-keys and iroha3-client-cert: {sorted(secrets)}")
    if vols.get("pools", {}).get("persistentVolumeClaim", {}).get("claimName") != "pools-index":
        bad.append("pools must be the existing PVC pools-index")
np = by.get(("NetworkPolicy", "aps-run-egress"))
if np:
    s = np["spec"]
    if s["podSelector"] != {"matchLabels": {"rd-iroha3/role": "aps-run", "rd/egress-locked": "true"}} or s["policyTypes"] != ["Egress"]:
        bad.append("aps-run-egress: selector role=aps-run + egress-locked, Egress only")
    gw = lambda q: {"namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": f"rd-iroha3-{q}"}}, "podSelector": {"matchLabels": {"rd-iroha3/role": "gateway"}}}
    want_eg = [
        {"to": [{"namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": "kube-system"}}, "podSelector": {"matchLabels": {"k8s-app": "kube-dns"}}}],
         "ports": [{"protocol": "UDP", "port": 53}, {"protocol": "TCP", "port": 53}]},
        {"to": [gw(q) for q in ("bi", "bank-a", "bank-b")], "ports": [{"protocol": "TCP", "port": 8443}]},
        {"to": [{"ipBlock": {"cidr": f"{bankc_ip}/32"}}], "ports": [{"protocol": "TCP", "port": 8443}]},
    ]
    if s.get("egress") != want_eg:
        bad.append(f"aps-run-egress: DNS + the 3 c1 gateways :8443 + bank-c gateway-lb /32 :8443 only: {json.dumps(s.get('egress'))}")
if bad:
    print("\n".join(f"FAIL: aps-run: {b}" for b in bad), file=sys.stderr)
    sys.exit(1)
print(f"ok:   aps-run {name}: {len(docs)} objects match")
