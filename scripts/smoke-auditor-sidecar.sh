#!/usr/bin/env bash
# Docker smoke of the auditor `gw-tls` sidecar config (deploy/auditor/render.sh --gw-tls) with the REAL pinned envoy (needs docker; CI only, never on the operator host;
# no cluster, throwaway certificates, no secrets): `envoy --mode validate` must accept the rendered envoy.yaml with the TLS files mounted where the pod mounts them.
#   scripts/smoke-auditor-sidecar.sh <envoy repo@sha256:..>
set -euo pipefail
cd "$(dirname "$0")/.."
(( $# == 1 )) || { echo "usage: smoke-auditor-sidecar.sh <envoy-image@digest>" >&2; exit 2; }
EI=$1
[[ $EI =~ @sha256:[0-9a-f]{64}$ ]] || { echo "the envoy image must be pinned by digest" >&2; exit 2; }
T=$(mktemp -d); chmod 755 "$T"; trap 'rm -rf -- "$T"' EXIT
P=$T/public; mkdir -p "$P/gateway-ca" "$T/server-cas" "$T/client"
D=sha256:$(printf 'a%.0s' $(seq 1 64)); H64=$(printf '0123456789abcdef%.0s' 1 2 3 4)
echo 11111111-2222-4333-8444-555555555555 > "$P/chain_id"; printf 'hash:%s#ABCD\n' "${H64^^}" > "$P/genesis.expected_hash"
jq -n '[ "bi","bank-a","bank-b","bank-c" | {party: ., public_key: ("ea0130" + .), pop_hex: "0xaa"} ]' > "$P/peers.json"
jq -n '{bi:"ed0120aa","bank-a":"ed0120bb","bank-b":"ed0120cc","bank-c":"ed0120dd","bi-gov":"ed0120ee"}' > "$P/accounts.json"
for q in bi bank-a bank-b bank-c; do
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -keyout "$T/ca-$q.key" -out "$P/gateway-ca/$q-server-ca.pem" -days 1 -subj "/CN=$q-smoke-ca" 2>/dev/null
  cp "$P/gateway-ca/$q-server-ca.pem" "$T/server-cas/"
done
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -keyout "$T/client/tls.key" -out "$T/client/tls.crt" -days 1 -subj "/CN=bank-a-auditor" 2>/dev/null
deploy/auditor/render.sh bank-a "$D" "$P" --keys-in-pvc --gw-tls --bank-c-gw-cidr 203.0.113.44/32 > "$T/out.yaml"
python3 -I - "$T" <<'PY'
import sys, yaml
t = sys.argv[1]
for d in yaml.safe_load_all(open(t + "/out.yaml")):
    if d and d["kind"] == "ConfigMap" and d["metadata"]["name"] == "auditor-gw-envoy":
        open(t + "/envoy.yaml", "w").write(d["data"]["envoy.yaml"])
PY
[[ -s $T/envoy.yaml ]] || { echo "no auditor-gw-envoy ConfigMap in the render" >&2; exit 1; }
chmod -R a+rX "$T"
docker run --rm -v "$T/envoy.yaml:/config/envoy.yaml:ro" -v "$T/server-cas:/server-cas:ro" -v "$T/client:/client:ro" "$EI" --mode validate -c /config/envoy.yaml 2>&1 | tail -3 | tee "$T/validate.log"
grep -q "configuration '/config/envoy.yaml' OK" "$T/validate.log" || { echo "envoy --mode validate did NOT accept the rendered sidecar config" >&2; exit 1; }
echo "ok: envoy --mode validate accepts the rendered auditor sidecar config"
