#!/usr/bin/env python3
"""Check rendered S14 gateway manifests on stdin. Usage: check-gateway.py <party> <cluster 1|2> <envoy-image> <opa-image>"""
import json
import os
import sys

import yaml

party, cluster, envoy_img, opa_img = sys.argv[1:5]
lbmode = len(sys.argv) > 5 and sys.argv[5] == "lb"  # cluster 1 WITH the cross-cluster LB (--lb-acl/--lb-range)
ns = f"rd-iroha3-{party}"
docs = [d for d in yaml.safe_load_all(sys.stdin.read()) if d]
by = {(d["kind"], d["metadata"]["name"]): d for d in docs}
bad = []


def need(kind, name):
    d = by.get((kind, name))
    if d is None:
        bad.append(f"missing {kind} {name}")
    return d


want = {("ConfigMap", "gateway-envoy"), ("ConfigMap", "gateway-opa"), ("ConfigMap", "gateway-policy"), ("Deployment", "gateway"), ("Service", "gateway"),
        ("NetworkPolicy", "gateway-ingress"), ("NetworkPolicy", "gateway-egress")}
want |= {("Service", "gateway-ext")} if cluster == "1" else set()
want |= {("Service", "gateway-lb")} if (cluster == "2" or lbmode) else set()
if set(by) != want or len(docs) != len(want):
    bad.append(f"objects: want exactly {sorted(want)}, got {sorted(by)} ({len(docs)} documents)")
for (k, n), d in by.items():
    if d["metadata"].get("namespace") != ns:
        bad.append(f"{k} {n} is in namespace {d['metadata'].get('namespace')}, want {ns}")
    if d["metadata"].get("labels", {}).get("app.kubernetes.io/part-of") != "rd-iroha3":
        bad.append(f"{k} {n}: label part-of=rd-iroha3 missing")
if any(k == "Secret" for k, _ in by):
    bad.append("a Secret must never be rendered (the server cert and the client CA are created outside the render)")
flat = json.dumps(docs)
for banned in ("nodeSelector", "nodeName", "nodeAffinity", "priorityClassName", "hostNetwork", "65536", "max_request_bytes", "with_request_body", "sink", ":8081"):
    if banned in flat:
        bad.append(f"rendered objects must not contain {banned!r}")

