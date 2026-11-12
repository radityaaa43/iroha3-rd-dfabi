"""Render one aps-run Job (see render.sh). Output: YAML stream of JSON documents, deterministic."""
import json
import re
import sys
import tomllib

import yaml

digest, pub, network, name, bankc_ip, *args = sys.argv[1:]
PARTIES = ["bi", "bank-a", "bank-b", "bank-c"]
ENVOY = "envoyproxy/envoy@sha256:b1f389c3a6148e85e9de364cb867aa2e5802153abb37ad80f1f2241d693da32a"  # the gateways' pinned envoy
ns = "rd-iroha3-bi"
read = lambda f: open(f"{pub}/{f}").read()
chain = read("chain_id").strip()
m = re.fullmatch(r"hash:([0-9A-Fa-f]{64})#[0-9A-Fa-f]{4}", read("genesis.expected_hash").strip())
h8 = m.group(1)[:8].lower()
peers = json.loads(read("peers.json"))
nexus = tomllib.load(open(f"{network}/nexus.toml", "rb"))["nexus"]
lanes = {l["alias"]: l["index"] for l in nexus["lane_catalog"]}
labels = {"app.kubernetes.io/part-of": "rd-iroha3", "rd-iroha3/party": "bi"}
locked = {**labels, "rd-iroha3/role": "aps-run", "rd/egress-locked": "true"}
toml = "\n".join([
    "# rd-dfabi config of the BI aps-run coordinator Job (public values only).",
    f'chain = "{chain}"',
    'network_id_file = "/genesis/genesis.expected_hash"',
    'account_domain = "wonderland.universal"',
    'party = "bi"',
    'client_toml = "/client/client.toml"',
    'peers_json = "/config/peers.json"',
    'key_dir = "/pools/keys"',
    'pools_file = "/pools/pools.json"',
    f'fee_asset = "{nexus["fees"]["fee_asset_id"]}"',
    'auditor_url = "unused-by-aps-run:8090"',
    "",
    "# all four committee Torii through their gateways (the gw-tls sidecar, loopback only)",
    "[torii]",
    *[f'{p} = "http://127.0.0.1:{18101 + i}/"' for i, p in enumerate(PARTIES)],
    "",
    "[assets]",
    'rd = "7onbjg2gRXveoAAUFsohCZyGW98t"',
    'dfabi = "4mBWK1JCwQdHLDPpuVKc56eLsXka"',
    "",
    "[lanes]",
    f"rd = {lanes['ds-rd']}",
    f"dfabi = {lanes['ds-dfabi']}",
    "",
    "[audit]",
    "min_approvals = 2",
    "auditor_urls = [" + ", ".join(json.dumps(f"https://gateway.rd-iroha3-{p}.svc.cluster.local:8443") for p in ("bi", "bank-a", "bank-b")) + "]",
    "",
    "[tls]",
    'client_cert = "/tls/client/tls.crt"',
    'client_key = "/tls/client/tls.key"',
    'server_ca_dir = "/tls/cas"',
    "",
])
tomllib.loads(toml)


def sidecar():
    listeners, clusters = [], []
    for i, q in enumerate(PARTIES):
        host = f"gateway.rd-iroha3-{q}.svc.cluster.local"
        listeners.append({"name": f"to-{q}", "address": {"socket_address": {"address": "127.0.0.1", "port_value": 18101 + i}},
                          "filter_chains": [{"filters": [{"name": "envoy.filters.network.http_connection_manager", "typed_config": {
                              "@type": "type.googleapis.com/envoy.extensions.filters.network.http_connection_manager.v3.HttpConnectionManager",
                              "stat_prefix": f"to_{q}", "codec_type": "AUTO",
                              "route_config": {"name": f"to-{q}", "virtual_hosts": [{"name": f"to-{q}", "domains": ["*"], "routes": [
                                  {"match": {"prefix": "/"}, "route": {"cluster": f"gw-{q}", "timeout": "330s"}}]}]},
                              "http_filters": [{"name": "envoy.filters.http.router", "typed_config": {
                                  "@type": "type.googleapis.com/envoy.extensions.filters.http.router.v3.Router"}}]}}]}]})
        remote = q == "bank-c"
        clusters.append({"name": f"gw-{q}", "type": "STATIC" if remote else "STRICT_DNS", "connect_timeout": "3s", "dns_lookup_family": "V4_ONLY",
                         "load_assignment": {"cluster_name": f"gw-{q}", "endpoints": [{"lb_endpoints": [{"endpoint": {"address": {"socket_address": {
                             "address": bankc_ip if remote else host, "port_value": 8443}}}}]}]},
                         "transport_socket": {"name": "envoy.transport_sockets.tls", "typed_config": {
                             "@type": "type.googleapis.com/envoy.extensions.transport_sockets.tls.v3.UpstreamTlsContext", "sni": host,
                             "common_tls_context": {
                                 "tls_params": {"tls_minimum_protocol_version": "TLSv1_2"},
                                 "tls_certificates": [{"certificate_chain": {"filename": "/client/tls.crt"}, "private_key": {"filename": "/client/tls.key"}}],
                                 "validation_context": {"trusted_ca": {"filename": f"/server-cas/{q}-server-ca.pem"},
                                                        "match_typed_subject_alt_names": [{"san_type": "DNS", "matcher": {"exact": host}}]}}}}})
    return {"static_resources": {"listeners": listeners, "clusters": clusters}}


