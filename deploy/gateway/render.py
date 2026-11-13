"""Render the S14 gateway manifests (see render.sh). Output: YAML stream of JSON documents, deterministic."""
import json
import os
import sys

import yaml

party, cluster, envoy_image, opa_image, acl = sys.argv[1:6]
ranges = sys.argv[6:]
ns = f"rd-iroha3-{party}"


def refuse(message):
    print(f"render.sh: {message}", file=sys.stderr)
    sys.exit(2)


# --- the gateway's OWN OPA (user 2026-11-13: iroha3 policy separated from the besu combined bundle). The policy, its tests and
# the public CA data live in deploy/gateway/policy; OPA loads those files from ConfigMap gateway-policy: no bundle service, no
# bundle-signing key, nothing pulled from rd-zeto-<party>. Decision path iroha3/allow; decision logs on the console.
POLICY = ("iroha3.rego", "authz.rego", "log.rego", "data.json")
pdir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "policy")
policy = {f: open(os.path.join(pdir, f)).read() for f in POLICY}
opa = {"plugins": {"envoy_ext_authz_grpc": {"addr": "127.0.0.1:9191", "path": "iroha3/allow", "dry-run": False}},
       "decision_logs": {"console": True}}

# --- envoy: mTLS listener, XFCC to OPA, forward every path unchanged to the party's Torii or driver
AUTHZ = "envoy.filters.http.ext_authz"
ctx = {"target": "iroha3", "node": party}
per_route = {AUTHZ: {"@type": "type.googleapis.com/envoy.extensions.filters.http.ext_authz.v3.ExtAuthzPerRoute",
                     "check_settings": {"context_extensions": ctx}}}
# Driver routes wait for `Applied` (client.toml status_timeout_ms 300000), so the route timeout is above 300 s.
# Exact driver paths (the code's names: driver/src/server.rs, mint.rs); `/mint` exists on the BI gateway only (BI driver).
driver_paths = ["/settle-grant", "/dvp-native", "/transfer"] + (["/mint"] if party == "bi" else [])
routes = [{"match": {"path": p}, "route": {"cluster": "driver", "timeout": "330s"}, "typed_per_filter_config": per_route}
          for p in driver_paths]
# Window B reads served by the party's OWN driver (driver/src/server.rs): exact path + GET only, anything else falls to Torii.
# /tx/ is a prefix + GET (envoy RE2 refuses a {64} regex: program size 132 > 100); the 64-hex check is OPA row 12 and the driver (tx_detail::check_hash). /tx/{64hex} and /balance are signed queries with that driver's own key; OPA (besu rego rows 9, 12, 14) decides who may call.
get_only = [{"name": ":method", "string_match": {"exact": "GET"}}]
routes += [{"match": m, "route": {"cluster": "driver", "timeout": "60s"}, "typed_per_filter_config": per_route}
           for m in ({"path": "/healthz", "headers": get_only},
                     {"prefix": "/tx/", "headers": get_only},
                     {"path": "/balance", "headers": get_only})]
# APS all-flows (plan 2026-11-13-04, OPA rows 16-18): the whole /aps/ prefix is the party's OWN driver (intent, address, leg, submit, wallet). A bundle takes ~100-200 s, so 600 s, and idle_timeout 600 s too (envoy's default stream idle timeout is 5 min); OPA decides who may call what.
routes.append({"match": {"prefix": "/aps/"}, "route": {"cluster": "driver", "timeout": "600s", "idle_timeout": "600s"}, "typed_per_filter_config": per_route})
# The party's OWN auditor (S12/S13 transport A): other parties reach it only through this gateway. The auditor's code route names:
# /keys (GET), /approve (POST; a leg approval can take a while), and on BI /records, /records/{bundle} (BI lens). Every auditor error is
# HTTP 500 by design (driver/src/auditor.rs); OPA decides who may call what.
auditor_exact = [("/keys", "60s"), ("/approve", "120s")] + ([("/records", "60s")] if party == "bi" else [])
routes += [{"match": {"path": p}, "route": {"cluster": "auditor", "timeout": to}, "typed_per_filter_config": per_route} for p, to in auditor_exact]
if party == "bi":
    routes.append({"match": {"prefix": "/records/"}, "route": {"cluster": "auditor", "timeout": "60s"}, "typed_per_filter_config": per_route})
