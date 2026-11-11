# External p2p address of one peer (iroha3 PLAN S6, DELTA 3). deploy/p2p/render.sh replaces @PARTY@ and @CLUSTER_LABEL@.
# Only the SoraNet p2p port 1337: never Torii 8080 (that stays behind the namespace's gateway, S14). The address that the cloud
# assigns goes into network/public/peers.addr.json (field `external`), and from there into `public_address` / `trusted_peers`.
# externalTrafficPolicy Local keeps the client source IP, which the peers-p2p ipBlock needs [unverified: test before S8].
# [unverified] The LB is reachable from the internet unless an access-control list is set; the ACL annotation names and the
# source ranges of the other clusters are not decided here (SoraNet handshake still authenticates the peer).
apiVersion: v1
kind: Service
metadata:
  name: p2p
  namespace: rd-iroha3-@PARTY@
  labels:
    app.kubernetes.io/part-of: rd-iroha3
    rd-iroha3/party: "@PARTY@"
spec:
  type: LoadBalancer
  externalTrafficPolicy: Local
  selector:
    app.kubernetes.io/part-of: rd-iroha3
    rd-iroha3/party: "@PARTY@"
    rd-iroha3/role: peer
  ports:
    - name: p2p
      port: 1337
      targetPort: p2p
      protocol: TCP
