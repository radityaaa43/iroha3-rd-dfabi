#!/usr/bin/env bash
# Static checks on the rendered peer manifests. Exit != 0 on any failure.
# Needs kubectl and jq. Writes nothing; the client dry-run still needs API discovery.
set -uo pipefail

cd "$(dirname "$0")/.."
IMAGE=ghcr.io/radityaaa43/iroha3-rd-node:071e281e-stark
fails=0
fail() { echo "FAIL: $*" >&2; fails=$((fails + 1)); }
ok() { echo "ok:   $*"; }

rendered=$(kubectl kustomize deploy/k8s 2>&1) || { echo "FAIL: kustomize: $rendered" >&2; exit 1; }
# multi-doc YAML -> JSON array of StatefulSets
sts=$(kubectl create --dry-run=client -o json -f - <<<"$rendered" 2>&1 |
  jq -sc '[.[] | (.items // [.])[] | select(.kind == "StatefulSet")]') || { echo "FAIL: parse: $sts" >&2; exit 1; }

n=$(jq length <<<"$sts")
[[ $n -eq 4 ]] && ok "4 StatefulSets" || fail "expected 4 StatefulSets, got $n"

jq -e 'map(.metadata.name) | sort == ["bank-a","bank-b","bank-c","bi"]' <<<"$sts" >/dev/null &&
  ok "names bi, bank-a, bank-b, bank-c" || fail "StatefulSet names"

# every peer-* / client-* Secret volume must belong to the StatefulSet's own party
bad=$(jq -r '.[] | .metadata.name as $p | .spec.template.spec.volumes[]? | .secret.secretName // empty
  | select(test("^(peer|client)-") and . != "peer-\($p)" and . != "client-\($p)") | "\($p) mounts \(.)"' <<<"$sts")
[[ -z $bad ]] && ok "no cross-party Secret mounts" || fail "cross-party Secret mount: $bad"

bad=$(jq -r '.[] | .metadata.name as $p | .spec.template.spec.containers[] | select(.image != "'"$IMAGE"'") | "\($p): \(.image)"' <<<"$sts")
[[ -z $bad ]] && ok "image $IMAGE" || fail "wrong image: $bad"

bad=$(jq -r '.[] | select(.spec.updateStrategy.type != "OnDelete") | .metadata.name' <<<"$sts")
[[ -z $bad ]] && ok "updateStrategy OnDelete" || fail "updateStrategy not OnDelete: $bad"

bad=$(jq -r '.[] | .spec.template.spec.containers[].env[]? | select((.name | test("PRIVATE_KEY")) and has("value")) | .name' <<<"$sts")
[[ -z $bad ]] && ok "no literal PRIVATE_KEY env" || fail "literal PRIVATE_KEY env: $bad"

bad=$(jq -r '.[] | select([.spec.template.spec.containers[].env[]? | select(.name == "TELEMETRY_PROFILE") | .value] != ["extended"]) | .metadata.name' <<<"$sts")
[[ -z $bad ]] && ok "TELEMETRY_PROFILE=extended" || fail "TELEMETRY_PROFILE != extended: $bad"

if (( fails )); then
  echo "FAILED: $fails check(s)" >&2
  exit 1
fi
echo "PASS"
