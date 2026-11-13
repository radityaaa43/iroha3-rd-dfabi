"""Render the S17 driver manifests (see render.sh). Output: YAML stream of JSON documents, deterministic."""
import json
import re
import sys
import tomllib

party, digest, pub, network = sys.argv[1:5]
audit_tls = len(sys.argv) > 5 and sys.argv[5] == "--audit-tls"
mint = sys.argv[6] if len(sys.argv) > 6 and sys.argv[6] else ""  # "<max_rd>:<max_dfabi>" (BI only; render.sh validates)
aps = len(sys.argv) > 7 and sys.argv[7] == "1"  # --aps (render.sh)
aps_pools = sys.argv[8] if len(sys.argv) > 8 else ""  # --aps-pools <pools.json> (banks only; BI uses the PVC pools-index)
extra = sys.argv[9:] if audit_tls else []
gw_ip = dict(a.split("=", 1) for a in extra if "=" in a)  # bank-c only (render.sh): cluster-1 party -> external gateway-lb ip
bankc_ip = gw_ip.pop("bank-c", None)  # BI --aps only (render.sh): the gateway-lb of bank-c, no [tls.resolve] entry (cluster 1 resolves the gateways by name)
# --remote-gw-cidr values first, then the /32s derived from --remote-gw in party order (the same ip feeds [tls.resolve] below)
remote_gw = [a for a in extra if "=" not in a] + [f"{gw_ip[q]}/32" for q in ("bi", "bank-a", "bank-b") if q in gw_ip] + ([f"{bankc_ip}/32"] if bankc_ip else [])
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
# --- APS all-flows (plan 2026-11-13-04). ConfigMap aps-pools = the PUBLIC pool records the operator gives (node-build driver/src/pools.rs PoolFile/PoolRecord, loaded by PoolFile::load):
# nothing is invented here; the shape is checked so a stray field (a key, a note) can never ride along.
POOL_FIELDS = {"pool_id", "route", "policy", "governance", "origin", "bundles"}
pools = None
if aps_pools:
    pools = json.load(open(aps_pools))
    if set(pools) != {"rd", "dfabi"} or any(not isinstance(r, dict) or set(r) != POOL_FIELDS for r in pools.values()):
        print(f"render.sh: {aps_pools} must be a PoolFile: exactly rd and dfabi, each with exactly {sorted(POOL_FIELDS)}", file=sys.stderr)
        sys.exit(2)
    for k, r in pools.items():
        if not (re.fullmatch(r"[0-9a-f]{64}", r["pool_id"]) and all(isinstance(r[f], str) and re.fullmatch(r"[A-Za-z0-9+/]+={0,2}", r[f]) for f in ("route", "policy", "governance"))
                and isinstance(r["origin"], list) and len(r["origin"]) == 2 and all(isinstance(o, str) and re.fullmatch(r"([0-9a-f]{2})+", o) for o in r["origin"])
                and isinstance(r["bundles"], list)):
            print(f"render.sh: {aps_pools}: {k} record is not a PoolRecord (pool_id 64 lowercase hex, route/policy/governance base64, origin 2 hex commitments, bundles list)", file=sys.stderr)
            sys.exit(2)
        r["bundles"] = []  # the bank driver fetches the bundle index from BI at runtime (T2): the seed never carries one
