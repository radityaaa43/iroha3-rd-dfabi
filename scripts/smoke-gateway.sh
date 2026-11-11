#!/usr/bin/env bash
# Docker smoke of deploy/gateway/render.sh with the REAL pinned images (needs docker; no cluster, throwaway cert, no secrets):
#   1. `envoy --mode validate` accepts the rendered envoy.yaml (all filters, the XFCC settings and the TLS paths load);
#   2. OPA started with the rendered args and opa.yaml logs "Starting gRPC server" on 127.0.0.1:9191 (only the bundle pull may fail:
#      the bundle-server is not reachable from the host).
#   scripts/smoke-gateway.sh <envoy repo@sha256:..> <opa repo@sha256:..>
set -euo pipefail
cd "$(dirname "$0")/.."
(( $# == 2 )) || { echo "usage: smoke-gateway.sh <envoy-image@digest> <opa-image@digest>" >&2; exit 2; }
EI=$1 OI=$2
T=$(mktemp -d); chmod 755 "$T"; trap 'rm -rf -- "$T"' EXIT
mkdir "$T/mtls" "$T/ca"
cat > "$T/opa-in.yaml" <<'EOF'
plugins:
  envoy_ext_authz_grpc:
    addr: 127.0.0.1:9191
    path: gw/allow
keys:
  bi:
    algorithm: RS256
    key: |
      -----BEGIN PUBLIC KEY-----
      MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8A
      -----END PUBLIC KEY-----
EOF
deploy/gateway/render.sh bi --envoy-image "$EI" --opa-image "$OI" --opa-config "$T/opa-in.yaml" > "$T/bi.yaml"
python3 -I - "$T" <<'PY'
import sys, yaml
t = sys.argv[1]
for d in yaml.safe_load_all(open(t + "/bi.yaml")):
    if d["kind"] == "ConfigMap":
        for k, v in d["data"].items():
            open(f"{t}/{k}", "w").write(v)
    if d["kind"] == "Deployment":
        opa = [c for c in d["spec"]["template"]["spec"]["containers"] if c["name"] == "opa"][0]
        open(t + "/opa.args", "w").write("\n".join(opa["args"]) + "\n")
PY
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -keyout "$T/mtls/tls.key" -out "$T/mtls/tls.crt" -days 1 -subj "/CN=gw-smoke" 2>/dev/null
cp "$T/mtls/tls.crt" "$T/ca/ca.crt"; chmod -R a+rX "$T"
docker run --rm -v "$T/envoy.yaml:/config/envoy.yaml:ro" -v "$T/mtls:/mtls:ro" -v "$T/ca:/client-ca:ro" "$EI" --mode validate -c /config/envoy.yaml 2>&1 | tail -3
mapfile -t args < "$T/opa.args"
out=$(timeout 8 docker run --rm -v "$T/opa.yaml:/config/opa.yaml:ro" "$OI" "${args[@]}" 2>&1 || true)
grep -q 'Starting gRPC server' <<<"$out" && echo "ok:   opa starts the ext_authz gRPC server with the rendered args" || { echo "FAIL: opa did not start the gRPC server:" >&2; echo "$out" | tail -8 >&2; exit 1; }
echo "PASS"
