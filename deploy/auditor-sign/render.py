"""Render the auditor-client-sign ConfigMap + Job + NetworkPolicy (see render.sh). Output: YAML stream of JSON documents, deterministic."""
import json
import sys

stage, party = sys.argv[1:3]
ns = f"rd-iroha3-{party}"
labels = {"app.kubernetes.io/part-of": "rd-iroha3", "rd-iroha3/party": party}
pod_labels = {**labels, "rd-iroha3/role": "auditor-client-sign", "rd/egress-locked": "true"}
meta = lambda name, lab: {"name": name, "namespace": ns, "labels": lab}
if stage == "sign":
    digest, csr_file = sys.argv[3:5]
    csr = open(csr_file).read().strip() + "\n"
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

# ---- Option C (analyst ruling): the key is made IN a pod of the auditor's own namespace and written by that pod into the pre-created EMPTY Secret auditor-client-cert through a Role
# limited to get/update/patch on resourceNames [auditor-client-cert] (create cannot be limited by resourceNames: the org creates the empty Secret itself). Nothing but the CSR / public cert is printed.
SECRET = "auditor-client-cert"
api_pod_labels = {**labels, "rd-iroha3/role": "auditor-client-api", "rd/egress-locked": "true"}
def api_job(name, image, drv, init_script, script, mounts=(), volumes=()):
    sec = {"allowPrivilegeEscalation": False, "readOnlyRootFilesystem": True, "capabilities": {"drop": ["ALL"]}}
    res = {"requests": {"cpu": "50m", "memory": "64Mi"}, "limits": {"cpu": "200m", "memory": "128Mi"}}
    return {"apiVersion": "batch/v1", "kind": "Job", "metadata": meta(name, api_pod_labels),
            "spec": {"backoffLimit": 0, "activeDeadlineSeconds": 300, "ttlSecondsAfterFinished": 3600,
                     "template": {"metadata": {"labels": api_pod_labels}, "spec": {
                         "restartPolicy": "Never", "serviceAccountName": "auditor-client-api", "automountServiceAccountToken": True, "enableServiceLinks": False,
                         "imagePullSecrets": [{"name": "ghcr-pull"}],
                         "securityContext": {"runAsNonRoot": True, "runAsUser": 1001, "runAsGroup": 1001, "fsGroup": 1001, "seccompProfile": {"type": "RuntimeDefault"}},
                         # openssl lives in the (digest-pinned) DRIVER image (ca-certificates depends on it); kubectl lives in the TOOLS image: the two meet only in a MEMORY emptyDir
                         "initContainers": [{"name": "openssl", "image": f"ghcr.io/radityaaa43/iroha3-rd-driver@{drv}", "imagePullPolicy": "IfNotPresent", "command": ["/bin/sh", "-c", init_script],
                                             "resources": res, "securityContext": sec,
                                             "volumeMounts": [{"name": "work", "mountPath": "/work"}, *mounts]}],
                         "containers": [{"name": "run", "image": image, "imagePullPolicy": "IfNotPresent", "command": ["/bin/sh", "-c", script],
                                         "resources": res, "securityContext": sec, "env": [{"name": "HOME", "value": "/tmp"}],
                                         "volumeMounts": [{"name": "work", "mountPath": "/work", "readOnly": True}, *mounts, {"name": "tmp", "mountPath": "/tmp"}]}],
                         "volumes": [*volumes, {"name": "work", "emptyDir": {"medium": "Memory", "sizeLimit": "1Mi"}}, {"name": "tmp", "emptyDir": {"medium": "Memory", "sizeLimit": "1Mi"}}]}}}}
