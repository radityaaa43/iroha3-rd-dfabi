"""Render the egress probe Pod + NetworkPolicy (see render.sh). Output: YAML stream of JSON documents, deterministic."""
import json
import sys

party, digest = sys.argv[1:3]
ns = f"rd-iroha3-{party}"
gw_ns = ("bi", "bank-a", "bank-b") if party != "bank-c" else ("bank-c",)
labels = {"app.kubernetes.io/part-of": "rd-iroha3", "rd-iroha3/party": party}
pod_labels = {**labels, "rd-iroha3/role": "egress-probe", "rd/egress-locked": "true"}
loop = r'''tcp() { timeout 4 bash -c 'exec 3<>/dev/tcp/$0/$1' "$1" "$2" 2>/dev/null; case $? in 0) echo OPEN;; 124) echo TIMEOUT;; 1) echo REFUSED;; *) echo rc$?;; esac; }
dns() { getent hosts "$1" >/dev/null 2>&1 && echo ok || echo NXDOMAIN; }
st() { exec 3<>/dev/tcp/"$1"/8080 2>/dev/null || { echo na; return; }; printf 'GET /status HTTP/1.0\r\nHost: x\r\nAccept: application/json\r\n\r\n' >&3; timeout 4 cat <&3 | tr -d '\n' | grep -oE '"(peers|blocks|view_changes)":[0-9]+' | tr -d '"' | tr '\n' ' '; exec 3>&-; }
while true; do
  GH=$(getent ahostsv4 ghcr.io 2>/dev/null | awk 'NR==1{print $1}'); GH=${GH:-none}
  line="$(date -u +%T) dns_own=$(dns PEER) dns_ghcr=$(dns ghcr.io) peer:8080=$(tcp PEER 8080) status=[$(st PEER)] 1.1.1.1:443=$(tcp 1.1.1.1 443) 8.8.8.8:53=$(tcp 8.8.8.8 53) apiserver:443=$(tcp "$KUBERNETES_SERVICE_HOST" 443) ghcr($GH):443=$(tcp "$GH" 443)"
  for q in GWNS; do line="$line gw-$q:8443=$(dns gateway.rd-iroha3-$q.svc.cluster.local)/$(tcp gateway.rd-iroha3-$q.svc.cluster.local 8443)"; done
  echo "$line"
  sleep 15
done
'''.replace("PEER", f"{party}-0.{party}.rd-iroha3-{party}.svc.cluster.local").replace("GWNS", " ".join(gw_ns))
meta = lambda name, lab: {"name": name, "namespace": ns, "labels": lab}
docs = [
    {"apiVersion": "networking.k8s.io/v1", "kind": "NetworkPolicy", "metadata": meta("egress-probe-egress", labels),
     "spec": {"podSelector": {"matchLabels": {"rd-iroha3/role": "egress-probe", "rd/egress-locked": "true"}}, "policyTypes": ["Egress"],
              "egress": [
                  {"to": [{"namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": "kube-system"}}, "podSelector": {"matchLabels": {"k8s-app": "kube-dns"}}}],
                   "ports": [{"protocol": "UDP", "port": 53}, {"protocol": "TCP", "port": 53}]},
                  {"to": [{"podSelector": {"matchLabels": {"rd-iroha3/role": "peer", "rd-iroha3/party": party}}}], "ports": [{"protocol": "TCP", "port": 8080}]},
                  {"to": [{"namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": f"rd-iroha3-{q}"}}, "podSelector": {"matchLabels": {"rd-iroha3/role": "gateway"}}} for q in gw_ns],
                   "ports": [{"protocol": "TCP", "port": 8443}]},
              ]}},
    {"apiVersion": "v1", "kind": "Pod", "metadata": meta("egress-probe", pod_labels),
     "spec": {"restartPolicy": "Never", "automountServiceAccountToken": False, "enableServiceLinks": False, "imagePullSecrets": [{"name": "ghcr-pull"}],
              "securityContext": {"runAsNonRoot": True, "runAsUser": 1001, "runAsGroup": 1001, "seccompProfile": {"type": "RuntimeDefault"}},
              "containers": [{"name": "probe", "image": f"ghcr.io/radityaaa43/iroha3-rd-driver@{digest}", "imagePullPolicy": "Always",
                              "command": ["bash", "-c", loop],
                              "resources": {"requests": {"cpu": "10m", "memory": "16Mi"}, "limits": {"cpu": "100m", "memory": "64Mi"}},
                              "securityContext": {"allowPrivilegeEscalation": False, "readOnlyRootFilesystem": True, "capabilities": {"drop": ["ALL"]}},
                              "volumeMounts": [{"name": "tmp", "mountPath": "/tmp"}]}],
              "volumes": [{"name": "tmp", "emptyDir": {"sizeLimit": "8Mi"}}]}},
]
print("\n---\n".join(json.dumps(d, indent=2) for d in docs))