routes.append({"match": {"prefix": "/"}, "route": {"cluster": "torii", "timeout": "60s"}, "typed_per_filter_config": per_route})


def dns_cluster(name, host, port):
    return {"name": name, "type": "STRICT_DNS", "connect_timeout": "1s", "dns_lookup_family": "V4_ONLY",
            "load_assignment": {"cluster_name": name, "endpoints": [{"lb_endpoints": [{"endpoint": {"address": {
                "socket_address": {"address": host, "port_value": port}}}}]}]}}


envoy = {
    "admin": {"address": {"socket_address": {"address": "127.0.0.1", "port_value": 9901}}},
    "static_resources": {
        "listeners": [{
            "name": "iroha3",
            "address": {"socket_address": {"address": "0.0.0.0", "port_value": 8443}},
            "filter_chains": [{
                "transport_socket": {"name": "envoy.transport_sockets.tls", "typed_config": {
                    "@type": "type.googleapis.com/envoy.extensions.transport_sockets.tls.v3.DownstreamTlsContext",
                    "require_client_certificate": True,
                    "common_tls_context": {
                        "tls_params": {"tls_minimum_protocol_version": "TLSv1_2"},
                        "alpn_protocols": ["h2", "http/1.1"],
                        "tls_certificates": [{"certificate_chain": {"filename": "/mtls/tls.crt"}, "private_key": {"filename": "/mtls/tls.key"}}],
                        "validation_context": {"trusted_ca": {"filename": "/client-ca/ca.crt"}}}}},
                "filters": [{"name": "envoy.filters.network.http_connection_manager", "typed_config": {
                    "@type": "type.googleapis.com/envoy.extensions.filters.network.http_connection_manager.v3.HttpConnectionManager",
                    "stat_prefix": "iroha3",
                    "codec_type": "AUTO",
                    # Client identity for OPA: the forwarded leaf cert + subject (`issuer` is refused by the pinned envoy,
                    # rd-fabric-x#37), so the rego verifies the leaf against the CA it expects.
                    "forward_client_cert_details": "SANITIZE_SET",
                    "set_current_client_cert_details": {"cert": True, "subject": True},
                    "route_config": {"name": "iroha3", "virtual_hosts": [{"name": "iroha3", "domains": ["*"], "routes": routes}]},
                    # No request body goes to OPA: the allowlist decides on path, method and caller; the client signature
                    # (CanonicalAccountSignature) already covers the body, and bundle/leg bodies reach 4 and 8 MiB.
                    "http_filters": [
                        {"name": AUTHZ, "typed_config": {
                            "@type": "type.googleapis.com/envoy.extensions.filters.http.ext_authz.v3.ExtAuthz",
                            "transport_api_version": "V3",
                            "failure_mode_allow": False,
                            "grpc_service": {"envoy_grpc": {"cluster_name": "opa"}, "timeout": "3s"}}},
                        {"name": "envoy.filters.http.router", "typed_config": {
                            "@type": "type.googleapis.com/envoy.extensions.filters.http.router.v3.Router"}},
                    ]}}],
            }],
        }],
        "clusters": [
            dns_cluster("torii", f"{party}-0.{party}.{ns}.svc.cluster.local", 8080),
            dns_cluster("driver", f"driver.{ns}.svc.cluster.local", 8091),
            dns_cluster("auditor", f"auditor.{ns}.svc.cluster.local", 8090),
            {"name": "opa", "type": "STATIC", "connect_timeout": "1s",
             "typed_extension_protocol_options": {"envoy.extensions.upstreams.http.v3.HttpProtocolOptions": {
                 "@type": "type.googleapis.com/envoy.extensions.upstreams.http.v3.HttpProtocolOptions",
                 "explicit_http_config": {"http2_protocol_options": {}}}},
             "load_assignment": {"cluster_name": "opa", "endpoints": [{"lb_endpoints": [{"endpoint": {"address": {
                 "socket_address": {"address": "127.0.0.1", "port_value": 9191}}}}]}]}},
        ],
    },
}

