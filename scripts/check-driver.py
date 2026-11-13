#!/usr/bin/env python3
"""Check rendered S17 driver manifests on stdin. Usage: check-driver.py <party> <digest> <hash8> <chain-id> [tls [<remote /32>...] [gw:<party>=<ip>...]] [mint:<max_rd>:<max_dfabi>] [aps:<pools.json>]
(mint:… = rendered with --mint-enabled: the BI driver enables POST /mint; caps in the [auditor] table, parties from accounts.json;
gw:<party>=<ip> = rendered with --remote-gw (bank-c): [tls.resolve] host -> ip:8443 and the same ip as a /32 ipBlock in driver-egress;
aps:<pools.json> = rendered with --aps --aps-pools <pools.json> (needs tls): coordinator driver at BI, coordinator_url at the banks; for BI gw:bank-c=<ip> is the bank-c gateway-lb address, NOT a [tls.resolve] entry)"""
import json
import sys
import tomllib

import yaml

party, digest, h8, chain = sys.argv[1:5]
mint = next((a for a in sys.argv[5:] if a.startswith("mint:")), None)
aps = next((a[4:] for a in sys.argv[5:] if a.startswith("aps:")), None)  # pools.json given to --aps-pools
args5 = [a for a in sys.argv[5:] if not a.startswith(("mint:", "aps:"))]
tlsmode = bool(args5) and args5[0] == "tls"  # rendered with --audit-tls (iroha3 S13 transport A)
gw = dict(a[3:].split("=") for a in args5[1:] if a.startswith("gw:")) if tlsmode else {}  # --remote-gw party=ip (bank-c: gateways of cluster 1)
remote = [a for a in args5[1:] if not a.startswith("gw:")] if tlsmode else []  # --remote-gw-cidr values (gateways on the OTHER cluster, ipBlock TCP 8443)
remote_all = remote + [f"{gw[q]}/32" for q in ("bi", "bank-a", "bank-b") if q in gw]  # the NP /32s derived from --remote-gw come after the explicit ones
bankc_gw = gw.pop("bank-c", None) if party == "bi" else None  # BI --aps only: the gateway-lb of bank-c (sidecar upstream + a /32 in driver-egress), never a [tls.resolve] entry
if bankc_gw:
    remote_all.append(f"{bankc_gw}/32")
ENVOY = "envoyproxy/envoy@sha256:b1f389c3a6148e85e9de364cb867aa2e5802153abb37ad80f1f2241d693da32a"  # the gateways' pinned envoy (deploy/aps-run/render.py)
COORD_URL = "https://gateway.rd-iroha3-bi.svc.cluster.local:8443"
ns = f"rd-iroha3-{party}"
docs = [d for d in yaml.safe_load_all(sys.stdin.read()) if d]
by = {(d["kind"], d["metadata"]["name"]): d for d in docs}
bad = []


def need(kind, name):
    d = by.get((kind, name))
    if d is None:
        bad.append(f"missing {kind} {name}")
    return d


want_n = (6 if tlsmode else 5) + (1 + (party == "bi") if aps is not None else 0)
if aps and not tlsmode:
    bad.append("--aps needs --audit-tls (the coordinator and the party drivers talk through the gateways)")
