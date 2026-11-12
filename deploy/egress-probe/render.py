"""Render the egress probe Pod + NetworkPolicy (see render.sh). Output: YAML stream of JSON documents, deterministic."""
import json
import sys

party, digest = sys.argv[1:3]
role = sys.argv[3] if len(sys.argv) > 3 else "default"
remotes = sys.argv[4:]
dmin = role == "driver-min"
driver_role, peer_role, gw_role, lb_role, aud_role = role in ("driver", "driver-min"), role == "peer", role == "gateway", role == "lb", role == "auditor"
kp_role = role == "auditor-api"
foreign = {"bi": "bank-a", "bank-a": "bank-b", "bank-b": "bi"}.get(party)  # ring inside cluster 1; bank-c has no other namespace on its cluster
ns = f"rd-iroha3-{party}"
gw_ns = ("bi", "bank-a", "bank-b") if party != "bank-c" else ("bank-c",)
labels = {"app.kubernetes.io/part-of": "rd-iroha3", "rd-iroha3/party": party}
pod_labels = ({"rd-iroha3/role": "driver"} if dmin else {**labels, "rd-iroha3/role": "driver"} if driver_role else {"rd-iroha3/role": "peer"} if peer_role
              else {"rd-iroha3/role": "gateway", "app.kubernetes.io/name": "gateway"} if gw_role  # W1 admits name=gateway; no part-of/party: the gateway Service/Deployment selectors cannot match
              else {**labels, "rd-iroha3/role": "auditor-client-api", "rd/egress-locked": "true"} if kp_role  # EXACTLY the keygen/put Job pod labels: selected by the real auditor-client-api-egress
              else {"rd-iroha3/role": "auditor", "rd/egress-locked": "true"} if aud_role  # EXACTLY the auditor pod labels: selected by the real auditor-egress; no part-of/party
              else {"rd-iroha3/role": "lb-probe"} if lb_role  # peer role: ONLY this label (no part-of/party: no selector of any Service/StatefulSet matches it)
              else {**labels, "rd-iroha3/role": "egress-probe", "rd/egress-locked": "true"})
