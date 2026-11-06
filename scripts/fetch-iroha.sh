#!/usr/bin/env bash
# Fetch upstream Iroha at the pinned commit into ./.iroha-src (no submodules) and seed Cargo.lock from it.
# Same recipe as iroha3-rd-node-build/.github/workflows/build-image.yml. Needs network; ~650 MB of source.
set -euo pipefail
COMMIT=071e281e778c5928cab4d6e007b7ddc9b050df27
cd "$(dirname "$0")/.."
if [ ! -d .iroha-src/.git ]; then git init -q .iroha-src; fi
git -C .iroha-src fetch -q --depth 1 https://github.com/hyperledger-iroha/iroha "$COMMIT"
git -C .iroha-src checkout -q --detach FETCH_HEAD
[ "$(git -C .iroha-src rev-parse HEAD)" = "$COMMIT" ] || { echo "wrong commit" >&2; exit 1; }
# Seed the lock only once; afterwards the committed Cargo.lock wins so shared crates stay at upstream's versions.
[ -f Cargo.lock ] || cp .iroha-src/Cargo.lock Cargo.lock
echo "iroha $COMMIT ready in .iroha-src"