if len(docs) != want_n:
    bad.append(f"want exactly {want_n} objects (ConfigMap driver-config, {'ConfigMap gateway-server-cas, ' if tlsmode else ''}{'ConfigMap aps-pools, ' if aps else ''}{'ConfigMap driver-gw-envoy, ' if aps and party == 'bi' else ''}Deployment, Service, NetworkPolicy{' x2 (ingress + egress)' if tlsmode else ''}), got {len(docs)}: {sorted(by)}")
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
            "chain": chain, "network_id_file": "/genesis/genesis.expected_hash", "client_toml": "/client/client.toml",
            "peers_json": "/config/peers.json", "key_dir": "/keys", "fee_asset": "6TEAJqbb8oEPmLncoNiMRbLEK6tw",
        }
        for k, v in want.items():
            if cfg.get(k) != v:
                bad.append(f"rd-dfabi.toml {k} = {cfg.get(k)!r}, want {v!r}")
        if cfg.get("assets") != {"rd": "7onbjg2gRXveoAAUFsohCZyGW98t", "dfabi": "4mBWK1JCwQdHLDPpuVKc56eLsXka"}:
            bad.append(f"assets must be the Base58 definition ids: {cfg.get('assets')}")
        if tlsmode and party == "bank-c" and sorted(gw) != ["bank-a", "bank-b", "bi"]:
            bad.append(f"bank-c --audit-tls needs gw:<party>=<ip> for bi, bank-a and bank-b (cluster 2 cannot resolve the cluster-1 gateway names): {sorted(gw)}")
        if gw and party != "bank-c":
            bad.append("--remote-gw is for bank-c only (BI --aps: bank-c=<ip> only)")
        if aps is not None and party == "bi" and not bankc_gw:
            bad.append("BI --aps needs gw:bank-c=<ip> (the gateway-lb of bank-c: the sidecar reaches its Torii through it)")
        if aps is None and bankc_gw:
            bad.append("--remote-gw bank-c=<ip> only with --aps (BI)")
        urls = [f"https://gateway.rd-iroha3-{p}.svc.cluster.local:8443" for p in ("bi", "bank-a", "bank-b")]
        if tlsmode:
            if cfg.get("audit") != {"min_approvals": 2, "auditor_urls": urls}:
                bad.append(f"[audit] must be 2-of-3 through the three gateways {urls}: {cfg.get('audit')}")
            want_tls = {"client_cert": "/tls/client/tls.crt", "client_key": "/tls/client/tls.key", "server_ca_dir": "/tls/cas"}
            if gw:  # the in-cluster names do not resolve on the other cluster: the driver gets host -> ip:port (node-build tls_http.rs:53-55); SAN of the gateway leaf stays gateway.rd-iroha3-<p>.svc[.cluster.local]
                want_tls["resolve"] = {f"gateway.rd-iroha3-{q}.svc.cluster.local": f"{gw[q]}:8443" for q in ("bi", "bank-a", "bank-b")}
            if cfg.get("tls") != want_tls:
                bad.append(f"[tls]: {cfg.get('tls')}")
        elif "audit" in cfg or "tls" in cfg:
            bad.append("[audit]/[tls] only with --audit-tls")
        if aps is not None:
            # APS all-flows (plan 2026-11-13-04): pools_file is a TOP-LEVEL key; BI is the coordinator, the banks forward /aps/submit to the BI gateway (bank-c: the host resolves through [tls.resolve])
            if cfg.get("pools_file") != "/pools/pools.json":
                bad.append(f"rd-dfabi.toml pools_file = {cfg.get('pools_file')!r}, want '/pools/pools.json'")
            if cm["data"]["rd-dfabi.toml"].index("pools_file") > cm["data"]["rd-dfabi.toml"].index("["):
                bad.append("pools_file must be a TOP-LEVEL key (before the first table)")
            want_aps = {"coordinator": True} if party == "bi" else {"coordinator_url": COORD_URL}
            if cfg.get("aps") != want_aps:
                bad.append(f"[aps] must be {want_aps}: {cfg.get('aps')}")
            if party == "bi":  # settle() uses plain-HTTP iroha client calls to all four committee Torii: through the gw-tls sidecar on loopback 18101..18104
                if cfg.get("torii") != {q: f"http://127.0.0.1:{18101 + i}/" for i, q in enumerate(("bi", "bank-a", "bank-b", "bank-c"))}:
                    bad.append(f"BI --aps: [torii] must be the gw-tls loopback ports 18101-18104: {cfg.get('torii')}")
        elif "pools_file" in cfg or "aps" in cfg:
            bad.append("pools_file / [aps] only with --aps")
        accounts = {"bi": "ed0120bb", "bank-a": "ed0120cc", "bank-b": "ed0120dd", "bank-c": "ed0120ee"}  # fixture values of test-driver.sh (accounts.json)
        if mint:
            _, mrd, mdf = mint.split(":")
            want_aud = {"listen": "0.0.0.0:8090", "store_dir": "/audit-store", "max_rd": int(mrd), "max_dfabi": int(mdf),
                        "parties": [accounts[q] for q in ("bi", "bank-a", "bank-b", "bank-c")]}
            if party != "bi":
                bad.append("mint is for the BI driver only")
            if cfg.get("mint_enabled") is not True:
                bad.append(f"mint_enabled must be true (top-level key): {cfg.get('mint_enabled')!r}")
            if cfg.get("auditor") != want_aud:
                bad.append(f"[auditor] caps table: {cfg.get('auditor')} want {want_aud}")
            if cm["data"]["rd-dfabi.toml"].index("mint_enabled") > cm["data"]["rd-dfabi.toml"].index("["):
                bad.append("mint_enabled must be a TOP-LEVEL key (before the first table)")
        elif "mint_enabled" in cfg or "auditor" in cfg:
            bad.append("mint_enabled / [auditor] only with --mint-enabled (BI)")
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
        # --aps: the prover peaks at ~1.1 GiB RSS (reports/b-aps.md; deploy/aps-run/render.py): memory 2Gi / 3Gi, cpu as aps-run
        "requests": c["resources"]["requests"] == ({"cpu": "1", "memory": "2Gi"} if aps is not None else {"cpu": "50m", "memory": "64Mi"}),
        "limits": ("cpu" in c["resources"]["limits"] and "memory" in c["resources"]["limits"]) if aps is None else c["resources"]["limits"] == {"cpu": "2", "memory": "3Gi"},
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
    all_secret_vols = [v for v in pod["volumes"] if "secret" in v]
    secret_vols = [v for v in all_secret_vols if v["secret"]["secretName"] == f"{party}-keys"]
    others = [v for v in all_secret_vols if v["secret"]["secretName"] != f"{party}-keys"]
    if tlsmode:
        want_other = [{"name": "client-cert", "secret": {"secretName": "iroha3-client-cert", "defaultMode": 0o400,
                                                          "items": [{"key": "tls.crt", "path": "tls.crt"}, {"key": "tls.key", "path": "tls.key"}]}}]
        if others != want_other:
            bad.append(f"the only extra Secret volume must be iroha3-client-cert (tls.crt, tls.key, 0400): {others}")
        cm_mounts = {m["mountPath"]: m for m in c["volumeMounts"]}
        for mp in ("/tls/client", "/tls/cas"):
            if mp not in cm_mounts or cm_mounts[mp].get("readOnly") is not True:
                bad.append(f"mount {mp} must be read-only")
        if vols.get("server-cas", {}).get("configMap", {}).get("name") != "gateway-server-cas":
            bad.append("server-cas volume must be ConfigMap gateway-server-cas")
    elif others:
        bad.append(f"the only Secret volume must be {party}-keys: {all_secret_vols}")
    if len(secret_vols) != 1:
        bad.append(f"the Secret volume {party}-keys must be present exactly once: {secret_vols}")
    else:
        sv = secret_vols[0]["secret"]
        if sorted(i["key"] for i in sv.get("items", [])) != sorted([f"{party}.seed", f"{party}.note", "client.toml"]) or sv.get("defaultMode") != 0o400:
            bad.append(f"{party}-keys must project exactly {party}.seed, {party}.note, client.toml with mode 0400: {sv}")
    if any("bi-auditor-key" in json.dumps(v) or "auditor" in json.dumps(v) for v in pod["volumes"]):
        bad.append("the auditor key must never be mounted")
    mounts = {m["mountPath"]: m for m in c["volumeMounts"]}
    # upstream iroha_config_base/src/toml.rs regular_file_metadata uses symlink_metadata and REFUSES a symlink: a Secret volume file is a symlink (..data/<file>), so client.toml
    # must be a subPath mount (a bind mount of the real file). Found live: GET /balance -> 502 "Configuration source is not a regular file".
    cmounts = [m for m in c["volumeMounts"] if m["mountPath"] == "/client/client.toml"]
    if len(cmounts) != 1 or cmounts[0].get("subPath") != "client.toml" or cmounts[0].get("name") != "keys" or cmounts[0].get("readOnly") is not True:
        bad.append(f"client.toml must be a read-only subPath mount of volume keys at /client/client.toml (a Secret volume file is a symlink and iroha refuses it): {cmounts}")
    for path in ("/keys", "/config", "/genesis"):
        if path not in mounts or mounts[path].get("readOnly") is not True:
            bad.append(f"volume mount {path} must exist and be readOnly")
    if vols.get("genesis", {}).get("configMap", {}).get("name") != f"genesis-{h8}":
        bad.append(f"genesis volume must be ConfigMap genesis-{h8}")
    if vols.get("config", {}).get("configMap", {}).get("name") != "driver-config":
        bad.append("config volume must be ConfigMap driver-config")
    inits = pod.get("initContainers", [])
    if aps is None:
        if inits or "pools" in vols or "aps-pools" in vols or "/pools" in mounts:
            bad.append(f"initContainers / pools volumes only with --aps: {[i['name'] for i in inits]}")
    else:
        # ConfigMap aps-pools is read-only but settle() rewrites pools_file in place (pools.rs update: lock file + rename, receipts dir beside it): an init container copies it into the
        # emptyDir /pools, and pools_file points there.
        if vols.get("aps-pools") != {"name": "aps-pools", "configMap": {"name": "aps-pools"}} or "emptyDir" not in vols.get("pools", {}):
            bad.append(f"volumes aps-pools (ConfigMap aps-pools) and pools (emptyDir) are required: {vols.get('aps-pools')} {vols.get('pools')}")
        seed = [i for i in inits if i["name"] == "pools-seed"]
        if len(seed) != 1 or seed[0].get("image") != c["image"] or "restartPolicy" in seed[0] or "cp /aps-pools/pools.json /pools/pools.json" not in json.dumps(seed[0].get("command")) \
                or {m["mountPath"]: m.get("readOnly", False) for m in seed[0].get("volumeMounts", [])} != {"/aps-pools": True, "/pools": False}:
            bad.append(f"initContainer pools-seed (driver image, copies /aps-pools/pools.json to /pools/pools.json, /aps-pools read-only): {seed}")
        if mounts.get("/pools", {}).get("name") != "pools" or mounts["/pools"].get("readOnly"):
            bad.append("driver mount /pools (volume pools) must be writable")
        sc = [i for i in inits if i["name"] == "gw-tls"]
        if party == "bi":
            if len(sc) != 1 or sc[0].get("restartPolicy") != "Always" or sc[0].get("image") != ENVOY:
                bad.append(f"BI --aps: initContainer gw-tls must be a native sidecar (restartPolicy Always) of the pinned envoy image: {sc}")
            else:
                if [i["name"] for i in inits] != ["pools-seed", "gw-tls"]:
                    bad.append(f"BI --aps: initContainers must be pools-seed then gw-tls: {[i['name'] for i in inits]}")
                smounts = {m["mountPath"]: m for m in sc[0]["volumeMounts"]}
                for mp in ("/config", "/server-cas", "/client"):
                    if mp not in smounts or smounts[mp].get("readOnly") is not True:
                        bad.append(f"gw-tls mount {mp} must be read-only")
                if {m["name"] for m in sc[0]["volumeMounts"]} != {"envoy-config", "server-cas", "client-cert", "tmp"}:
                    bad.append(f"gw-tls mounts: {sc[0]['volumeMounts']}")
                if vols.get("envoy-config") != {"name": "envoy-config", "configMap": {"name": "driver-gw-envoy"}} or "emptyDir" not in vols.get("tmp", {}):
                    bad.append("gw-tls needs volumes envoy-config (ConfigMap driver-gw-envoy) and tmp (emptyDir)")
                s = sc[0]["securityContext"]
                if not (s["allowPrivilegeEscalation"] is False and s["readOnlyRootFilesystem"] is True and s["capabilities"] == {"drop": ["ALL"]}):
                    bad.append(f"gw-tls container hardening: {s}")
        elif sc:
            bad.append("gw-tls sidecar is for the BI coordinator only")

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