# --- objects
labels = {"app.kubernetes.io/part-of": "rd-iroha3", "rd-iroha3/party": party}
role = {**labels, "app.kubernetes.io/name": "gateway", "rd-iroha3/role": "gateway"}
meta = lambda name, extra=None: {"name": name, "namespace": ns, "labels": labels, **(extra or {})}
ctr_sec = {"allowPrivilegeEscalation": False, "readOnlyRootFilesystem": True, "capabilities": {"drop": ["ALL"]}}
tmp_mount = {"name": "tmp", "mountPath": "/tmp"}
docs = [
    {"apiVersion": "v1", "kind": "ConfigMap", "metadata": meta("gateway-envoy"), "data": {"envoy.yaml": json.dumps(envoy, indent=2) + "\n"}},
    {"apiVersion": "v1", "kind": "ConfigMap", "metadata": meta("gateway-opa"),
     "data": {"opa.yaml": yaml.safe_dump(opa, sort_keys=True, default_flow_style=False)}},
    {"apiVersion": "v1", "kind": "ConfigMap", "metadata": meta("gateway-policy"), "data": policy},
    {"apiVersion": "apps/v1", "kind": "Deployment", "metadata": meta("gateway", {"labels": role}),
     "spec": {
         "replicas": 1,
         "strategy": {"type": "Recreate"},
         "selector": {"matchLabels": role},
         "template": {"metadata": {"labels": role}, "spec": {
             "automountServiceAccountToken": False,
             # envoy/opa are docker.io today; the pod spec still carries ghcr-pull like every rd-iroha3-* pod (R15: packages may go private)
             "imagePullSecrets": [{"name": "ghcr-pull"}],
             "enableServiceLinks": False,
             # R22 (co-location): PREFERRED spread of gateways across workers and rd-iroha3 namespaces (never required: it must still schedule when nodes are scarce)
             "affinity": {"podAntiAffinity": {"preferredDuringSchedulingIgnoredDuringExecution": [{"weight": 100, "podAffinityTerm": {
                 "topologyKey": "kubernetes.io/hostname",
                 "labelSelector": {"matchLabels": {"app.kubernetes.io/part-of": "rd-iroha3", "rd-iroha3/role": "gateway"}},
                 "namespaceSelector": {"matchLabels": {"app.kubernetes.io/part-of": "rd-iroha3"}}}}]}},
             "securityContext": {"runAsNonRoot": True, "runAsUser": 10001, "runAsGroup": 10001, "fsGroup": 10001,
                                 "seccompProfile": {"type": "RuntimeDefault"}},
             "containers": [
                 {"name": "envoy", "image": envoy_image, "imagePullPolicy": "IfNotPresent",
                  "args": ["-c", "/config/envoy.yaml", "--log-level", "warn"],
                  "ports": [{"name": "https", "containerPort": 8443}],
                  "resources": {"requests": {"cpu": "10m", "memory": "32Mi"}, "limits": {"cpu": "500m", "memory": "128Mi"}},
                  "securityContext": ctr_sec,
                  "readinessProbe": {"tcpSocket": {"port": 8443}, "periodSeconds": 5},
                  "volumeMounts": [{"name": "envoy-config", "mountPath": "/config", "readOnly": True},
                                   {"name": "server-cert", "mountPath": "/mtls", "readOnly": True},
                                   {"name": "client-ca", "mountPath": "/client-ca", "readOnly": True}, tmp_mount]},
                 {"name": "opa", "image": opa_image, "imagePullPolicy": "IfNotPresent",
                  "args": ["run", "--server", "--addr=localhost:8181", "--diagnostic-addr=0.0.0.0:8282", "--authorization=basic",
                           "--config-file=/config/opa.yaml", f"--set=labels.gateway=gateway-{party}"]
                          # explicit files: the ConfigMap mount also holds ..data / ..<timestamp> links that a directory load would read twice
                          + [f"/policy/{f}" for f in POLICY],
                  "resources": {"requests": {"cpu": "20m", "memory": "64Mi"}, "limits": {"cpu": "500m", "memory": "256Mi"}},
                  "securityContext": ctr_sec,
                  "readinessProbe": {"httpGet": {"path": "/health?plugins", "port": 8282}, "periodSeconds": 5},
                  "livenessProbe": {"httpGet": {"path": "/health", "port": 8282}, "periodSeconds": 20},
                  "volumeMounts": [{"name": "opa-config", "mountPath": "/config", "readOnly": True},
                                   {"name": "opa-policy", "mountPath": "/policy", "readOnly": True}, tmp_mount]},
             ],
             "volumes": [
                 {"name": "envoy-config", "configMap": {"name": "gateway-envoy"}},
                 {"name": "opa-config", "configMap": {"name": "gateway-opa"}},
                 {"name": "opa-policy", "configMap": {"name": "gateway-policy"}},
                 {"name": "server-cert", "secret": {"secretName": "gateway-server", "defaultMode": 0o440}},
                 {"name": "client-ca", "secret": {"secretName": "gateway-client-ca"}},
                 {"name": "tmp", "emptyDir": {}},
             ],
         }},
     }},
    {"apiVersion": "v1", "kind": "Service", "metadata": meta("gateway"),
     "spec": {"type": "ClusterIP", "selector": role, "ports": [{"name": "https", "port": 8443, "targetPort": 8443, "protocol": "TCP"}]}},
]
if cluster == "1":
    # The Lensa host and the peers of the other cluster reach the gateway here; no fixed nodePort.
    docs.append({"apiVersion": "v1", "kind": "Service", "metadata": meta("gateway-ext"),
                 "spec": {"type": "NodePort", "externalTrafficPolicy": "Cluster", "selector": role,
                          "ports": [{"name": "https", "port": 8443, "targetPort": 8443, "protocol": "TCP"}]}})
