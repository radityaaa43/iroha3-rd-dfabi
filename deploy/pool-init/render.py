"""Render the S13 pool-init Job (see render.sh). Output: YAML stream of JSON documents, deterministic."""
import json
import re
import sys
import tomllib

digest, pub, network, rd_reserve, dfabi_reserve = sys.argv[1:6]
PARTIES = ["bi", "bank-a", "bank-b", "bank-c"]
ns = "rd-iroha3-bi"
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
labels = {"app.kubernetes.io/part-of": "rd-iroha3", "rd-iroha3/party": "bi"}
role = {**labels, "rd-iroha3/role": "pool-init"}
# R17: a Job that mounts a key Secret is egress-locked: this label is what its own Egress NetworkPolicy (below) selects.
locked = {**role, "rd/egress-locked": "true"}
bi_torii = "http://bi-0.bi.rd-iroha3-bi.svc.cluster.local:8080/"
toml = "\n".join(
    [
        "# rd-dfabi config of the S13 pool-init Job (public values only; the governance seed comes from Secret bi-gov-key).",
        f'chain = "{chain}"',
        'network_id_file = "/genesis/genesis.expected_hash"',
        'account_domain = "wonderland.universal"',
        'party = "bi"',
        'client_toml = "/work/client.toml"',
        'peers_json = "/config/peers.json"',
        'key_dir = "/pools/keys"',
        'pools_file = "/pools/pools.json"',
        f'fee_asset = "{fee}"',
        'auditor_url = "unused-by-pool-init:8090"',
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
        "# 2-of-3 auditors (BI, org A, org B), each reached ONLY through its own party's gateway over mutual TLS (S13 transport A)",
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
)
tomllib.loads(toml)
meta = lambda name: {"name": name, "namespace": ns, "labels": labels}
script = " && ".join(
    [
        "set -eu",
        # BI's two origin (reserve) notes are WRITTEN here by pool-init (create_new): the persistent PVC, owner-only. bi.note stays on
        # the Secret mount (only linked, never copied); the link is made once and kept for later runs on the same PVC.
        "mkdir -p /pools/keys",
        "chmod 700 /pools/keys",
        "{ test -L /pools/keys/bi.note || ln -s /keys/bi.note /pools/keys/bi.note; }",
        "install -m 600 /gov/bi-gov.seed /work/bi-gov.seed",
        f"rd-dfabi keys client-toml /work bi-gov --torii {bi_torii} --chain {chain} --network-id-file /genesis/genesis.expected_hash",
        "rm -f /work/bi-gov.seed",
        f"rd-dfabi pool-init /config/rd-dfabi.toml --rd-reserve {rd_reserve} --dfabi-reserve {dfabi_reserve}",
    ]
)
gateway = lambda p: {"namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": f"rd-iroha3-{p}"}},
                     "podSelector": {"matchLabels": {"rd-iroha3/role": "gateway"}}}
egress_policy = {"apiVersion": "networking.k8s.io/v1", "kind": "NetworkPolicy", "metadata": meta("pool-init-egress"),
    "spec": {"podSelector": {"matchLabels": {"rd-iroha3/role": "pool-init", "rd/egress-locked": "true"}}, "policyTypes": ["Egress"],
             "egress": [
                 # cluster DNS only
                 {"to": [{"namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": "kube-system"}},
                          "podSelector": {"matchLabels": {"k8s-app": "kube-dns"}}}],
                  "ports": [{"protocol": "UDP", "port": 53}, {"protocol": "TCP", "port": 53}]},
                 # BI's own Torii (the governance transaction)
                 {"to": [{"podSelector": {"matchLabels": {"rd-iroha3/role": "peer", "rd-iroha3/party": "bi"}}}], "ports": [{"protocol": "TCP", "port": 8080}]},
                 # the three auditor gateways (mutual TLS), nothing else
                 {"to": [gateway(p) for p in ("bi", "bank-a", "bank-b")], "ports": [{"protocol": "TCP", "port": 8443}]},
             ]}}
docs = [
    {"apiVersion": "v1", "kind": "ConfigMap", "metadata": meta("pool-init-config"),
     "data": {"rd-dfabi.toml": toml, "peers.json": json.dumps(peers, indent=2) + "\n"}},
    {"apiVersion": "v1", "kind": "PersistentVolumeClaim", "metadata": meta("pools-index"),
     "spec": {"storageClassName": "alicloud-essd-wffc", "accessModes": ["ReadWriteOnce"], "resources": {"requests": {"storage": "1Gi"}}}},
    {"apiVersion": "batch/v1", "kind": "Job", "metadata": {**meta("pool-init"), "labels": locked},
     "spec": {
         "backoffLimit": 0,
         "activeDeadlineSeconds": 1800,
         "ttlSecondsAfterFinished": 86400,
         "template": {"metadata": {"labels": locked}, "spec": {
             "restartPolicy": "Never",
             "automountServiceAccountToken": False,
             "enableServiceLinks": False,
             "imagePullSecrets": [{"name": "ghcr-pull"}],
             "securityContext": {"runAsNonRoot": True, "runAsUser": 1001, "runAsGroup": 1001, "fsGroup": 1001,
                                 "seccompProfile": {"type": "RuntimeDefault"}},
             "containers": [{
                 "name": "pool-init",
                 "image": f"ghcr.io/radityaaa43/iroha3-rd-driver@{digest}",
                 "imagePullPolicy": "IfNotPresent",
                 "command": ["/bin/sh", "-c", script],
                 "resources": {"requests": {"cpu": "100m", "memory": "256Mi"}, "limits": {"cpu": "1", "memory": "1Gi"}},
                 "securityContext": {"allowPrivilegeEscalation": False, "readOnlyRootFilesystem": True, "capabilities": {"drop": ["ALL"]}},
                 "volumeMounts": [
                     {"name": "gov", "mountPath": "/gov", "readOnly": True},
                     {"name": "keys", "mountPath": "/keys", "readOnly": True},
                     {"name": "config", "mountPath": "/config", "readOnly": True},
                     {"name": "genesis", "mountPath": "/genesis", "readOnly": True},
                     {"name": "client-cert", "mountPath": "/tls/client", "readOnly": True},
                     {"name": "server-cas", "mountPath": "/tls/cas", "readOnly": True},
                     {"name": "work", "mountPath": "/work"},
                     {"name": "pools", "mountPath": "/pools"},
                 ],
             }],
             "volumes": [
                 {"name": "gov", "secret": {"secretName": "bi-gov-key", "defaultMode": 0o400,
                                            "items": [{"key": "bi-gov.seed", "path": "bi-gov.seed"}]}},
                 {"name": "keys", "secret": {"secretName": "bi-keys", "defaultMode": 0o400, "items": [{"key": "bi.note", "path": "bi.note"}]}},
                 {"name": "config", "configMap": {"name": "pool-init-config"}},
                 {"name": "genesis", "configMap": {"name": f"genesis-{h8}"}},
                 {"name": "client-cert", "secret": {"secretName": "iroha3-client-cert", "defaultMode": 0o400,
                                                    "items": [{"key": "tls.crt", "path": "tls.crt"}, {"key": "tls.key", "path": "tls.key"}]}},
                 {"name": "server-cas", "configMap": {"name": "gateway-server-cas"}},
                 {"name": "work", "emptyDir": {"medium": "Memory", "sizeLimit": "1Mi"}},
                 {"name": "pools", "persistentVolumeClaim": {"claimName": "pools-index"}},
             ],
         }},
     }},
    egress_policy,
]
print("\n---\n".join(json.dumps(d, indent=2) for d in docs))