aps_coordinator = aps and party == "bi"  # BI keeps its pools on the PVC pools-index (render.sh refuses --aps-pools there)
ENVOY = "envoyproxy/envoy@sha256:b1f389c3a6148e85e9de364cb867aa2e5802153abb37ad80f1f2241d693da32a"  # the gateways' pinned envoy (same as deploy/aps-run/render.py)
labels = {"app.kubernetes.io/part-of": "rd-iroha3", "rd-iroha3/party": party}
role = {**labels, "rd-iroha3/role": "driver"}
toml = "\n".join(
    [
        "# rd-dfabi server config of this bank (public values only; keys come from Secret %s-keys)." % party,
        f'chain = "{chain}"',
        'network_id_file = "/genesis/genesis.expected_hash"',
        'account_domain = "wonderland.universal"',
        'client_toml = "/client/client.toml"',  # a subPath mount (below): a Secret volume file is a symlink and iroha_config_base refuses symlinks
        f'party = "{party}"  # the acting party (sponsor = this bank, node-build S10); set explicitly, never the default bi',
        'peers_json = "/config/peers.json"',
        f'key_dir = "{"/pools/keys" if aps_coordinator else "/keys"}"' + ("  # APS: on the PVC pools-index; the Secret keys are linked in by the init container pools-link" if aps_coordinator else ""),
        f'fee_asset = "{fee}"',
        *(['pools_file = "/pools/pools.json"  # APS: ' + ("the live index on the PVC pools-index (deploy/pool-init)" if aps_coordinator else "ConfigMap aps-pools, copied into the writable emptyDir /pools by an init container")] if aps else []),
        *(["mint_enabled = true  # BI only (K6): POST /mint for RD and DFABI up to the caps of [auditor]"] if mint else []),
        'auditor_url = "bi-auditor.rd-iroha3-bi.svc.cluster.local:8090"  # unused by the server mode',
        "",
        "[torii]",
        # BI --aps: settle() uses plain-HTTP iroha client calls to all four committee Torii, so BI reaches them through the gw-tls sidecar (loopback 18101-18104, mTLS to the gateways)
        *([f'{p} = "http://127.0.0.1:{18101 + i}/"' for i, p in enumerate(PARTIES)] if aps_coordinator
          else [f'{p} = "http://{p}-0.{p}.rd-iroha3-{p}.svc.cluster.local:8080/"' for p in PARTIES]),
        "",
        "[assets]",
        f'rd = "{rd}"',
        f'dfabi = "{dfabi}"',
        "",
        "[lanes]",
        f"rd = {lanes['ds-rd']}",
        f"dfabi = {lanes['ds-dfabi']}",
        "",
        *(["# APS coordinator = the BI driver only; a bank forwards POST /aps/submit to the BI gateway over mTLS (bank-c resolves the host through [tls.resolve])",
           "[aps]", *(["coordinator = true"] if aps_coordinator else ['coordinator_url = "https://gateway.rd-iroha3-bi.svc.cluster.local:8443"']), ""] if aps else []),
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
            *(["", "# cluster 2 cannot resolve the cluster-1 gateway names: host -> ip:port (node-build tls_http.rs:53-55); the leaf SAN still matches the host",
               "[tls.resolve]", *[f'"gateway.rd-iroha3-{q}.svc.cluster.local" = "{gw_ip[q]}:8443"' for q in ("bi", "bank-a", "bank-b")]] if gw_ip else []),
            "",
        ]
        if audit_tls
        else []
    )
)
tomllib.loads(toml)


def sidecar():
    """gw-tls (BI --aps): loopback 18101-18104 -> the four gateways over mTLS with the driver client leaf; verbatim the pattern of deploy/aps-run/render.py sidecar()."""
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


