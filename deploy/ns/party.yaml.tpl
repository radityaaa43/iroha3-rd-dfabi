# Per-party namespace set (iroha3 PLAN S1a/S1b): bi, bank-a, bank-b on cluster 1; bank-c on cluster 2. deploy/ns/render.sh replaces @PARTY@ and prints it.
# Default-deny ingress only: the allow rules (p2p, Torii) arrive with the peers (S7). No egress policy, no workloads.
apiVersion: v1
kind: Namespace
metadata:
  name: rd-iroha3-@PARTY@
  labels:
    app.kubernetes.io/part-of: rd-iroha3
    rd-iroha3/party: "@PARTY@"
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-ingress
  namespace: rd-iroha3-@PARTY@
  labels:
    app.kubernetes.io/part-of: rd-iroha3
spec:
  podSelector: {}
  policyTypes: [Ingress]
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: party-admin
  namespace: rd-iroha3-@PARTY@
  labels:
    app.kubernetes.io/part-of: rd-iroha3
---
# The party's own deployer. Verbs follow deploy/runner/rbac.yaml:12-14 minus jobs and pods/exec; Secrets can be
# written but not read (create, update, patch), so one party cannot read another's keys through this role.
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: party-admin
  namespace: rd-iroha3-@PARTY@
  labels:
    app.kubernetes.io/part-of: rd-iroha3
rules:
  - apiGroups: [""]
    resources: [services, configmaps, persistentvolumeclaims, pods, pods/log]
    verbs: [get, list, watch, create, update, patch, delete]
  - apiGroups: [apps]
    resources: [statefulsets, deployments]
    verbs: [get, list, watch, create, update, patch, delete]
  - apiGroups: [networking.k8s.io]
    resources: [networkpolicies]
    verbs: [get, list, watch, create, update, patch, delete]
  - apiGroups: [""]
    resources: [secrets]
    verbs: [create, update, patch]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: party-admin
  namespace: rd-iroha3-@PARTY@
  labels:
    app.kubernetes.io/part-of: rd-iroha3
subjects:
  - kind: ServiceAccount
    name: party-admin
    namespace: rd-iroha3-@PARTY@
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: party-admin
