# External p2p address of one peer (iroha3 PLAN S6, DELTA 3). deploy/p2p/render.sh replaces @PARTY@ and @CLUSTER_LABEL@.
# Only the SoraNet p2p port 1337: never Torii 8080 (that stays behind the namespace's gateway, S14). The address that the cloud
# assigns goes into network/public/peers.addr.json (field `external`), and from there into `public_address` / `trusted_peers`.
# externalTrafficPolicy Local keeps the client source IP, which the peers-p2p ipBlock needs [unverified: test before S8].
# loadBalancerSourceRanges = the peer cluster's egress address(es) as /32 entries (render.sh --external-cidr, never wider).
# loadBalancerSourceRanges creates no ACL on the Alibaba CLB (besu's read-only diagnosis): the real whitelist is the pre-created
# access-control list named by --acl-id (annotations below). The peers-p2p NetworkPolicy (ipBlock, same /32 list) is the second layer.
# publishNotReadyAddresses: true is required. A peer's /readyz needs its peers, and a peer in the other cluster (bank-c) reaches this pod
# only through this LB. A Service publishes Ready pods only, so after all validators restart at once no pod is Ready, no LB has an
# endpoint, no peer reaches another, and none ever becomes Ready (deadlock, live incident 2026-11-17). The headless peer Service sets it too.
apiVersion: v1
kind: Service
metadata:
  name: p2p
  namespace: rd-iroha3-@PARTY@
  annotations:
    service.beta.kubernetes.io/alibaba-cloud-loadbalancer-acl-status: "on"
    service.beta.kubernetes.io/alibaba-cloud-loadbalancer-acl-type: "white"
    service.beta.kubernetes.io/alibaba-cloud-loadbalancer-acl-id: "@ACL_ID@"
  labels:
    app.kubernetes.io/part-of: rd-iroha3
    rd-iroha3/party: "@PARTY@"
spec:
  type: LoadBalancer
  publishNotReadyAddresses: true
  externalTrafficPolicy: Local
  loadBalancerSourceRanges:
@SOURCE_RANGES@
  selector:
    app.kubernetes.io/part-of: rd-iroha3
    rd-iroha3/party: "@PARTY@"
    rd-iroha3/role: peer
  ports:
    - name: p2p
      port: 1337
      targetPort: p2p
      protocol: TCP
