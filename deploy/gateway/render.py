"""Render the S14 gateway manifests (see render.sh). Output: YAML stream of JSON documents, deterministic."""
import json
import sys

import yaml

party, cluster, envoy_image, opa_image, opa_config, acl = sys.argv[1:7]
ranges = sys.argv[7:]
ns = f"rd-iroha3-{party}"


def refuse(message):
    print(f"render.sh: {message}", file=sys.stderr)
    sys.exit(2)


# --- the party's OPA config: public bundle-signing keys and the ext_authz plugin, kept as given
try:
    base = yaml.safe_load(open(opa_config)) or {}
except yaml.YAMLError as e:
    refuse(f"--opa-config is not YAML: {e}")
if not isinstance(base, dict) or not base.get("keys"):
    refuse("--opa-config needs a `keys:` block with the PUBLIC bundle-signing keys")
if party not in base["keys"]:
    refuse(f"--opa-config `keys:` has no key named {party} (the bank bundle is verified with signing keyid {party})")
if base.get("plugins", {}).get("envoy_ext_authz_grpc", {}).get("addr") != "127.0.0.1:9191":
    refuse("--opa-config needs plugins.envoy_ext_authz_grpc with addr 127.0.0.1:9191 (the address the envoy opa cluster dials)")
# Read side only, as the Fabric-X gateway (rd-fabric-x#37): bundles come from the SAME party's bundle-server in its own cluster;
# URL names the Service port 80 (no :8080: that is the pod port; 8081 is the sink); no sink, no token, decision logs and status on the console.
opa = {**base,
       "services": {"bundle-server": {"url": f"http://bundle-server.rd-zeto-{party}.svc.cluster.local"}},
       "decision_logs": {"console": True},
       "status": {"console": True}}

# --- envoy: mTLS listener, XFCC to OPA, forward every path unchanged to the party's Torii or driver
AUTHZ = "envoy.filters.http.ext_authz"
ctx = {"target": "iroha3", "node": party}
per_route = {AUTHZ: {"@type": "type.googleapis.com/envoy.extensions.filters.http.ext_authz.v3.ExtAuthzPerRoute",
                     "check_settings": {"context_extensions": ctx}}}
# Driver routes wait for `Applied` (client.toml status_timeout_ms 300000), so the route timeout is above 300 s.
# Exact driver paths (the code's names: driver/src/server.rs, mint.rs); `/mint` exists on the BI gateway only (BI driver).
driver_paths = ["/settle-grant", "/dvp-native"] + (["/mint"] if party == "bi" else [])
routes = [{"match": {"path": p}, "route": {"cluster": "driver", "timeout": "330s"}, "typed_per_filter_config": per_route}
          for p in driver_paths]
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
    {"apiVersion": "apps/v1", "kind": "Deployment", "metadata": meta("gateway", {"labels": role}),
     "spec": {
         "replicas": 1,
         "strategy": {"type": "Recreate"},
         "selector": {"matchLabels": role},
         "template": {"metadata": {"labels": role}, "spec": {
             "automountServiceAccountToken": False,
             "enableServiceLinks": False,
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
                           "--config-file=/config/opa.yaml", f"--set=labels.gateway=gateway-{party}",
                           "--set=bundles.bi.resource=bi/latest.tar.gz", "--set=bundles.bank.resource=bank/latest.tar.gz",
                           f"--set=bundles.bank.signing.keyid={party}"],
                  "resources": {"requests": {"cpu": "20m", "memory": "64Mi"}, "limits": {"cpu": "500m", "memory": "256Mi"}},
                  "securityContext": ctr_sec,
                  "readinessProbe": {"httpGet": {"path": "/health?plugins&bundles", "port": 8282}, "periodSeconds": 5},
                  "livenessProbe": {"httpGet": {"path": "/health", "port": 8282}, "periodSeconds": 20},
                  "volumeMounts": [{"name": "opa-config", "mountPath": "/config", "readOnly": True}, tmp_mount]},
             ],
             "volumes": [
                 {"name": "envoy-config", "configMap": {"name": "gateway-envoy"}},
                 {"name": "opa-config", "configMap": {"name": "gateway-opa"}},
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
print("\n---\n".join(json.dumps(d, indent=2) for d in docs))