cm = need("ConfigMap", "gateway-envoy")
if cm:
    if set(cm["data"]) != {"envoy.yaml"}:
        bad.append(f"gateway-envoy keys: {sorted(cm['data'])}")
    else:
        env = yaml.safe_load(cm["data"]["envoy.yaml"])
        sr = env["static_resources"]
        lst = sr["listeners"]
        if len(lst) != 1 or lst[0]["address"]["socket_address"] != {"address": "0.0.0.0", "port_value": 8443}:
            bad.append(f"envoy: want one listener on 0.0.0.0:8443, got {[l['address'] for l in lst]}")
        else:
            fc = lst[0]["filter_chains"][0]
            ts = fc["transport_socket"]["typed_config"]
            if ts.get("require_client_certificate") is not True:
                bad.append("envoy: require_client_certificate must be true (mTLS)")
            cs = ts["common_tls_context"]
            if cs["tls_params"]["tls_minimum_protocol_version"] != "TLSv1_2":
                bad.append("envoy: minimum TLS version must be TLSv1_2")
            if cs["tls_certificates"][0]["certificate_chain"]["filename"] != "/mtls/tls.crt" or cs["tls_certificates"][0]["private_key"]["filename"] != "/mtls/tls.key":
                bad.append("envoy: server cert/key must be /mtls/tls.crt and /mtls/tls.key")
            if cs["validation_context"]["trusted_ca"]["filename"] != "/client-ca/ca.crt":
                bad.append("envoy: client CA must be /client-ca/ca.crt")
            hcm = fc["filters"][0]["typed_config"]
            if hcm.get("forward_client_cert_details") != "SANITIZE_SET" or hcm.get("set_current_client_cert_details") != {"cert": True, "subject": True}:
                bad.append(f"envoy: XFCC must be SANITIZE_SET with {{cert, subject}}, got {hcm.get('forward_client_cert_details')} {hcm.get('set_current_client_cert_details')}")
            http_filters = hcm["http_filters"]
            if [f["name"] for f in http_filters] != ["envoy.filters.http.ext_authz", "envoy.filters.http.router"]:
                bad.append(f"envoy: filters must be ext_authz then router, got {[f['name'] for f in http_filters]}")
            else:
                ea = http_filters[0]["typed_config"]
                if ea.get("failure_mode_allow") is not False:
                    bad.append("envoy: ext_authz failure_mode_allow must be false (fail closed)")
                if ea["grpc_service"]["envoy_grpc"]["cluster_name"] != "opa":
                    bad.append("envoy: ext_authz must call the opa cluster")
            vh = hcm["route_config"]["virtual_hosts"]
            if len(vh) != 1 or vh[0]["domains"] != ["*"]:
                bad.append("envoy: want one virtual host for *")
            else:
                routes = vh[0]["routes"]
                driver_paths = ["/settle-grant", "/dvp-native", "/transfer"] + (["/mint"] if party == "bi" else [])
                # S12/S13 transport A: the party's OWN auditor is reached through its gateway (/keys, /approve; /records on BI only)
                auditor_exact = ["/keys", "/approve"] + (["/records"] if party == "bi" else [])
                get_only = [{"name": ":method", "string_match": {"exact": "GET"}}]
                # window B reads served by the party's OWN driver: exact path + GET only (OPA decides who may call)
                driver_reads = [({"path": "/healthz", "headers": get_only}, "driver"),
                                ({"prefix": "/tx/", "headers": get_only}, "driver"),
                                ({"path": "/balance", "headers": get_only}, "driver")]
                # APS all-flows (plan 2026-11-13-04, OPA rows 16-18): the whole /aps/ prefix goes to the party's OWN driver (a bundle takes ~100-200 s: timeout 600 s, checked below)
                aps = [({"prefix": "/aps/"}, "driver")]
                want_routes = [({"path": p}, "driver") for p in driver_paths] + driver_reads + aps + [({"path": p}, "auditor") for p in auditor_exact]
                if party == "bi":
                    want_routes.append(({"prefix": "/records/"}, "auditor"))
                got = [(r["match"], r["route"]["cluster"]) for r in routes[:-1]]
                if got != want_routes:
                    bad.append(f"envoy: routes before the default must be exactly {want_routes} (exact paths, in order), got {got}")
                for r in routes[:-1]:
                    if r["match"] == {"prefix": "/aps/"} and (r["route"].get("timeout") != "600s" or r["route"].get("idle_timeout") != "600s"):
                        bad.append(f"envoy: the /aps/ route timeout and idle_timeout must both be 600s (the default stream idle timeout is 5 min), got {r['route'].get('timeout')} {r['route'].get('idle_timeout')}")
                last = routes[-1]
                if last["match"] != {"prefix": "/"} or last["route"]["cluster"] != "torii":
                    bad.append(f"envoy: last route must be prefix / -> torii, got {last['match']} {last['route']['cluster']}")
                for r in routes:
                    ctx = r["typed_per_filter_config"]["envoy.filters.http.ext_authz"]["check_settings"]["context_extensions"]
                    if ctx != {"target": "iroha3", "node": party}:
                        bad.append(f"envoy: context_extensions must be target=iroha3 node={party}, got {ctx}")
                    if "rewrite" in json.dumps(r["route"]) or "prefix_rewrite" in r["route"]:
                        bad.append("envoy: paths must be forwarded unchanged (the client signature covers the path)")
                    if r["route"].get("timeout") in (None, "0s"):
                        bad.append("envoy: every route needs an explicit timeout")
        cl = {c["name"]: c for c in sr["clusters"]}
        if set(cl) != {"torii", "driver", "auditor", "opa"}:
            bad.append(f"envoy: clusters {sorted(cl)}, want torii, driver, auditor, opa")
        else:
            def target(c):
                s = c["load_assignment"]["endpoints"][0]["lb_endpoints"][0]["endpoint"]["address"]["socket_address"]
                return s["address"], s["port_value"]
            if target(cl["torii"]) != (f"{party}-0.{party}.{ns}.svc.cluster.local", 8080):
                bad.append(f"envoy: torii cluster -> {target(cl['torii'])}")
            if target(cl["driver"]) != (f"driver.{ns}.svc.cluster.local", 8091):
                bad.append(f"envoy: driver cluster -> {target(cl['driver'])}")
            if target(cl["auditor"]) != (f"auditor.{ns}.svc.cluster.local", 8090):
                bad.append(f"envoy: auditor cluster -> {target(cl['auditor'])}")
            if target(cl["opa"]) != ("127.0.0.1", 9191):
                bad.append(f"envoy: opa cluster -> {target(cl['opa'])}")
            if any(cl[c]["type"] != "STRICT_DNS" for c in ("torii", "driver", "auditor")):
                bad.append("envoy: torii, driver and auditor clusters must be STRICT_DNS (other pods)")
        if env["admin"]["address"]["socket_address"] != {"address": "127.0.0.1", "port_value": 9901}:
            bad.append("envoy: admin must listen on 127.0.0.1:9901 only")

