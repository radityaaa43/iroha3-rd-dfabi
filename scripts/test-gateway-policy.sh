#!/usr/bin/env bash
# Offline test of iroha3's own gateway policy (deploy/gateway/policy): `opa test` (rows, roles, CA binding, shipped data) and
# `opa fmt` must be clean. Needs the `opa` binary (CI: render-tests.yml installs the pinned v1.21.1, the version of the gateway image).
set -euo pipefail
cd "$(dirname "$0")/.."
command -v opa >/dev/null || { echo "FAIL: opa binary missing (render-tests.yml installs it)" >&2; exit 1; }
opa version | grep -q '^Version: 1.21.1$' || { echo "FAIL: opa $(opa version | head -1), want 1.21.1 (gateway image)" >&2; exit 1; }
[[ -z $(opa fmt -l deploy/gateway/policy) ]] || { echo "FAIL: opa fmt -l: $(opa fmt -l deploy/gateway/policy)" >&2; exit 1; }
opa test deploy/gateway/policy
echo "PASS"