# R17 end step: the key-holding driver gets ONE narrow Egress policy `driver-egress`, ALWAYS (the live D2 shape too). Destinations: the OWN peer's Torii on 8080 only (every live
# server route uses client.toml = own Torii; the [torii] table's other parties are read only by the CLI APS paths aps.rs:625/735, not by the driver pod), DNS by selector, and WITH --audit-tls the gateways on 8443 (same-cluster namespaces by selector; the other cluster's gateways only as explicit /32 --remote-gw-cidr).
eg = by.get(("NetworkPolicy", "driver-egress"))
if eg is None:
    bad.append("missing NetworkPolicy driver-egress")
else:
    sp = eg["spec"]
    c1 = ("bi", "bank-a", "bank-b")
    same = c1 if party in c1 else ("bank-c",)
    nsel = lambda q, role: {"namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": f"rd-iroha3-{q}"}}, "podSelector": {"matchLabels": {"rd-iroha3/role": role}}}
    want_eg = [
        {"to": [{"namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": "kube-system"}},
                 "podSelector": {"matchLabels": {"k8s-app": "kube-dns"}}}],
         "ports": [{"protocol": "UDP", "port": 53}, {"protocol": "TCP", "port": 53}]},
        {"to": [{"podSelector": {"matchLabels": {"rd-iroha3/role": "peer", "rd-iroha3/party": party}}}], "ports": [{"protocol": "TCP", "port": 8080}]},
    ]
    if tlsmode:
        want_eg.append({"to": [nsel(q, "gateway") for q in same] + [{"ipBlock": {"cidr": c}} for c in remote_all], "ports": [{"protocol": "TCP", "port": 8443}]})
    # BI --aps: remote_all already holds bank-c's /32 (from --remote-gw bank-c=<ip>, the same ip as the sidecar upstream), so the NP and the sidecar cannot drift
    if sp.get("podSelector") != {"matchLabels": {"rd-iroha3/role": "driver"}} or sp.get("policyTypes") != ["Egress"] or "ingress" in sp:
        bad.append(f"driver-egress: selector role=driver, Egress only: {sp.get('podSelector')} {sp.get('policyTypes')}")
    if sp.get("egress") != want_eg:
        bad.append(f"driver-egress rules differ from the intended destinations: {json.dumps(sp.get('egress'))}")
    if any(not c.endswith("/32") for c in remote_all):
        bad.append("remote gateway CIDRs must be /32")

