# One Iroha 3 validator in its own namespace (iroha3 PLAN S7). deploy/peers/render.sh replaces @PARTY@, @GENESIS_HASH8@
# and @BANKC_LB_CIDR@. Derived from deploy/k8s/base/statefulset.yaml:1-133 (same image, probes, resources, security
# settings, subPath mounts) with the new namespace, labels and PriorityClass `rd-iroha3-peer`. Secret `peer-@PARTY@`
# (that org's own peer.toml) and ConfigMap `genesis-@GENESIS_HASH8@` are created by their owners, not here.
apiVersion: v1
kind: Service
metadata:
  name: "@PARTY@"
  namespace: rd-iroha3-@PARTY@
  labels:
    app.kubernetes.io/part-of: rd-iroha3
    rd-iroha3/party: "@PARTY@"
spec:
  clusterIP: None
  # Peers must resolve each other before any of them is Ready (consensus needs quorum).
  publishNotReadyAddresses: true
  selector:
    app.kubernetes.io/part-of: rd-iroha3
    rd-iroha3/party: "@PARTY@"
    rd-iroha3/role: peer
  ports:
    - name: p2p
      port: 1337
    - name: api
      port: 8080
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: "@PARTY@"
  namespace: rd-iroha3-@PARTY@
  labels:
    app.kubernetes.io/part-of: rd-iroha3
    rd-iroha3/party: "@PARTY@"
spec:
  serviceName: "@PARTY@"
  replicas: 1
  podManagementPolicy: Parallel
  # Genesis/topology changes need a coordinated wipe of every peer PVC, never a rolling update.
  updateStrategy:
    type: OnDelete
  selector:
    matchLabels:
      app.kubernetes.io/part-of: rd-iroha3
      rd-iroha3/party: "@PARTY@"
      rd-iroha3/role: peer
  template:
    metadata:
      labels:
        app.kubernetes.io/part-of: rd-iroha3
        rd-iroha3/party: "@PARTY@"
        rd-iroha3/role: peer
    spec:
      automountServiceAccountToken: false
      enableServiceLinks: false
      priorityClassName: rd-iroha3-peer # cluster 1 only (deploy/ns/priorityclass.yaml)
      # Keep the 3 GiB peers off two nodes that are full (disk-attach slots, memory) and off each other. A
      # topologySpreadConstraint only counts pods of its own namespace, so the three peers (one per namespace) would not
      # see each other: soft podAntiAffinity with a namespaceSelector spreads them across the rd-iroha3 namespaces.
      # S7 window prerequisite (read-only, per candidate node): disk-attach slots left (cluster-1 slots were full before).
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
              - matchExpressions:
                  - key: kubernetes.io/hostname
                    operator: NotIn
                    values: [member-16033-node, member-16034-node]
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
            - weight: 100
              podAffinityTerm:
                topologyKey: kubernetes.io/hostname
                labelSelector:
                  matchLabels:
                    app.kubernetes.io/part-of: rd-iroha3
                    rd-iroha3/role: peer
                namespaceSelector:
                  matchLabels:
                    app.kubernetes.io/part-of: rd-iroha3
      securityContext:
        runAsNonRoot: true
        runAsUser: 1001
        runAsGroup: 1001
        fsGroup: 1001
        fsGroupChangePolicy: OnRootMismatch
        seccompProfile:
          type: RuntimeDefault
      # fsGroup leaves the PVC root setgid and group-writable (2775); iroha3d then fails P2P startup with
      # "SoraNet handshake negotiation failed". Run iroha3d on an owner-only, non-setgid subdir.
      initContainers:
        - name: storage-dir
          image: ghcr.io/radityaaa43/iroha3-rd-node:071e281e-stark
          command: [sh, -c, 'mkdir -p /pvc/data && chmod 00700 /pvc/data'] # 00700 also clears setgid
          resources:
            requests:
              cpu: 10m
              memory: 16Mi
            limits:
              cpu: 100m
              memory: 64Mi
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop: [ALL]
          volumeMounts:
            - name: data
              mountPath: /pvc
      containers:
        - name: iroha3d
          image: ghcr.io/radityaaa43/iroha3-rd-node:071e281e-stark
          command: [iroha3d]
          args: [--sora, --config, /config/peer.toml]
          env:
            - name: TELEMETRY_PROFILE
              value: extended
          ports:
            - name: p2p
              containerPort: 1337
            - name: api
              containerPort: 8080
          resources:
            requests:
              cpu: 250m
              memory: 1Gi
            limits:
              cpu: 2000m
              memory: 3Gi
          # /livez is process-only; /readyz includes consensus admission. timeoutSeconds 3 (default 1).
          startupProbe:
            httpGet:
              path: /livez
              port: api
            periodSeconds: 5
            failureThreshold: 60
          livenessProbe:
            httpGet:
              path: /livez
              port: api
            periodSeconds: 10
            timeoutSeconds: 3
            failureThreshold: 3
          readinessProbe:
            httpGet:
              path: /readyz
              port: api
            periodSeconds: 5
            timeoutSeconds: 3
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop: [ALL]
          # subPath: Secret/ConfigMap keys are symlinks and iroha3d rejects a symlinked config source.
          volumeMounts:
            - name: config
              mountPath: /config/peer.toml
              subPath: peer.toml
              readOnly: true
            - name: genesis
              mountPath: /genesis/genesis.signed.nrt
              subPath: genesis.signed.nrt
              readOnly: true
            - name: genesis
              mountPath: /genesis/genesis.expected_hash
              subPath: genesis.expected_hash
              readOnly: true
            - name: data
              mountPath: /storage
              subPath: data
      volumes:
        - name: config
          secret:
            secretName: peer-@PARTY@
            defaultMode: 0440 # root-owned, group 1001 (fsGroup) reads it
        - name: genesis
          configMap:
            name: genesis-@GENESIS_HASH8@
  volumeClaimTemplates:
    - metadata:
        name: data
      spec:
        accessModes: [ReadWriteOnce]
        storageClassName: alicloud-essd-wffc
        resources:
          requests:
            storage: 5Gi
