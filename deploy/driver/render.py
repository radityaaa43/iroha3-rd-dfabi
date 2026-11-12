"""Render the S17 driver manifests (see render.sh). Output: YAML stream of JSON documents, deterministic."""
import json
import re
import sys
import tomllib

party, digest, pub, network = sys.argv[1:5]
audit_tls = len(sys.argv) > 5 and sys.argv[5] == "--audit-tls"
mint = sys.argv[6] if len(sys.argv) > 6 and sys.argv[6] else ""  # "<max_rd>:<max_dfabi>" (BI only; render.sh validates)
remote_gw = sys.argv[7:] if audit_tls else []
same_cluster = ("bi", "bank-a", "bank-b") if party != "bank-c" else ("bank-c",)
PARTIES = ["bi", "bank-a", "bank-b", "bank-c"]
ns = f"rd-iroha3-{party}"
read = lambda name: open(f"{pub}/{name}").read()
chain = read("chain_id").strip()
m = re.fullmatch(r"hash:([0-9A-Fa-f]{64})#[0-9A-Fa-f]{4}", read("genesis.expected_hash").strip())
if not m:
    sys.exit("render.sh: genesis.expected_hash is not hash:<64 hex>#<crc>")
h8 = m.group(1)[:8].lower()
peers = json.loads(read("peers.json"))
gen = open(f"{network}/generate.sh").read()
rd = re.search(r"^  RD_ID=(\S+)$", gen, re.M).group(1)
dfabi = re.search(r"^  DFABI_ID=(\S+)$", gen, re.M).group(1)
nexus = tomllib.load(open(f"{network}/nexus.toml", "rb"))["nexus"]
fee = nexus["fees"]["fee_asset_id"]
lanes = {l["alias"]: l["index"] for l in nexus["lane_catalog"]}
labels = {"app.kubernetes.io/part-of": "rd-iroha3", "rd-iroha3/party": party}
role = {**labels, "rd-iroha3/role": "driver"}
toml = "\n".join(
    [
        "# rd-dfabi server config of this bank (public values only; keys come from Secret %s-keys)." % party,
        f'chain = "{chain}"',
        'network_id_file = "/genesis/genesis.expected_hash"',
        'account_domain = "wonderland.universal"',
        'client_toml = "/keys/client.toml"',
        f'party = "{party}"  # the acting party (sponsor = this bank, node-build S10); set explicitly, never the default bi',
        'peers_json = "/config/peers.json"',
        'key_dir = "/keys"',
        f'fee_asset = "{fee}"',
        *(["mint_enabled = true  # BI only (K6): POST /mint for RD and DFABI up to the caps of [auditor]"] if mint else []),
        'auditor_url = "bi-auditor.rd-iroha3-bi.svc.cluster.local:8090"  # unused by the server mode',
        "",
        "[torii]",
        *[f'{p} = "http://{p}-0.{p}.rd-iroha3-{p}.svc.cluster.local:8080/"' for p in PARTIES],
        "",
        "[assets]",
        f'rd = "{rd}"',
        f'dfabi = "{dfabi}"',
        "",
        "[lanes]",
        f"rd = {lanes['ds-rd']}",
        f"dfabi = {lanes['ds-dfabi']}",
        "",
        *(["# K6: per-request mint caps (cfg.auditor.max_rd / max_dfabi); the table needs all of listen, store_dir, max_rd, max_dfabi, parties (node-build config.rs:96-118); listen/store_dir are unused by the server mode",
           "[auditor]", 'listen = "0.0.0.0:8090"', 'store_dir = "/audit-store"', f"max_rd = {mint.split(':')[0]}", f"max_dfabi = {mint.split(':')[1]}",
           "parties = [" + ", ".join(json.dumps(json.loads(read('accounts.json'))[q]) for q in PARTIES) + "]", ""] if mint else []),
    ]
    + (
        [
            "# 2-of-3 auditors (BI, org A, org B), each reached ONLY through its own party's gateway over mutual TLS (iroha3 S13 transport A)",
            "[audit]",
            "min_approvals = 2",
            "auditor_urls = [" + ", ".join(json.dumps(f"https://gateway.rd-iroha3-{p}.svc.cluster.local:8443") for p in ("bi", "bank-a", "bank-b")) + "]",
            "",
            "[tls]",
            'client_cert = "/tls/client/tls.crt"',
            'client_key = "/tls/client/tls.key"',
            'server_ca_dir = "/tls/cas"',
            "",
        ]
        if audit_tls
        else []
    )
)
tomllib.loads(toml)
docs = [
    {"apiVersion": "v1", "kind": "ConfigMap", "metadata": {"name": "driver-config", "namespace": ns, "labels": labels},
     "data": {"rd-dfabi.toml": toml, "peers.json": json.dumps(peers, indent=2) + "\n"}},
    *([{"apiVersion": "v1", "kind": "ConfigMap", "metadata": {"name": "gateway-server-cas", "namespace": ns, "labels": labels},
        "data": {f"{p}-server-ca.pem": open(f"{pub}/gateway-ca/{p}-server-ca.pem").read() for p in PARTIES}}] if audit_tls else []),
    {"apiVersion": "apps/v1", "kind": "Deployment", "metadata": {"name": "driver", "namespace": ns, "labels": role},
     "spec": {
         "replicas": 1,
         "selector": {"matchLabels": role},
         "template": {"metadata": {"labels": role}, "spec": {
             "automountServiceAccountToken": False,
             "enableServiceLinks": False,
             "imagePullSecrets": [{"name": "ghcr-pull"}],
             "securityContext": {"runAsNonRoot": True, "runAsUser": 1001, "runAsGroup": 1001, "fsGroup": 1001,
                                 "seccompProfile": {"type": "RuntimeDefault"}},
             "containers": [{
                 "name": "driver",
                 "image": f"ghcr.io/radityaaa43/iroha3-rd-driver@{digest}",
                 "imagePullPolicy": "IfNotPresent",
                 "args": ["server", "/config/rd-dfabi.toml", "--listen", "0.0.0.0:8091"],
                 "ports": [{"name": "http", "containerPort": 8091}],
                 "resources": {"requests": {"cpu": "50m", "memory": "64Mi"}, "limits": {"cpu": "500m", "memory": "256Mi"}},
                 "securityContext": {"allowPrivilegeEscalation": False, "readOnlyRootFilesystem": True, "capabilities": {"drop": ["ALL"]}},
                 # One request at a time: /healthz is unanswered while a /dvp-native waits for Applied (up to 300 s). Liveness
                 # (12 x 30 s + 5 s) outlasts that, so the pod is never killed mid-request; readiness (3 x 5 s) fails fast, so the
                 # Service stops routing to a busy driver. Throughput limit: ONE in-flight request per bank (ANALYST Q10).
                 "livenessProbe": {"httpGet": {"path": "/healthz", "port": "http"}, "periodSeconds": 30, "failureThreshold": 12, "timeoutSeconds": 5},
                 "readinessProbe": {"httpGet": {"path": "/healthz", "port": "http"}, "periodSeconds": 5, "failureThreshold": 3, "timeoutSeconds": 2},
                 "volumeMounts": [
                     {"name": "keys", "mountPath": "/keys", "readOnly": True},
                     {"name": "config", "mountPath": "/config", "readOnly": True},
                     {"name": "genesis", "mountPath": "/genesis", "readOnly": True},
                 ] + ([{"name": "client-cert", "mountPath": "/tls/client", "readOnly": True},
                       {"name": "server-cas", "mountPath": "/tls/cas", "readOnly": True}] if audit_tls else []),
             }],
             "volumes": [
                 {"name": "keys", "secret": {"secretName": f"{party}-keys", "defaultMode": 0o400,
                                             "items": [{"key": f"{party}.seed", "path": f"{party}.seed"},
                                                       {"key": f"{party}.note", "path": f"{party}.note"},
                                                       {"key": "client.toml", "path": "client.toml"}]}},
                 {"name": "config", "configMap": {"name": "driver-config"}},
                 {"name": "genesis", "configMap": {"name": f"genesis-{h8}"}},
             ] + ([{"name": "client-cert", "secret": {"secretName": "iroha3-client-cert", "defaultMode": 0o400,
                                                      "items": [{"key": "tls.crt", "path": "tls.crt"}, {"key": "tls.key", "path": "tls.key"}]}},
                   {"name": "server-cas", "configMap": {"name": "gateway-server-cas"}}] if audit_tls else []),
         }},
     }},
    {"apiVersion": "v1", "kind": "Service", "metadata": {"name": "driver", "namespace": ns, "labels": labels},
     "spec": {"type": "ClusterIP", "selector": role, "ports": [{"name": "http", "port": 8091, "targetPort": "http", "protocol": "TCP"}]}},
    {"apiVersion": "networking.k8s.io/v1", "kind": "NetworkPolicy", "metadata": {"name": "driver-ingress", "namespace": ns, "labels": labels},
     "spec": {"podSelector": {"matchLabels": {"rd-iroha3/role": "driver"}}, "policyTypes": ["Ingress"],
              "ingress": [{"from": [{"podSelector": {"matchLabels": {"rd-iroha3/role": "gateway"}}}],
                           "ports": [{"protocol": "TCP", "port": 8091}]}]}},
    # R17 end step (key-holding pod: the bank seed): ONE narrow Egress policy `driver-egress`, ALWAYS rendered (live D2 shape too): cluster DNS; the OWN peer's Torii (:8080)
    # only (every live server route uses client.toml = own Torii; the other parties' [torii] entries are read only by the CLI APS paths); and WITH --audit-tls the
    # gateways on 8443 (same-cluster namespaces by selector; the other cluster's gateways ONLY as the explicit /32 external LB addresses of --remote-gw-cidr).
    {"apiVersion": "networking.k8s.io/v1", "kind": "NetworkPolicy", "metadata": {"name": "driver-egress", "namespace": ns, "labels": labels},
     "spec": {"podSelector": {"matchLabels": {"rd-iroha3/role": "driver"}}, "policyTypes": ["Egress"],
              "egress": [
                  {"to": [{"namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": "kube-system"}},
                           "podSelector": {"matchLabels": {"k8s-app": "kube-dns"}}}],
                   "ports": [{"protocol": "UDP", "port": 53}, {"protocol": "TCP", "port": 53}]},
                  {"to": [{"podSelector": {"matchLabels": {"rd-iroha3/role": "peer", "rd-iroha3/party": party}}}],
                   "ports": [{"protocol": "TCP", "port": 8080}]},
              ] + ([{"to": [{"namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": f"rd-iroha3-{q}"}},
                             "podSelector": {"matchLabels": {"rd-iroha3/role": "gateway"}}} for q in same_cluster]
                            + [{"ipBlock": {"cidr": c}} for c in remote_gw],
                     "ports": [{"protocol": "TCP", "port": 8443}]}] if audit_tls else [])}},
]
print("\n---\n".join(json.dumps(d, indent=2) for d in docs))