ap = by.get(("ConfigMap", "aps-pools"))
if aps is None:
    if ap is not None or ("ConfigMap", "driver-gw-envoy") in by:
        bad.append("ConfigMaps aps-pools / driver-gw-envoy only with --aps")
else:
    want_pools = json.load(open(aps))
    if ap is None:
        bad.append("missing ConfigMap aps-pools")
    elif set(ap["data"]) != {"pools.json"}:
        bad.append(f"aps-pools keys: {sorted(ap['data'])}, want ['pools.json']")
    else:
        got = json.loads(ap["data"]["pools.json"])
        # node-build driver/src/pools.rs PoolFile / PoolRecord: exactly {rd, dfabi}, each {pool_id, route, policy, governance, origin, bundles}; the values are the operator's public input, never invented here
        rec = {"pool_id", "route", "policy", "governance", "origin", "bundles"}
        if got != want_pools or set(got) != {"rd", "dfabi"} or any(set(v) != rec for v in got.values()):
            bad.append(f"aps-pools pools.json must be the given public pools file with exactly rd/dfabi records of {sorted(rec)}: {sorted(got)}")
    gwe = by.get(("ConfigMap", "driver-gw-envoy"))
    if party == "bi":
        if gwe is None or set(gwe["data"]) != {"envoy.yaml"}:
            bad.append("BI --aps: missing ConfigMap driver-gw-envoy (envoy.yaml)")
        else:
            env = json.loads(gwe["data"]["envoy.yaml"])["static_resources"]
            lis = {l["name"]: l for l in env["listeners"]}
            cls = {c["name"]: c for c in env["clusters"]}
            addr = lambda c: c["load_assignment"]["endpoints"][0]["lb_endpoints"][0]["endpoint"]["address"]["socket_address"]
            for i, q in enumerate(("bi", "bank-a", "bank-b", "bank-c")):
                host = f"gateway.rd-iroha3-{q}.svc.cluster.local"
                l, c = lis.get(f"to-{q}"), cls.get(f"gw-{q}")
                if l is None or c is None:
                    bad.append(f"gw-tls: listener to-{q} / cluster gw-{q} missing")
                    continue
                if l["address"]["socket_address"] != {"address": "127.0.0.1", "port_value": 18101 + i}:
                    bad.append(f"gw-tls: listener to-{q} must be 127.0.0.1:{18101 + i} (loopback only): {l['address']}")
                rt = l["filter_chains"][0]["filters"][0]["typed_config"]["route_config"]["virtual_hosts"][0]["routes"]
                if rt != [{"match": {"prefix": "/"}, "route": {"cluster": f"gw-{q}", "timeout": "330s"}}]:
                    bad.append(f"gw-tls: listener to-{q} route: {rt}")
                if (addr(c), c["type"]) != (({"address": bankc_gw, "port_value": 8443}, "STATIC") if q == "bank-c" else ({"address": host, "port_value": 8443}, "STRICT_DNS")):
                    bad.append(f"gw-tls: cluster gw-{q} upstream {addr(c)} {c['type']}")
                tls = c["transport_socket"]["typed_config"]
                vc = tls["common_tls_context"]["validation_context"]
                if tls["sni"] != host or vc["trusted_ca"]["filename"] != f"/server-cas/{q}-server-ca.pem" \
                        or vc["match_typed_subject_alt_names"] != [{"san_type": "DNS", "matcher": {"exact": host}}]:
                    bad.append(f"gw-tls: cluster gw-{q} must verify the gateway server CA and the SAN {host}")
                if tls["common_tls_context"]["tls_certificates"] != [{"certificate_chain": {"filename": "/client/tls.crt"}, "private_key": {"filename": "/client/tls.key"}}]:
                    bad.append(f"gw-tls: cluster gw-{q} must present the driver client leaf (mTLS)")
            if sorted(lis) != sorted(f"to-{q}" for q in ("bi", "bank-a", "bank-b", "bank-c")):
                bad.append(f"gw-tls: listeners {sorted(lis)}")
    elif gwe is not None:
        bad.append("driver-gw-envoy is for the BI coordinator only")

cas = by.get(("ConfigMap", "gateway-server-cas"))
if tlsmode:
    if cas is None:
        bad.append("missing ConfigMap gateway-server-cas")
    elif sorted(cas["data"]) != sorted(f"{p}-server-ca.pem" for p in ("bi", "bank-a", "bank-b", "bank-c")) or any("PRIVATE KEY" in v or "BEGIN CERTIFICATE" not in v for v in cas["data"].values()):
        bad.append("gateway-server-cas must hold exactly the 4 public <party>-server-ca.pem certificates")
elif cas is not None:
    bad.append("gateway-server-cas only with --audit-tls")
for b in bad:
    print(f"FAIL: {party}: {b}", file=sys.stderr)
print(f"{'FAIL' if bad else 'ok:  '} {party}: {len(docs)} objects")
sys.exit(1 if bad else 0)
