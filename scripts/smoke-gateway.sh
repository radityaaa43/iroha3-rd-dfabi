#!/usr/bin/env bash
# Docker smoke of deploy/gateway/render.sh with the REAL pinned images (needs docker; no cluster, throwaway cert, no secrets):
#   1. `envoy --mode validate` accepts the rendered envoy.yaml (all filters, the XFCC settings and the TLS paths load);
#   2. OPA started with the rendered args, opa.yaml and the gateway-policy files (iroha3's own policy, no bundle) logs
#      "Starting gRPC server" on 127.0.0.1:9191 and no compile error.
#   scripts/smoke-gateway.sh <envoy repo@sha256:..> <opa repo@sha256:..>
set -euo pipefail
cd "$(dirname "$0")/.."
(( $# == 2 )) || { echo "usage: smoke-gateway.sh <envoy-image@digest> <opa-image@digest>" >&2; exit 2; }
EI=$1 OI=$2
T=$(mktemp -d); chmod 755 "$T"; trap 'rm -rf -- "$T"' EXIT
mkdir "$T/mtls" "$T/ca" "$T/policy"
deploy/gateway/render.sh bi --envoy-image "$EI" --opa-image "$OI" > "$T/bi.yaml"
python3 -I - "$T" <<'PY'
import sys, yaml
t = sys.argv[1]
for d in yaml.safe_load_all(open(t + "/bi.yaml")):
    if d["kind"] == "ConfigMap":
        sub = "/policy" if d["metadata"]["name"] == "gateway-policy" else ""
        for k, v in d["data"].items():
            open(f"{t}{sub}/{k}", "w").write(v)
    if d["kind"] == "Deployment":
        opa = [c for c in d["spec"]["template"]["spec"]["containers"] if c["name"] == "opa"][0]
        open(t + "/opa.args", "w").write("\n".join(opa["args"]) + "\n")
PY
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -keyout "$T/mtls/tls.key" -out "$T/mtls/tls.crt" -days 1 -subj "/CN=gw-smoke" 2>/dev/null
cp "$T/mtls/tls.crt" "$T/ca/ca.crt"; chmod -R a+rX "$T"
docker run --rm -v "$T/envoy.yaml:/config/envoy.yaml:ro" -v "$T/mtls:/mtls:ro" -v "$T/ca:/client-ca:ro" "$EI" --mode validate -c /config/envoy.yaml 2>&1 | tail -3
mapfile -t args < "$T/opa.args"
out=$(timeout 8 docker run --rm -v "$T/opa.yaml:/config/opa.yaml:ro" -v "$T/policy:/policy:ro" "$OI" "${args[@]}" 2>&1 || true)
grep -qi 'error' <<<"$out" && { echo "FAIL: opa reported an error:" >&2; echo "$out" | grep -i error | head -5 >&2; exit 1; }
grep -q 'Starting gRPC server' <<<"$out" && echo "ok:   opa starts the ext_authz gRPC server with the rendered args" || { echo "FAIL: opa did not start the gRPC server:" >&2; echo "$out" | tail -8 >&2; exit 1; }
echo "PASS"