if cluster == "2" or acl:
    # Only behind an EXISTING whitelist ACL (Alibaba CLB: loadBalancerSourceRanges alone creates none, see deploy/p2p).
    p = "service.beta.kubernetes.io/alibaba-cloud-loadbalancer-"
    docs.append({"apiVersion": "v1", "kind": "Service",
                 "metadata": meta("gateway-lb", {"annotations": {p + "acl-status": "on", p + "acl-type": "white", p + "acl-id": acl,
                                                                "service.beta.kubernetes.io/backend-type": "eni"}}),
                 "spec": {"type": "LoadBalancer", "externalTrafficPolicy": "Cluster", "loadBalancerSourceRanges": ranges, "selector": role,
                          "ports": [{"name": "https", "port": 8443, "targetPort": 8443, "protocol": "TCP"}]}})
docs.append({"apiVersion": "networking.k8s.io/v1", "kind": "NetworkPolicy", "metadata": meta("gateway-ingress"),
             "spec": {"podSelector": {"matchLabels": {"app.kubernetes.io/name": "gateway"}}, "policyTypes": ["Ingress"],
                      "ingress": [{"ports": [{"protocol": "TCP", "port": 8443}]}]}})
# R17 (key-holding pod: tls.key): the gateway's own narrow Egress policy, applied together with it. DNS, the own Torii, driver and auditor.
# No bundle-server (the policy is local), no ipBlock: nothing else leaves the pod.
docs.append({"apiVersion": "networking.k8s.io/v1", "kind": "NetworkPolicy", "metadata": meta("gateway-egress"),
             "spec": {"podSelector": {"matchLabels": {"rd-iroha3/role": "gateway"}}, "policyTypes": ["Egress"],
                      "egress": [
                          {"to": [{"namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": "kube-system"}},
                           "podSelector": {"matchLabels": {"k8s-app": "kube-dns"}}}],
                   "ports": [{"protocol": "UDP", "port": 53}, {"protocol": "TCP", "port": 53}]},
                          {"to": [{"podSelector": {"matchLabels": {"rd-iroha3/role": "peer", "rd-iroha3/party": party}}}], "ports": [{"protocol": "TCP", "port": 8080}]},
                          {"to": [{"podSelector": {"matchLabels": {"rd-iroha3/role": "driver"}}}], "ports": [{"protocol": "TCP", "port": 8091}]},
                          {"to": [{"podSelector": {"matchLabels": {"rd-iroha3/role": "auditor"}}}], "ports": [{"protocol": "TCP", "port": 8090}]},
                      ]}})
print("\n---\n".join(json.dumps(d, indent=2) for d in docs))
