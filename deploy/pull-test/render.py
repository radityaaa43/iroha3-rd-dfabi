"""Render the pull-test Pod + NetworkPolicy (see render.sh). Output: YAML stream of JSON documents, deterministic."""
import json
import sys

party, drv, envoy, tools = sys.argv[1:5]
ns = f"rd-iroha3-{party}"
labels = {"app.kubernetes.io/part-of": "rd-iroha3", "rd-iroha3/party": party}
pod_labels = {**labels, "rd-iroha3/role": "pull-test", "rd/egress-locked": "true"}
meta = lambda name, lab: {"name": name, "namespace": ns, "labels": lab}


def container(name, image):
    return {"name": name, "image": image, "imagePullPolicy": "Always", "command": ["/bin/sh", "-c", "exit 0"],
            "resources": {"requests": {"cpu": "10m", "memory": "16Mi"}, "limits": {"cpu": "100m", "memory": "64Mi"}},
            "securityContext": {"allowPrivilegeEscalation": False, "readOnlyRootFilesystem": True, "capabilities": {"drop": ["ALL"]}}}


docs = [
    {"apiVersion": "v1", "kind": "Pod", "metadata": meta("pull-test", pod_labels),
     "spec": {"restartPolicy": "Never", "activeDeadlineSeconds": 600, "automountServiceAccountToken": False, "enableServiceLinks": False, "imagePullSecrets": [{"name": "ghcr-pull"}],
              "securityContext": {"runAsNonRoot": True, "runAsUser": 1001, "runAsGroup": 1001, "seccompProfile": {"type": "RuntimeDefault"}},
              "containers": [container("driver", f"ghcr.io/radityaaa43/iroha3-rd-driver@{drv}"), container("envoy", envoy), container("tools", tools)]}},
    {"apiVersion": "networking.k8s.io/v1", "kind": "NetworkPolicy", "metadata": meta("pull-test-egress", labels),
     "spec": {"podSelector": {"matchLabels": {"rd-iroha3/role": "pull-test", "rd/egress-locked": "true"}}, "policyTypes": ["Egress"], "egress": []}},
]
print("\n---\n".join(json.dumps(d, indent=2) for d in docs))