std_lines = r'''  line="$(date -u +%T) dns_own=$(dns PEER) dns_ghcr=$(dns ghcr.io) peer:8080=$(tcp PEER 8080) status=[$(st PEER)] 1.1.1.1:443=$(tcp 1.1.1.1 443) 8.8.8.8:53=$(tcp 8.8.8.8 53) apiserver:443=$(tcp "$KUBERNETES_SERVICE_HOST" 443) ghcr($GH):443=$(tcp "$GH" 443)"
  for q in GWNS; do line="$line gw-$q:8443=$(dns gateway.rd-iroha3-$q.svc.cluster.local)/$(tcp gateway.rd-iroha3-$q.svc.cluster.local 8443)"; done
'''
foreign_peer = (r'''  line="$line foreign-peer-FOREIGN:8080=$(tcp FOREIGN-0.FOREIGN.rd-iroha3-FOREIGN.svc.cluster.local 8080)"
'''.replace("FOREIGN", foreign) if foreign else "")  # another party's peer Torii: blocked by driver-egress (also ingress-denied: not attributable on its own)
foreign_driver = (r'''  line="$line foreign-driver-FOREIGN:8091=$(tcp driver.rd-iroha3-FOREIGN.svc.cluster.local 8091)"
'''.replace("FOREIGN", foreign) if foreign else "")  # another party's driver: blocked by egress (also ingress-denied: not attributable on its own)
peer_lines = r'''  line="$(date -u +%T) dns_own=$(dns PEER) 1.1.1.1:443=$(tcp 1.1.1.1 443) 8.8.8.8:53=$(tcp 8.8.8.8 53) apiserver:443=$(tcp "$KUBERNETES_SERVICE_HOST" 443) ghcr($GH):443=$(tcp "$GH" 443)"
''' + "".join(
    f'''  line="$line peer-{q}:1337=$(tcp {q}-0.{q}.rd-iroha3-{q}.svc.cluster.local 1337) peer-{q}:8080=$(tcp {q}-0.{q}.rd-iroha3-{q}.svc.cluster.local 8080)"
''' for q in gw_ns) + r'''  for r in REMOTES; do line="$line remote-$r:1337=$(tcp $r 1337)"; done
''' + foreign_driver
gw_lines = r'''  line="$(date -u +%T) dns_own=$(dns PEER) peer:8080=$(tcp PEER 8080) driver:8091=$(tcp driver.rd-iroha3-P.svc.cluster.local 8091) bundle-server:80=$(tcp bundle-server.rd-zeto-P.svc.cluster.local 80) 1.1.1.1:443=$(tcp 1.1.1.1 443) 8.8.8.8:53=$(tcp 8.8.8.8 53) apiserver:443=$(tcp "$KUBERNETES_SERVICE_HOST" 443) ghcr($GH):443=$(tcp "$GH" 443)"
'''.replace("-P.svc", f"-{party}.svc").replace("-zeto-P", f"-zeto-{party}") + foreign_peer
aud_lines = r'''  line="$(date -u +%T) dns_own=$(dns PEER) peer:8080=$(tcp PEER 8080) 1.1.1.1:443=$(tcp 1.1.1.1 443) 8.8.8.8:53=$(tcp 8.8.8.8 53) apiserver:443=$(tcp "$KUBERNETES_SERVICE_HOST" 443) ghcr($GH):443=$(tcp "$GH" 443)"
''' + "".join(
    f'''  line="$line gw-{q}:8443=$(dns gateway.rd-iroha3-{q}.svc.cluster.local)/$(tcp gateway.rd-iroha3-{q}.svc.cluster.local 8443)"
''' for q in ("bi", "bank-a", "bank-b")) + r'''  for r in REMOTES; do line="$line gw-bank-c-lb-$r:8443=$(tcp $r 8443)"; done
'''
kp_lines = r'''  line="$(date -u +%T) apiserver-clusterip:443=$(tcp "$KUBERNETES_SERVICE_HOST" 443) 1.1.1.1:443=$(tcp 1.1.1.1 443) 8.8.8.8:53=$(tcp 8.8.8.8 53) dns_ghcr=$(dns ghcr.io) dns_own=$(dns PEER) ghcr($GH):443=$(tcp "$GH" 443)"
  for r in REMOTES; do line="$line apiserver-ep-$r:6443=$(tcp $r 6443)"; done
'''
lines = kp_lines.replace("REMOTES", " ".join(remotes)) if kp_role else aud_lines.replace("REMOTES", " ".join(remotes)) if aud_role else peer_lines.replace("REMOTES", " ".join(remotes)) if peer_role else gw_lines if gw_role else std_lines + (foreign_peer + foreign_driver if driver_role else "")
loop = r'''tcp() { timeout 4 bash -c 'exec 3<>/dev/tcp/$0/$1' "$1" "$2" 2>/dev/null; case $? in 0) echo OPEN;; 124) echo TIMEOUT;; 1) echo REFUSED;; *) echo rc$?;; esac; }
dns() { getent hosts "$1" >/dev/null 2>&1 && echo ok || echo NXDOMAIN; }
# PARSE-BEGIN (tested on real-format fixtures: scripts/test-egressprobe.sh; prints http/ctype/bytes and the three counts, NEVER the body)
parse() { local f=$1 off
  off=$(LC_ALL=C grep -abo -m1 $'^\r$' "$f" | head -1 | cut -d: -f1); off=${off:-0}
  echo "http=$(head -c 16 "$f" | head -1 | cut -d' ' -f2) ctype=$(LC_ALL=C head -c "$off" "$f" | tr -d '\r' | grep -ai '^content-type:' | head -1 | cut -d' ' -f2 | cut -d';' -f1) bytes=$(( $(wc -c < "$f") - off - 2 )) counts=[$(LC_ALL=C tail -c +"$((off + 3))" "$f" | tr -d '\n\r' | grep -aoE '"(peers|blocks|view_changes)" *: *[0-9]+' | tr -d '" ' | tr '\n' ' ')]"
}
# PARSE-END
st() { [ "$(tcp "$1" 8080)" = OPEN ] || { echo "http=na"; return; }; exec 3<>/dev/tcp/"$1"/8080 2>/dev/null || { echo "http=na"; return; }; printf 'GET /status HTTP/1.0\r\nHost: x\r\nAccept: application/json\r\n\r\n' >&3; timeout 4 cat <&3 > /tmp/st.raw; exec 3>&-; parse /tmp/st.raw; }
while true; do
  GH=$(getent ahostsv4 ghcr.io 2>/dev/null | awk 'NR==1{print $1}'); GH=${GH:-none}
@@LINES@@  echo "$line"
  sleep 15
done
'''.replace("@@LINES@@", lines).replace("PEER", f"{party}-0.{party}.rd-iroha3-{party}.svc.cluster.local").replace("GWNS", " ".join(gw_ns))
if peer_role or gw_role or aud_role or kp_role:  # no /status machinery in the peer/gateway-role probes (they open TCP connections only)
    a, b = loop.index("# PARSE-BEGIN"), loop.index("while true; do")
    loop = loop[:a] + loop[b:]