---
# p2p 1337: peer pods of the other cluster-1 rd-iroha3 namespaces (cluster DNS side) and bank C's external address.
# [unverified] whether the LB/NAT keeps the source IP so that the ipBlock matches (analyst caveat): test before S8.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: peers-p2p
  namespace: rd-iroha3-@PARTY@
  labels:
    app.kubernetes.io/part-of: rd-iroha3
spec:
  podSelector:
    matchLabels:
      rd-iroha3/role: peer
  policyTypes: [Ingress]
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              app.kubernetes.io/part-of: rd-iroha3
          podSelector:
            matchLabels:
              rd-iroha3/role: peer
        - ipBlock:
            cidr: "@BANKC_LB_CIDR@"
      ports:
        - protocol: TCP
          port: 1337
---
# Torii 8080: only the own namespace's gateway pods (S14). The operator's `kubectl port-forward` goes through the API
# server and needs no rule.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: peers-torii
  namespace: rd-iroha3-@PARTY@
  labels:
    app.kubernetes.io/part-of: rd-iroha3
spec:
  podSelector:
    matchLabels:
      rd-iroha3/role: peer
  policyTypes: [Ingress]
  ingress:
    - from:
        - podSelector:
            matchLabels:
              rd-iroha3/role: gateway
      ports:
        - protocol: TCP
          port: 8080
---
# TEMPORARY: lets S8, S11 and S13 reach Torii before the gateways exist. S14 deletes it.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: torii-bootstrap
  namespace: rd-iroha3-@PARTY@
  labels:
    app.kubernetes.io/part-of: rd-iroha3
    rd-iroha3/temporary: "true"
  annotations:
    rd-iroha3/delete-at: "S14 (gateways in place)"
spec:
  podSelector:
    matchLabels:
      rd-iroha3/role: peer
  policyTypes: [Ingress]
  ingress:
    - from:
        - podSelector: {}
      ports:
        - protocol: TCP
          port: 8080