sec = {"allowPrivilegeEscalation": False, "readOnlyRootFilesystem": True, "capabilities": {"drop": ["ALL"]}}
image = f"ghcr.io/radityaaa43/iroha3-rd-driver@{digest}"
docs = [
    {"apiVersion": "v1", "kind": "ConfigMap", "metadata": {"name": "driver-config", "namespace": ns, "labels": labels},
     "data": {"rd-dfabi.toml": toml, "peers.json": json.dumps(peers, indent=2) + "\n"}},
    *([{"apiVersion": "v1", "kind": "ConfigMap", "metadata": {"name": "gateway-server-cas", "namespace": ns, "labels": labels},
        "data": {f"{p}-server-ca.pem": open(f"{pub}/gateway-ca/{p}-server-ca.pem").read() for p in PARTIES}}] if audit_tls else []),
    *([{"apiVersion": "v1", "kind": "ConfigMap", "metadata": {"name": "aps-pools", "namespace": ns, "labels": labels},
        "data": {"pools.json": json.dumps(pools, indent=2) + "\n"}}] if pools else []),
    *([{"apiVersion": "v1", "kind": "ConfigMap", "metadata": {"name": "driver-gw-envoy", "namespace": ns, "labels": labels},
        "data": {"envoy.yaml": json.dumps(sidecar(), indent=2) + "\n"}}] if aps_coordinator else []),
    {"apiVersion": "apps/v1", "kind": "Deployment", "metadata": {"name": "driver", "namespace": ns, "labels": role},
     "spec": {
         "replicas": 1,
         **({"strategy": {"type": "Recreate"}} if aps_coordinator else {}),  # BI --aps: the RWO PVC pools-index cannot be mounted by an old and a new pod at once
         "selector": {"matchLabels": role},
         "template": {"metadata": {"labels": role}, "spec": {
             "automountServiceAccountToken": False,
             "enableServiceLinks": False,
             "imagePullSecrets": [{"name": "ghcr-pull"}],
             "securityContext": {"runAsNonRoot": True, "runAsUser": 1001, "runAsGroup": 1001, "fsGroup": 1001,
                                 "seccompProfile": {"type": "RuntimeDefault"}},
             # --aps, banks: pools-seed copies ConfigMap aps-pools into the writable emptyDir /pools (settle() rewrites pools_file: lock file + rename, receipts dir beside it).
             # --aps, BI: the PVC pools-index is /pools; pools-link LINKS the Secret's bi.seed and bi.note into /pools/keys (deploy/aps-run/render.py pattern, never a copy of a key file); gw-tls native sidecar.
             **({"initContainers": [
                 *([{"name": "pools-link", "image": image, "imagePullPolicy": "IfNotPresent",
                     "command": ["/bin/bash", "-c", " && ".join(["set -eu", "test -f /pools/pools.json"] + [f"{{ test -L /pools/keys/{k} || ln -s /keys/{k} /pools/keys/{k}; }}" for k in ("bi.seed", "bi.note")])],
                     "resources": {"requests": {"cpu": "10m", "memory": "16Mi"}, "limits": {"cpu": "100m", "memory": "64Mi"}}, "securityContext": sec,
                     "volumeMounts": [{"name": "keys", "mountPath": "/keys", "readOnly": True}, {"name": "pools", "mountPath": "/pools"}]}] if aps_coordinator else
                   [{"name": "pools-seed", "image": image, "imagePullPolicy": "IfNotPresent", "command": ["/bin/bash", "-c", "cp /aps-pools/pools.json /pools/pools.json"],
                     "resources": {"requests": {"cpu": "10m", "memory": "16Mi"}, "limits": {"cpu": "100m", "memory": "64Mi"}}, "securityContext": sec,
                     "volumeMounts": [{"name": "aps-pools", "mountPath": "/aps-pools", "readOnly": True}, {"name": "pools", "mountPath": "/pools"}]}]),
                 *([{"name": "gw-tls", "image": ENVOY, "imagePullPolicy": "IfNotPresent", "restartPolicy": "Always",
                     "args": ["-c", "/config/envoy.yaml", "--log-level", "warn"],
                     "resources": {"requests": {"cpu": "10m", "memory": "32Mi"}, "limits": {"cpu": "500m", "memory": "128Mi"}}, "securityContext": sec,
                     "volumeMounts": [{"name": "envoy-config", "mountPath": "/config", "readOnly": True}, {"name": "server-cas", "mountPath": "/server-cas", "readOnly": True},
                                      {"name": "client-cert", "mountPath": "/client", "readOnly": True}, {"name": "tmp", "mountPath": "/tmp"}]}] if aps_coordinator else []),
             ]} if aps else {}),
             "containers": [{
                 "name": "driver",
                 "image": image,
                 "imagePullPolicy": "IfNotPresent",
                 "args": ["server", "/config/rd-dfabi.toml", "--listen", "0.0.0.0:8091"],
                 "ports": [{"name": "http", "containerPort": 8091}],
                 # --aps: the prover peaks at ~1.1 GiB RSS (reports/b-aps.md); memory 2Gi/3Gi and cpu 1/2 as deploy/aps-run/render.py
                 "resources": ({"requests": {"cpu": "1", "memory": "2Gi"}, "limits": {"cpu": "2", "memory": "3Gi"}} if aps
                               else {"requests": {"cpu": "50m", "memory": "64Mi"}, "limits": {"cpu": "500m", "memory": "256Mi"}}),
                 "securityContext": sec,
                 # One request at a time: /healthz is unanswered while a /dvp-native waits for Applied (up to 300 s). Liveness
                 # (12 x 30 s + 5 s) outlasts that, so the pod is never killed mid-request; readiness (3 x 5 s) fails fast, so the
                 # Service stops routing to a busy driver. Throughput limit: ONE in-flight request per bank (ANALYST Q10).
                 "livenessProbe": {"httpGet": {"path": "/healthz", "port": "http"}, "periodSeconds": 30, "failureThreshold": 12, "timeoutSeconds": 5},
                 "readinessProbe": {"httpGet": {"path": "/healthz", "port": "http"}, "periodSeconds": 5, "failureThreshold": 3, "timeoutSeconds": 2},
                 "volumeMounts": [
                     {"name": "keys", "mountPath": "/keys", "readOnly": True},
                     {"name": "keys", "mountPath": "/client/client.toml", "subPath": "client.toml", "readOnly": True},
                     {"name": "config", "mountPath": "/config", "readOnly": True},
                     {"name": "genesis", "mountPath": "/genesis", "readOnly": True},
                 ] + ([{"name": "client-cert", "mountPath": "/tls/client", "readOnly": True},
                       {"name": "server-cas", "mountPath": "/tls/cas", "readOnly": True}] if audit_tls else [])
                 + ([{"name": "pools", "mountPath": "/pools"}, {"name": "tmp", "mountPath": "/tmp"}] if aps else []),
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
                   {"name": "server-cas", "configMap": {"name": "gateway-server-cas"}}] if audit_tls else [])
             + (([{"name": "pools", "persistentVolumeClaim": {"claimName": "pools-index"}}, {"name": "tmp", "emptyDir": {}}, {"name": "envoy-config", "configMap": {"name": "driver-gw-envoy"}}] if aps_coordinator
                 else [{"name": "aps-pools", "configMap": {"name": "aps-pools"}}, {"name": "pools", "emptyDir": {}}, {"name": "tmp", "emptyDir": {}}]) if aps else []),
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
