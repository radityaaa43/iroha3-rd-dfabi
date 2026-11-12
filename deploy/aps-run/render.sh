#!/usr/bin/env bash
# Print ONE BI coordinator Job for the shared private-settlement pools (iroha3 S13 RED, S15). Writes nothing, calls no cluster,
# renders NO Secret. Namespace rd-iroha3-bi ONLY.
#   deploy/aps-run/render.sh <sha256:digest> <public-dir> <name> <bank-c-gateway-lb-ipv4> <rd-dfabi command...>
#   command: pay --asset rd|dfabi --from bi --to bi --amount N   |   wallet --party bi   |   pool-history --asset rd|dfabi
# The upstream quorum client posts availability shares, prepare and commit votes to all FOUR committee Torii with plain HTTP, and a
# party reaches another party's Torii only through that party's gateway (mTLS, OPA rows 5-7 for role bi). So a native sidecar
# `gw-tls` (pinned envoy) listens on 127.0.0.1:18101-18104 and originates mTLS to the four gateways with BI's iroha3-client-cert
# (CN bi), pinning each party's own server CA; the coordinator's [torii] is those loopback URLs. bank-c's gateway is on cluster 2:
# reached by its gateway-lb address. The k-of-n /approve calls use the driver's own [tls] client to the three auditor gateways.
# Keys: bi-keys (bi.seed, bi.note: BI's own account and note key, as the driver) linked into key_dir /pools/keys on PVC pools-index,
# where pool-init wrote BI's origin notes. The governance seed is never mounted. backoffLimit 0: a retry would be a NEW bundle.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
usage() { echo "usage: render.sh <sha256:<64 hex>> <public-dir> <name> <bank-c-gw-ipv4> pay --asset rd|dfabi --from bi --to bi --amount N | wallet --party bi | pool-history --asset rd|dfabi" >&2; exit 2; }
(( $# >= 5 )) || usage
digest=$1 pub=$2 name=$3 ip=$4; shift 4
[[ $digest =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "render.sh: the image must be pinned by a digest (sha256:<64 lowercase hex>): got '$digest'" >&2; exit 2; }
[[ -d $pub ]] || { echo "render.sh: public dir $pub not found" >&2; exit 2; }
[[ $name =~ ^[a-z0-9]([a-z0-9-]{0,30}[a-z0-9])?$ ]] || { echo "render.sh: run name '$name' must be lowercase alnum/-, at most 32" >&2; exit 2; }
python3 -I -c 'import ipaddress as i,sys; a=i.ip_address(sys.argv[1]); sys.exit(0 if a.version == 4 and not any(a in i.ip_network(n) for n in ("10.0.0.0/8","172.16.0.0/12","192.168.0.0/16","169.254.0.0/16","127.0.0.0/8","100.64.0.0/10","0.0.0.0/8")) else 1)' "$ip" 2>/dev/null \
  || { echo "render.sh: bank-c gateway address '$ip' must be a public IPv4 (its gateway-lb)" >&2; exit 2; }
case "$*" in
  "pay --asset rd --from bi --to bi --amount "* | "pay --asset dfabi --from bi --to bi --amount "*)
    (( $# == 9 )) || usage; [[ ${9} =~ ^[1-9][0-9]{0,17}$ ]] || { echo "render.sh: amount '${9}' must be a positive integer" >&2; exit 2; } ;;
  "pay "*) echo "render.sh: pay is BI -> bi only here (the Job holds BI's keys only): $*" >&2; exit 2 ;;
  "wallet --party bi" | "pool-history --asset rd" | "pool-history --asset dfabi") ;;
  *) echo "render.sh: command must be pay/wallet/pool-history (got '$*')" >&2; exit 2 ;;
esac
for f in chain_id genesis.expected_hash peers.json gateway-ca/bi-server-ca.pem gateway-ca/bank-a-server-ca.pem gateway-ca/bank-b-server-ca.pem gateway-ca/bank-c-server-ca.pem; do
  [[ -f $pub/$f ]] || { echo "render.sh: $pub/$f is missing" >&2; exit 2; }; done
[[ -z $(find "$pub" \( -name '*.seed' -o -name '*.note' -o -name '*.hybrid' -o -name private.key \) -print -quit) ]] \
  || { echo "render.sh: $pub holds private material (*.seed, *.note, *.hybrid or private.key); public files only" >&2; exit 2; }
exec python3 -I "$here/render.py" "$digest" "$pub" "$here/../../network" "$name" "$ip" "$@"