meta = lambda n: {"name": n, "namespace": ns, "labels": labels}
script = " && ".join([
    "set -eu",
    "test -f /pools/pools.json",  # pool-init ran on this PVC
    "{ test -L /pools/keys/bi.seed || ln -s /keys/bi.seed /pools/keys/bi.seed; }",
    "{ test -L /pools/keys/bi.note || ln -s /keys/bi.note /pools/keys/bi.note; }",
    "for i in $(seq 1 30); do (echo > /dev/tcp/127.0.0.1/18104) 2>/dev/null && break; sleep 1; done",
    "rd-dfabi " + args[0] + " /config/rd-dfabi.toml " + " ".join(args[1:]),
])
ro = lambda n, p, **kw: {"name": n, "mountPath": p, "readOnly": True, **kw}
gw = lambda q: {"namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": f"rd-iroha3-{q}"}}, "podSelector": {"matchLabels": {"rd-iroha3/role": "gateway"}}}
sec = {"allowPrivilegeEscalation": False, "readOnlyRootFilesystem": True, "capabilities": {"drop": ["ALL"]}}
docs = [
    {"apiVersion": "v1", "kind": "ConfigMap", "metadata": meta("aps-run-config"),
     "data": {"rd-dfabi.toml": toml, "peers.json": json.dumps(peers, indent=2) + "\n"}},
    {"apiVersion": "v1", "kind": "ConfigMap", "metadata": meta("aps-run-gw-envoy"),
     "data": {"envoy.yaml": yaml.safe_dump(sidecar(), sort_keys=True, default_flow_style=False)}},
    {"apiVersion": "batch/v1", "kind": "Job", "metadata": {**meta(f"aps-run-{name}"), "labels": locked},
     "spec": {
         "backoffLimit": 0,
         "activeDeadlineSeconds": 3600,
         "ttlSecondsAfterFinished": 86400,
         "template": {"metadata": {"labels": locked}, "spec": {
             "restartPolicy": "Never",
             "automountServiceAccountToken": False,
             "enableServiceLinks": False,
             "imagePullSecrets": [{"name": "ghcr-pull"}],
             "securityContext": {"runAsNonRoot": True, "runAsUser": 1001, "runAsGroup": 1001, "fsGroup": 1001, "seccompProfile": {"type": "RuntimeDefault"}},
             "initContainers": [{
                 "name": "gw-tls", "image": ENVOY, "imagePullPolicy": "IfNotPresent", "restartPolicy": "Always",
                 "args": ["-c", "/config/envoy.yaml", "--log-level", "warn"],
                 "resources": {"requests": {"cpu": "10m", "memory": "32Mi"}, "limits": {"cpu": "500m", "memory": "128Mi"}},
                 "securityContext": sec,
                 "volumeMounts": [ro("envoy-config", "/config"), ro("server-cas", "/server-cas"), ro("client-cert", "/client"), {"name": "tmp", "mountPath": "/tmp"}],
             }],
             "containers": [{
                 "name": "aps-run", "image": f"ghcr.io/radityaaa43/iroha3-rd-driver@{digest}", "imagePullPolicy": "IfNotPresent",
                 "command": ["/bin/bash", "-c", script],
                 # the prover: one leg peaked at 1.1 GiB RSS (reports/b-aps.md selftest); nodes have ~6.2 GiB allocatable
                 "resources": {"requests": {"cpu": "1", "memory": "2Gi"}, "limits": {"cpu": "2", "memory": "3Gi"}},
                 "securityContext": sec,
                 "volumeMounts": [
                     ro("keys", "/keys"), ro("config", "/config"), ro("genesis", "/genesis"),
                     ro("keys", "/client/client.toml", subPath="client.toml"),
                     ro("client-cert", "/tls/client"), ro("server-cas", "/tls/cas"),
                     {"name": "pools", "mountPath": "/pools"}, {"name": "tmp", "mountPath": "/tmp"},
                 ],
             }],
             "volumes": [
                 {"name": "keys", "secret": {"secretName": "bi-keys", "defaultMode": 0o400,
                                             "items": [{"key": k, "path": k} for k in ("bi.seed", "bi.note", "client.toml")]}},
                 {"name": "config", "configMap": {"name": "aps-run-config"}},
                 {"name": "genesis", "configMap": {"name": f"genesis-{h8}"}},
                 {"name": "envoy-config", "configMap": {"name": "aps-run-gw-envoy"}},
                 {"name": "server-cas", "configMap": {"name": "gateway-server-cas"}},
                 {"name": "client-cert", "secret": {"secretName": "iroha3-client-cert", "defaultMode": 0o400,
                                                    "items": [{"key": "tls.crt", "path": "tls.crt"}, {"key": "tls.key", "path": "tls.key"}]}},
                 {"name": "pools", "persistentVolumeClaim": {"claimName": "pools-index"}},
                 {"name": "tmp", "emptyDir": {}},
             ],
         }},
     }},
    {"apiVersion": "networking.k8s.io/v1", "kind": "NetworkPolicy", "metadata": meta("aps-run-egress"),
     "spec": {"podSelector": {"matchLabels": {"rd-iroha3/role": "aps-run", "rd/egress-locked": "true"}}, "policyTypes": ["Egress"],
              "egress": [
                  {"to": [{"namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": "kube-system"}}, "podSelector": {"matchLabels": {"k8s-app": "kube-dns"}}}],
                   "ports": [{"protocol": "UDP", "port": 53}, {"protocol": "TCP", "port": 53}]},
                  {"to": [gw(q) for q in ("bi", "bank-a", "bank-b")], "ports": [{"protocol": "TCP", "port": 8443}]},
                  {"to": [{"ipBlock": {"cidr": f"{bankc_ip}/32"}}], "ports": [{"protocol": "TCP", "port": 8443}]},
              ]}},
]
print("\n---\n".join(json.dumps(d, indent=2) for d in docs))