NAMES = "kubectl get secret " + SECRET + " -o go-template='{{range $k, $v := .data}}{{$k}} {{end}}' >&2"  # key NAMES only, never a value
if stage == "keygen":
    image, drv, api = sys.argv[3], sys.argv[4], sys.argv[5:]
    init_script = "\n".join([
        "set -eu",
        "umask 077",
        f"openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -keyout /work/tls.key -out /work/auditor-client.csr -subj '/CN={party}-auditor'",
    ])
    script = "\n".join([
        "set -eu",
        "umask 077",
        # never overwrite: the Secret must be empty (a lost key is a new identity + a policy update, never silent)
        "n=$(kubectl get secret " + SECRET + " -o go-template='{{if .data}}{{len .data}}{{else}}0{{end}}')",
        "test \"$n\" = 0 || { echo 'Secret " + SECRET + " is not empty: refusing to overwrite a key' >&2; exit 1; }",
        # the key reaches the API server through a patch FILE in the memory emptyDir (printf is a builtin: no key in any argv)
        "printf '{\"data\":{\"tls.key\":\"%s\"}}' \"$(base64 -w0 /work/tls.key)\" > /tmp/patch.json",
        "kubectl patch secret " + SECRET + " --type=merge --patch-file /tmp/patch.json >/dev/null",
        NAMES,
        # ONLY the public CSR leaves the pod
        "cat /work/auditor-client.csr",
    ])
    docs = [
        {"apiVersion": "v1", "kind": "ServiceAccount", "metadata": meta("auditor-client-api", labels), "automountServiceAccountToken": False},
        {"apiVersion": "rbac.authorization.k8s.io/v1", "kind": "Role", "metadata": meta("auditor-client-api", labels),
         "rules": [{"apiGroups": [""], "resources": ["secrets"], "resourceNames": [SECRET], "verbs": ["get", "patch", "update"]}]},
        {"apiVersion": "rbac.authorization.k8s.io/v1", "kind": "RoleBinding", "metadata": meta("auditor-client-api", labels),
         "roleRef": {"apiGroup": "rbac.authorization.k8s.io", "kind": "Role", "name": "auditor-client-api"},
         "subjects": [{"kind": "ServiceAccount", "name": "auditor-client-api", "namespace": ns}]},
        {"apiVersion": "networking.k8s.io/v1", "kind": "NetworkPolicy", "metadata": meta("auditor-client-api-egress", labels),
         "spec": {"podSelector": {"matchLabels": {"rd-iroha3/role": "auditor-client-api", "rd/egress-locked": "true"}}, "policyTypes": ["Egress"],
                  "egress": [{"to": [{"ipBlock": {"cidr": c}} for c in dict.fromkeys(a.split(":")[0] for a in api)],
                              "ports": [{"protocol": "TCP", "port": pt} for pt in dict.fromkeys(int(a.split(":")[1]) for a in api)]}]}},
        api_job("auditor-client-keygen", image, drv, init_script, script),
    ]
elif stage == "put":
    image, drv, crt_file = sys.argv[3:6]
    crt = open(crt_file).read().strip() + "\n"
    init_script = "\n".join([
        "set -eu",
        f"test \"$(openssl x509 -in /crt/tls.crt -noout -subject -nameopt RFC2253)\" = 'subject=CN={party}-auditor'",
    ])
    script = "\n".join([
        "set -eu",
        "printf '{\"data\":{\"tls.crt\":\"%s\"}}' \"$(base64 -w0 /crt/tls.crt)\" > /tmp/patch.json",
        "kubectl patch secret " + SECRET + " --type=merge --patch-file /tmp/patch.json >/dev/null",
        NAMES,
    ])
    docs = [
        {"apiVersion": "v1", "kind": "ConfigMap", "metadata": meta("auditor-client-crt", labels), "data": {"tls.crt": crt}},
        api_job("auditor-client-put", image, drv, init_script, script, mounts=[{"name": "crt", "mountPath": "/crt", "readOnly": True}], volumes=[{"name": "crt", "configMap": {"name": "auditor-client-crt"}}]),
    ]
print("\n---\n".join(json.dumps(d, indent=2) for d in docs))
