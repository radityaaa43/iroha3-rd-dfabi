"""Render the S11/S12 auditor manifests (see render.sh). Output: YAML stream of JSON documents, deterministic."""
import json
import re
import sys
import tomllib

party, digest, pub, network = sys.argv[1:5]
PARTIES = ["bi", "bank-a", "bank-b", "bank-c"]
ns = f"rd-iroha3-{party}"
key_name = "bi-auditor" if party == "bi" else f"{party}-auditor"
read = lambda name: open(f"{pub}/{name}").read()
chain = read("chain_id").strip()
m = re.fullmatch(r"hash:([0-9A-Fa-f]{64})#[0-9A-Fa-f]{4}", read("genesis.expected_hash").strip())
if not m:
    sys.exit("render.sh: genesis.expected_hash is not hash:<64 hex>#<crc>")
h8 = m.group(1)[:8].lower()
peers = json.loads(read("peers.json"))
accounts = json.loads(read("accounts.json"))
parties_keys = [accounts[p] for p in PARTIES]  # the 4 trading accounts; bi-gov is governance only
gen = open(f"{network}/generate.sh").read()
rd = re.search(r"^  RD_ID=(\S+)$", gen, re.M).group(1)
dfabi = re.search(r"^  DFABI_ID=(\S+)$", gen, re.M).group(1)
nexus = tomllib.load(open(f"{network}/nexus.toml", "rb"))["nexus"]
fee = nexus["fees"]["fee_asset_id"]
lanes = {l["alias"]: l["index"] for l in nexus["lane_catalog"]}
labels = {"app.kubernetes.io/part-of": "rd-iroha3", "rd-iroha3/party": party}
role = {**labels, "rd-iroha3/role": "auditor"}
toml = "\n".join(
    [
        f"# rd-dfabi auditor config of {party} (public values only; keys come from Secret {key_name}-key, created by the org itself).",
        f'chain = "{chain}"',
        'network_id_file = "/genesis/genesis.expected_hash"',
        f'party = "{party}"',
        'peers_json = "/config/peers.json"',
        'key_dir = "/keys"',
        f'fee_asset = "{fee}"',
        'auditor_url = "unused-by-the-auditor:8090"',
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
        "[auditor]",
        f'key_name = "{key_name}"',
        'listen = "0.0.0.0:8090"',
        'store_dir = "/audit-store"',
        "max_rd = 10000000000   # = max_dfabi x 10^6 (Lensa prices one DFABI at 10^6 RD)",
        "max_dfabi = 10000",
        "parties = [" + ", ".join(json.dumps(k) for k in parties_keys) + "]",
        "",
    ]
)
tomllib.loads(toml)
meta = lambda name: {"name": name, "namespace": ns, "labels": labels}
docs = [
    {"apiVersion": "v1", "kind": "ConfigMap", "metadata": meta("auditor-config"),
     "data": {"rd-dfabi.toml": toml, "peers.json": json.dumps(peers, indent=2) + "\n"}},
    {"apiVersion": "v1", "kind": "PersistentVolumeClaim", "metadata": meta("audit-store"),
     "spec": {"storageClassName": "alicloud-essd-wffc", "accessModes": ["ReadWriteOnce"], "resources": {"requests": {"storage": "1Gi"}}}},
    {"apiVersion": "apps/v1", "kind": "Deployment", "metadata": {**meta("auditor"), "labels": role},
     "spec": {
         "replicas": 1,
         # RWO volume and one approver at a time: never two pods.
         "strategy": {"type": "Recreate"},
         "selector": {"matchLabels": role},
         "template": {"metadata": {"labels": role}, "spec": {
             "automountServiceAccountToken": False,
             "enableServiceLinks": False,
             "imagePullSecrets": [{"name": "ghcr-pull"}],
             "securityContext": {"runAsNonRoot": True, "runAsUser": 1001, "runAsGroup": 1001, "fsGroup": 1001,
                                 "seccompProfile": {"type": "RuntimeDefault"}},
             "containers": [{
                 "name": "auditor",
                 "image": f"ghcr.io/radityaaa43/iroha3-rd-driver@{digest}",
                 "imagePullPolicy": "IfNotPresent",
                 "args": ["auditor", "/config/rd-dfabi.toml"],
                 "ports": [{"name": "http", "containerPort": 8090}],
                 "readinessProbe": {"tcpSocket": {"port": "http"}, "periodSeconds": 10},
                 "resources": {"requests": {"cpu": "50m", "memory": "64Mi"}, "limits": {"cpu": "500m", "memory": "256Mi"}},
                 "securityContext": {"allowPrivilegeEscalation": False, "readOnlyRootFilesystem": True, "capabilities": {"drop": ["ALL"]}},
                 "volumeMounts": [
                     {"name": "keys", "mountPath": "/keys", "readOnly": True},
                     {"name": "config", "mountPath": "/config", "readOnly": True},
                     {"name": "genesis", "mountPath": "/genesis", "readOnly": True},
                     {"name": "store", "mountPath": "/audit-store"},
                 ],
             }],
             "volumes": [
                 {"name": "keys", "secret": {"secretName": f"{key_name}-key", "defaultMode": 0o400,
                                             "items": [{"key": f"{key_name}.seed", "path": f"{key_name}.seed"},
                                                       {"key": f"{key_name}.hybrid", "path": f"{key_name}.hybrid"}]}},
                 {"name": "config", "configMap": {"name": "auditor-config"}},
                 {"name": "genesis", "configMap": {"name": f"genesis-{h8}"}},
                 {"name": "store", "persistentVolumeClaim": {"claimName": "audit-store"}},
             ],
         }},
     }},
    {"apiVersion": "v1", "kind": "Service", "metadata": meta("auditor"),
     "spec": {"type": "ClusterIP", "selector": role, "ports": [{"name": "http", "port": 8090, "targetPort": "http", "protocol": "TCP"}]}},
    {"apiVersion": "networking.k8s.io/v1", "kind": "NetworkPolicy", "metadata": meta("auditor-ingress"),
     "spec": {"podSelector": {"matchLabels": {"rd-iroha3/role": "auditor"}}, "policyTypes": ["Ingress"],
              "ingress": [{"from": [{"podSelector": {"matchLabels": {"rd-iroha3/role": "gateway"}}}],
                           "ports": [{"protocol": "TCP", "port": 8090}]}]}},
    # R17 (key-holding pod: the auditor seed): its own narrow Egress policy, applied together with it. DNS and its own party's Torii only;
    # approvals arrive INBOUND through the gateway, so no cross-party and no internet egress.
    {"apiVersion": "networking.k8s.io/v1", "kind": "NetworkPolicy", "metadata": meta("auditor-egress"),
     "spec": {"podSelector": {"matchLabels": {"rd-iroha3/role": "auditor"}}, "policyTypes": ["Egress"],
              "egress": [
                  {"to": [{"namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": "kube-system"}},
                           "podSelector": {"matchLabels": {"k8s-app": "kube-dns"}}}],
                   "ports": [{"protocol": "UDP", "port": 53}, {"protocol": "TCP", "port": 53}]},
                  {"to": [{"podSelector": {"matchLabels": {"rd-iroha3/role": "peer", "rd-iroha3/party": party}}}], "ports": [{"protocol": "TCP", "port": 8080}]},
              ]}},
]
print("\n---\n".join(json.dumps(d, indent=2) for d in docs))