if lb_role:  # ONLY a TCP connect to each target LB on 8443: no DNS, no apiserver/ghcr/internet targets (its policy would not allow them anyway)
    loop = loop[:loop.index("dns() {")] + r'''while true; do
  line="$(date -u +%T)"
  for t in TARGETS; do line="$line lb-$t:8443=$(tcp $t 8443)"; done
  echo "$line"
  sleep 15
done
'''.replace("TARGETS", " ".join(remotes))
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
    {"apiVersion": "v1", "kind": "Pod", "metadata": meta("egress-probe-driver-min" if dmin else "egress-probe-driver" if driver_role else "egress-probe-peer" if peer_role else "egress-probe-gateway" if gw_role else "egress-probe-auditor" if aud_role else "egress-probe-auditor-api" if kp_role else "lb-probe" if lb_role else "egress-probe", pod_labels),
     "spec": {"restartPolicy": "Never", **({"activeDeadlineSeconds": 1800} if (gw_role or lb_role or aud_role or kp_role) else {}), "automountServiceAccountToken": False, "enableServiceLinks": False, "imagePullSecrets": [{"name": "ghcr-pull"}],
              "securityContext": {"runAsNonRoot": True, "runAsUser": 1001, "runAsGroup": 1001, "seccompProfile": {"type": "RuntimeDefault"}},
              "containers": [{"name": "probe", "image": f"ghcr.io/radityaaa43/iroha3-rd-driver@{digest}", "imagePullPolicy": "Always",
                              "command": ["bash", "-c", loop],
                              "resources": {"requests": {"cpu": "10m", "memory": "16Mi"}, "limits": {"cpu": "100m", "memory": "64Mi"}},
                              "securityContext": {"allowPrivilegeEscalation": False, "readOnlyRootFilesystem": True, "capabilities": {"drop": ["ALL"]}},
                              "volumeMounts": [{"name": "tmp", "mountPath": "/tmp"}]}],
              "volumes": [{"name": "tmp", "emptyDir": {"sizeLimit": "8Mi"}}]}},
]
if driver_role or peer_role or gw_role or aud_role or kp_role:  # driver: the Pod alone (no probe policy selects it); peer/gateway: the Pod alone, selected by the REAL peers-egress / gateway-egress
    docs = [d for d in docs if d["kind"] == "Pod"]
if lb_role:  # the LB probe brings its OWN policy: egress ONLY the target LB /32(s) on 8443 (the other cluster's LB: ipBlock is the one allowed form)
    docs = [{"apiVersion": "networking.k8s.io/v1", "kind": "NetworkPolicy", "metadata": meta("lb-probe-egress", labels),
             "spec": {"podSelector": {"matchLabels": {"rd-iroha3/role": "lb-probe"}}, "policyTypes": ["Egress"],
                      "egress": [{"to": [{"ipBlock": {"cidr": f"{t}/32"}} for t in remotes], "ports": [{"protocol": "TCP", "port": 8443}]}]}}] + [d for d in docs if d["kind"] == "Pod"]
print("\n---\n".join(json.dumps(d, indent=2) for d in docs))
