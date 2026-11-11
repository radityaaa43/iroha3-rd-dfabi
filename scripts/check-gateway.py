#!/usr/bin/env python3
"""Check rendered S14 gateway manifests on stdin. Usage: check-gateway.py <party> <cluster 1|2> <envoy-image> <opa-image>"""
import json
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


want = {("ConfigMap", "gateway-envoy"), ("ConfigMap", "gateway-opa"), ("Deployment", "gateway"), ("Service", "gateway"),
        ("NetworkPolicy", "gateway-ingress")}
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
for banned in ("nodeSelector", "nodeName", "affinity", "priorityClassName", "hostNetwork", "65536", "max_request_bytes", "with_request_body", "sink", ":8081"):
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
                driver_paths = ["/settle-grant", "/dvp-native"] + (["/mint"] if party == "bi" else [])
                # S12/S13 transport A: the party's OWN auditor is reached through its gateway (/keys, /approve; /records on BI only)
                auditor_exact = ["/keys", "/approve"] + (["/records"] if party == "bi" else [])
                want_routes = [({"path": p}, "driver") for p in driver_paths] + [({"path": p}, "auditor") for p in auditor_exact]
                if party == "bi":
                    want_routes.append(({"prefix": "/records/"}, "auditor"))
                got = [(r["match"], r["route"]["cluster"]) for r in routes[:-1]]
                if got != want_routes:
                    bad.append(f"envoy: routes before the default must be exactly {want_routes} (exact paths, in order), got {got}")
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
        if opa["services"] != {"bundle-server": {"url": f"http://bundle-server.rd-zeto-{party}.svc.cluster.local:8080"}}:
            bad.append(f"opa: services must be the same party's bundle-server only, got {opa['services']}")
        if opa["plugins"]["envoy_ext_authz_grpc"]["addr"] != "127.0.0.1:9191":
            bad.append(f"opa: ext_authz addr {opa['plugins']['envoy_ext_authz_grpc']['addr']}")
        if not opa.get("keys"):
            bad.append("opa: public keys block missing")
        if opa.get("decision_logs") != {"console": True} or opa.get("status") != {"console": True}:
            bad.append("opa: decision_logs and status must be console only")

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
    sc = pod["securityContext"]
    if not (sc.get("runAsNonRoot") is True and sc.get("runAsUser") == 10001 and sc["seccompProfile"] == {"type": "RuntimeDefault"}):
        bad.append(f"gateway: pod securityContext {sc}")
    ctrs = {c["name"]: c for c in pod["containers"]}
    if set(ctrs) != {"envoy", "opa"}:
        bad.append(f"gateway: containers {sorted(ctrs)}, want envoy, opa")
    else:
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
        for need_arg in ("run", "--server", "--addr=localhost:8181", "--config-file=/config/opa.yaml", f"--set=labels.gateway=gateway-{party}",
                         "--set=bundles.bi.resource=bi/latest.tar.gz", "--set=bundles.bank.resource=bank/latest.tar.gz", f"--set=bundles.bank.signing.keyid={party}"):
            if need_arg not in a:
                bad.append(f"gateway opa: arg {need_arg} missing")
    vols = {v["name"]: v for v in pod["volumes"]}
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
