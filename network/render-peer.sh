#!/usr/bin/env bash
# One org renders ITS OWN peer.toml from the public template and its own custody keys (iroha3 PLAN S5/S7, DELTA 2a).
#   network/render-peer.sh <bi|bank-a|bank-b|bank-c> <custody-dir> <out-file>
# Public inputs in $PUBLIC_DIR (default network/public): peer.template.toml, peers.json, peers.addr.json ({party:{dns,external}}).
# The out file is created mode 0600 (refuses to overwrite); nothing is printed. Private keys never leave the custody dir except
# into that file, which becomes the Secret `peer-<party>` in this org's own namespace.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
party=${1:-} custody=${2:-} out=${3:-}
case $party in bi | bank-a | bank-b | bank-c) ;; *) echo "usage: render-peer.sh bi|bank-a|bank-b|bank-c <custody-dir> <out-file>" >&2; exit 2 ;; esac
[[ -d $custody && -n $out ]] || { echo "usage: render-peer.sh bi|bank-a|bank-b|bank-c <custody-dir> <out-file>" >&2; exit 2; }
PUBLIC_DIR=${PUBLIC_DIR:-$here/public}
for f in peer.template.toml peers.json peers.addr.json; do [[ -f $PUBLIC_DIR/$f ]] || { echo "render-peer.sh: $PUBLIC_DIR/$f is missing" >&2; exit 2; }; done
umask 077
exec python3 -I "$here/s5.py" render --template "$PUBLIC_DIR/peer.template.toml" --peers "$PUBLIC_DIR/peers.json" \
  --addrs "$PUBLIC_DIR/peers.addr.json" --party "$party" --custody "$custody" --out "$out"
