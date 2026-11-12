"""Render the auditor-client-sign ConfigMap + Job + NetworkPolicy (see render.sh). Output: YAML stream of JSON documents, deterministic."""
import json
import sys

party, digest, csr_file = sys.argv[1:4]
ns = f"rd-iroha3-{party}"
csr = open(csr_file).read().strip() + "\n"
labels = {"app.kubernetes.io/part-of": "rd-iroha3", "rd-iroha3/party": party}
pod_labels = {**labels, "rd-iroha3/role": "auditor-client-sign", "rd/egress-locked": "true"}
meta = lambda name, lab: {"name": name, "namespace": ns, "labels": lab}
script = "\n".join([
    "set -eu",
    "umask 077",
    # the CSR again, inside the pod that holds the CA key: valid signature, subject exactly CN=<party>-auditor, EC P-256, no requested extensions
    "openssl req -in /csr/auditor-client.csr -noout -verify",
    f"test \"$(openssl req -in /csr/auditor-client.csr -noout -subject -nameopt RFC2253)\" = 'subject=CN={party}-auditor'",
    "openssl req -in /csr/auditor-client.csr -noout -text > /tmp/csr.txt",
    "grep -q prime256v1 /tmp/csr.txt",
    "if awk '/Requested Extensions:/{f=1;next} /Signature Algorithm/{f=0} f&&NF' /tmp/csr.txt | grep -q .; then echo 'CSR requests extensions' >&2; exit 1; fi",
    # the signer's OWN extensions: a leaf that can only authenticate a client
    "printf 'basicConstraints=CA:FALSE\\nkeyUsage=digitalSignature\\nextendedKeyUsage=clientAuth\\n' > /tmp/auditor-client.ext",
    "openssl x509 -req -in /csr/auditor-client.csr -CA /ca/ca.crt -CAkey /ca/ca.key -CAserial /tmp/ca.srl -CAcreateserial -days 365 -extfile /tmp/auditor-client.ext -out /tmp/auditor-client.crt",
    "openssl verify -CAfile /ca/ca.crt -purpose sslclient /tmp/auditor-client.crt >&2",
    "openssl x509 -in /tmp/auditor-client.crt -noout -subject -enddate -ext basicConstraints,extendedKeyUsage >&2",
    # ONLY the public certificate leaves the pod
    "cat /tmp/auditor-client.crt",
])
docs = [
    {"apiVersion": "v1", "kind": "ConfigMap", "metadata": meta("auditor-client-csr", labels), "data": {"auditor-client.csr": csr}},
    {"apiVersion": "batch/v1", "kind": "Job", "metadata": meta("auditor-client-sign", pod_labels),
     "spec": {"backoffLimit": 0, "activeDeadlineSeconds": 300, "ttlSecondsAfterFinished": 3600,
              "template": {"metadata": {"labels": pod_labels}, "spec": {
                  "restartPolicy": "Never", "automountServiceAccountToken": False, "enableServiceLinks": False, "imagePullSecrets": [{"name": "ghcr-pull"}],
                  "securityContext": {"runAsNonRoot": True, "runAsUser": 1001, "runAsGroup": 1001, "fsGroup": 1001, "seccompProfile": {"type": "RuntimeDefault"}},
                  "containers": [{"name": "sign", "image": f"ghcr.io/radityaaa43/iroha3-rd-driver@{digest}", "imagePullPolicy": "IfNotPresent",
                                  "command": ["/bin/sh", "-c", script],
                                  "resources": {"requests": {"cpu": "50m", "memory": "64Mi"}, "limits": {"cpu": "200m", "memory": "128Mi"}},
                                  "securityContext": {"allowPrivilegeEscalation": False, "readOnlyRootFilesystem": True, "capabilities": {"drop": ["ALL"]}},
                                  "volumeMounts": [{"name": "ca", "mountPath": "/ca", "readOnly": True}, {"name": "csr", "mountPath": "/csr", "readOnly": True},
                                                   {"name": "tmp", "mountPath": "/tmp"}]}],
                  "volumes": [{"name": "ca", "secret": {"secretName": "iroha3-role-ca", "defaultMode": 0o400, "items": [{"key": "ca.crt", "path": "ca.crt"}, {"key": "ca.key", "path": "ca.key"}]}},
                              {"name": "csr", "configMap": {"name": "auditor-client-csr"}},
                              {"name": "tmp", "emptyDir": {"medium": "Memory", "sizeLimit": "1Mi"}}]}}}},
    # the pod holds the CA key and needs NO network: deny-all egress, selected by the rd/egress-locked label
    {"apiVersion": "networking.k8s.io/v1", "kind": "NetworkPolicy", "metadata": meta("auditor-client-sign-egress", labels),
     "spec": {"podSelector": {"matchLabels": {"rd-iroha3/role": "auditor-client-sign", "rd/egress-locked": "true"}}, "policyTypes": ["Egress"], "egress": []}},
]
print("\n---\n".join(json.dumps(d, indent=2) for d in docs))
