#!/usr/bin/env bash
# Print the throwaway PULL-TEST Pod of S13 gate G5 (pull test of the EXACT images before the auditor Deployment). Writes nothing, calls no cluster, renders NO Secret.
#   deploy/pull-test/render.sh <bi|bank-a|bank-b> <sha256:<64 hex> driver digest> <envoy repo@sha256:digest> <tools repo@sha256:digest>
# Objects in rd-iroha3-<party>: Pod pull-test (3 containers `driver`, `envoy`, `tools` = the three images of the auditor + client-key Jobs, each only `exit 0`, imagePullPolicy Always so the
# digest is really pulled; no SA token, no volumes, no env, no Secret; imagePullSecrets ghcr-pull) and NetworkPolicy pull-test-egress (deny-all: the kubelet pulls, the pod needs no network).
# Read afterwards (party-admin or cluster-admin read-only): status.containerStatuses[].imageID must contain each digest, no ImagePullBackOff/ErrImagePull; then delete the Pod and the policy.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
usage() { echo "usage: render.sh bi|bank-a|bank-b <sha256:<64 hex> driver digest> <envoy repo@sha256:digest> <tools repo@sha256:digest>" >&2; exit 2; }
(( $# == 4 )) || usage
party=$1 drv=$2 envoy=$3 tools=$4
case $party in bi | bank-a | bank-b) ;; *) usage ;; esac
[[ $drv =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "render.sh: the driver image must be pinned by a digest (sha256:<64 lowercase hex>): got '$drv'" >&2; exit 2; }
[[ $envoy =~ @sha256:[0-9a-f]{64}$ ]] || { echo "render.sh: the envoy image must be pinned by a digest (<repo>@sha256:<64 hex>): got '$envoy'" >&2; exit 2; }
[[ $tools =~ @sha256:[0-9a-f]{64}$ ]] || { echo "render.sh: the tools image must be pinned by a digest (<repo>@sha256:<64 hex>): got '$tools'" >&2; exit 2; }
exec python3 -I "$here/render.py" "$party" "$drv" "$envoy" "$tools"