cm = need("ConfigMap", "gateway-opa")
if cm:
    if set(cm["data"]) != {"opa.yaml"}:
        bad.append(f"gateway-opa keys: {sorted(cm['data'])}")
    else:
        text = cm["data"]["opa.yaml"]
        opa = yaml.safe_load(text)
        if "PRIVATE KEY" in text:
            bad.append("opa.yaml holds a private key")
        # iroha3's OWN policy (user 2026-11-13): no bundle service, no bundle, no signing key; the files come from ConfigMap gateway-policy.
        want_opa = {"plugins": {"envoy_ext_authz_grpc": {"addr": "127.0.0.1:9191", "path": "iroha3/allow", "dry-run": False}},
                    "decision_logs": {"console": True}}
        if opa != want_opa:
            bad.append(f"opa.yaml must be exactly {want_opa} (no services, bundles or keys), got {opa}")

# The policy files are the reviewed ones in deploy/gateway/policy, byte for byte (the gateway's OPA loads them as given).
POLICY = ("iroha3.rego", "authz.rego", "log.rego", "data.json")
pdir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "deploy", "gateway", "policy")
pc = need("ConfigMap", "gateway-policy")
if pc:
    if set(pc["data"]) != set(POLICY):
        bad.append(f"gateway-policy keys: {sorted(pc['data'])}, want {sorted(POLICY)}")
    else:
        for f in POLICY:
            if pc["data"][f] != open(os.path.join(pdir, f)).read():
                bad.append(f"gateway-policy {f} differs from deploy/gateway/policy/{f}")
        ca = json.loads(pc["data"]["data.json"])["iroha3_config"]["iroha3_ca"]
        if {k: sorted(v) for k, v in ca.items()} != {k: ["bank-a", "bank-b", "bank-c", "bi"] for k in ("lensa", "role")}:
            bad.append("gateway-policy data.json: iroha3_ca must hold exactly lensa and role CAs of bi, bank-a, bank-b, bank-c")
        if any("PRIVATE" in pem or not pem.startswith("-----BEGIN CERTIFICATE-----") for v in ca.values() for pem in v.values()):
            bad.append("gateway-policy data.json: public CA certificates only")
        if "package iroha3\n" not in pc["data"]["iroha3.rego"]:
            bad.append("gateway-policy iroha3.rego must be package iroha3 (decision path iroha3/allow)")

dep = need("Deployment", "gateway")
if dep:
    role = {"app.kubernetes.io/part-of": "rd-iroha3", "app.kubernetes.io/name": "gateway", "rd-iroha3/party": party, "rd-iroha3/role": "gateway"}
    if dep["spec"]["selector"]["matchLabels"] != role or dep["spec"]["template"]["metadata"]["labels"] != role:
        bad.append(f"gateway: pod labels must be {role} (peers-torii and driver-ingress admit role=gateway)")
    if dep["spec"].get("replicas") != 1 or dep["spec"]["strategy"] != {"type": "Recreate"}:
        bad.append("gateway: replicas 1, strategy Recreate")
    pod = dep["spec"]["template"]["spec"]
    if pod.get("automountServiceAccountToken") is not False:
        bad.append("gateway: automountServiceAccountToken must be false")
    # R22 (co-location): PREFERRED (never required: a gateway must still schedule when nodes are scarce) spread of gateways across workers and rd-iroha3 namespaces
    if pod.get("affinity") != {"podAntiAffinity": {"preferredDuringSchedulingIgnoredDuringExecution": [{"weight": 100, "podAffinityTerm": {
            "topologyKey": "kubernetes.io/hostname",
            "labelSelector": {"matchLabels": {"app.kubernetes.io/part-of": "rd-iroha3", "rd-iroha3/role": "gateway"}},
            "namespaceSelector": {"matchLabels": {"app.kubernetes.io/part-of": "rd-iroha3"}}}}]}}:
        bad.append(f"gateway: affinity must be exactly one PREFERRED hostname anti-affinity term against role=gateway pods of the rd-iroha3 namespaces: {pod.get('affinity')}")
    sc = pod["securityContext"]
    if not (sc.get("runAsNonRoot") is True and sc.get("runAsUser") == 10001 and sc["seccompProfile"] == {"type": "RuntimeDefault"}):
        bad.append(f"gateway: pod securityContext {sc}")
    ctrs = {c["name"]: c for c in pod["containers"]}
    if set(ctrs) != {"envoy", "opa"}:
        bad.append(f"gateway: containers {sorted(ctrs)}, want envoy, opa")
    else:
        if pod.get("imagePullSecrets") != [{"name": "ghcr-pull"}]:
            bad.append("gateway: pod spec must carry imagePullSecrets ghcr-pull (every rd-iroha3-* pod spec does: the packages may go private)")
        if ctrs["envoy"]["image"] != envoy_img or ctrs["opa"]["image"] != opa_img:
            bad.append("gateway: images must be exactly the digests given")
        for n, c in ctrs.items():
            s = c["securityContext"]
            if not (s["allowPrivilegeEscalation"] is False and s["readOnlyRootFilesystem"] is True and s["capabilities"] == {"drop": ["ALL"]}):
                bad.append(f"gateway {n}: container securityContext {s}")
            if "limits" not in c["resources"] or "requests" not in c["resources"]:
                bad.append(f"gateway {n}: requests and limits are required")
            for vm in c["volumeMounts"]:
                if vm["name"] != "tmp" and vm.get("readOnly") is not True:
                    bad.append(f"gateway {n}: mount {vm['name']} must be read-only")
        if ctrs["envoy"]["ports"][0]["containerPort"] != 8443:
            bad.append("gateway envoy: containerPort 8443")
        a = ctrs["opa"]["args"]
        want_args = ["run", "--server", "--addr=localhost:8181", "--diagnostic-addr=0.0.0.0:8282", "--authorization=basic",
                     "--config-file=/config/opa.yaml", f"--set=labels.gateway=gateway-{party}"] + [f"/policy/{f}" for f in POLICY]
        if a != want_args:
            bad.append(f"gateway opa: args must be exactly {want_args} (explicit files: the ConfigMap dir also holds ..data links), got {a}")
        if ctrs["opa"]["readinessProbe"]["httpGet"]["path"] != "/health?plugins":
            bad.append("gateway opa: readiness /health?plugins (no bundles to wait for)")
        if {"name": "opa-policy", "mountPath": "/policy", "readOnly": True} not in ctrs["opa"]["volumeMounts"]:
            bad.append("gateway opa: ConfigMap gateway-policy mounted read-only at /policy")
    vols = {v["name"]: v for v in pod["volumes"]}
    if vols.get("opa-policy") != {"name": "opa-policy", "configMap": {"name": "gateway-policy"}}:
        bad.append("gateway: volume opa-policy must be ConfigMap gateway-policy")
    secrets = {v["secret"]["secretName"] for v in vols.values() if "secret" in v}
    if secrets != {"gateway-server", "gateway-client-ca"}:
        bad.append(f"gateway: Secret volumes {sorted(secrets)}, want gateway-server and gateway-client-ca")

svc = need("Service", "gateway")
if svc and (svc["spec"]["type"] != "ClusterIP" or svc["spec"]["ports"][0]["port"] != 8443 or svc["spec"]["ports"][0]["targetPort"] != 8443):
    bad.append("Service gateway: ClusterIP 8443 -> 8443")
if cluster == "1":
    ext = need("Service", "gateway-ext")
    if ext and (ext["spec"]["type"] != "NodePort" or ext["spec"]["externalTrafficPolicy"] != "Cluster" or "nodePort" in ext["spec"]["ports"][0]):
        bad.append("Service gateway-ext: NodePort, externalTrafficPolicy Cluster, no fixed nodePort")
if cluster == "2" or lbmode:
    lb = need("Service", "gateway-lb")
    if lb:
        an = lb["metadata"].get("annotations", {})
        p = "service.beta.kubernetes.io/alibaba-cloud-loadbalancer-"
        if an.get(p + "acl-status") != "on" or an.get(p + "acl-type") != "white" or not an.get(p + "acl-id", "").startswith("acl-"):
            bad.append(f"Service gateway-lb: ACL annotations (on/white/acl-id) missing: {an}")
        if lb["spec"]["type"] != "LoadBalancer" or not lb["spec"].get("loadBalancerSourceRanges"):
            bad.append("Service gateway-lb: LoadBalancer with loadBalancerSourceRanges")
        # Same as the other CLBs on this platform (clb-etp-local gotcha, fabric arma lb-1..4): externalTrafficPolicy Cluster + ENI backends.
        if lb["spec"].get("externalTrafficPolicy") != "Cluster":
            bad.append(f"Service gateway-lb: externalTrafficPolicy must be Cluster, got {lb['spec'].get('externalTrafficPolicy')}")
        if an.get("service.beta.kubernetes.io/backend-type") != "eni":
            bad.append("Service gateway-lb: annotation service.beta.kubernetes.io/backend-type: eni missing")

# R17 precondition of the apply: the key-holding gateway (tls.key) gets its own narrow Egress policy.
ge = need("NetworkPolicy", "gateway-egress")
if ge:
    sp = ge["spec"]
    peer = {"podSelector": {"matchLabels": {"rd-iroha3/role": "peer", "rd-iroha3/party": party}}}
    want_eg = [
        {"to": [{"namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": "kube-system"}},
                 "podSelector": {"matchLabels": {"k8s-app": "kube-dns"}}}],
         "ports": [{"protocol": "UDP", "port": 53}, {"protocol": "TCP", "port": 53}]},
        {"to": [peer], "ports": [{"protocol": "TCP", "port": 8080}]},
        {"to": [{"podSelector": {"matchLabels": {"rd-iroha3/role": "driver"}}}], "ports": [{"protocol": "TCP", "port": 8091}]},
        {"to": [{"podSelector": {"matchLabels": {"rd-iroha3/role": "auditor"}}}], "ports": [{"protocol": "TCP", "port": 8090}]},
    ]  # no bundle-server: the policy is local (ConfigMap gateway-policy), nothing leaves for rd-zeto-<party>
    if sp.get("podSelector") != {"matchLabels": {"rd-iroha3/role": "gateway"}} or sp.get("policyTypes") != ["Egress"] or "ingress" in sp:
        bad.append(f"NetworkPolicy gateway-egress: selector role=gateway, Egress only: {sp.get('podSelector')} {sp.get('policyTypes')}")
    if sp.get("egress") != want_eg:
        bad.append(f"NetworkPolicy gateway-egress: DNS, own Torii 8080, own driver 8091, own auditor 8090 only: {json.dumps(sp.get('egress'))}")
    if "ipBlock" in json.dumps(sp) or "8081" in json.dumps(sp):
        bad.append("NetworkPolicy gateway-egress: no ipBlock, never the 8081 sink")

np = need("NetworkPolicy", "gateway-ingress")
if np:
    if np["spec"]["podSelector"] != {"matchLabels": {"app.kubernetes.io/name": "gateway"}} or np["spec"]["policyTypes"] != ["Ingress"]:
        bad.append("NetworkPolicy gateway-ingress: selector name=gateway, Ingress only")
    if np["spec"]["ingress"] != [{"ports": [{"protocol": "TCP", "port": 8443}]}]:
        bad.append(f"NetworkPolicy gateway-ingress: TCP 8443 with NO from list (mTLS + OPA are the control), got {np['spec']['ingress']}")

if bad:
    print("\n".join(f"FAIL: {party}: {b}" for b in bad), file=sys.stderr)
    sys.exit(1)
print(f"ok:   {party} (cluster {cluster}): {len(docs)} objects match")
