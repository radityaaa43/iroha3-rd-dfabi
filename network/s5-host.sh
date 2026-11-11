#!/usr/bin/env bash
# GO-S5, host only (no cluster call): all four orgs' keys, the public files, the signed genesis (iroha3 PLAN S5, DELTA 1/2).
# ALL private material lives ONLY under $SHM (default /dev/shm/iroha3-new, tmpfs, umask 077): per-party custody dirs, the signer
# key and the throwaway localnet of assemble-s5.sh. Only PUBLIC outputs are written to disk under $PUB (default ~/iroha3-new/public).
# The signer key is shredded right after the assembly. Per-party private files stay in $SHM until each party's Secret is created
# (S7a/S8, then shredded there) and the account seeds until S9.
#   LB_BI=<ip> LB_BANK_A=<ip> LB_BANK_B=<ip> LB_BANK_C=<ip> network/s5-host.sh
# Needs docker, jq, python3. Env: NODE_IMAGE, DRIVER_IMAGE (pinned), SHM, PUB, EPOCH_LENGTH (default 2^60, user decision "iroha iii").
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
NODE_IMAGE=${NODE_IMAGE:-ghcr.io/radityaaa43/iroha3-rd-node:071e281e-stark}
DRIVER_IMAGE=${DRIVER_IMAGE:-ghcr.io/radityaaa43/iroha3-rd-driver:33d5ffac}
SHM=${SHM:-/dev/shm/iroha3-new}
PUB=${PUB:-$HOME/iroha3-new/public}
die() { echo "s5-host.sh: $*" >&2; exit 2; }
for v in LB_BI LB_BANK_A LB_BANK_B LB_BANK_C; do [[ ${!v:-} =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "$v must be the LoadBalancer IPv4 address of that party"; done
[[ $SHM == /dev/shm/* || ${S5_HOST_ALLOW_DISK:-} == 1 ]] || die "SHM must be under /dev/shm (private keys never on disk); S5_HOST_ALLOW_DISK=1 is for tests only"
[[ ! -e $SHM && ! -e $PUB ]] || die "$SHM or $PUB exists; refusing to reuse (would mix keys)"
umask 077
mkdir -p "$SHM" "$SHM/tmp" "$SHM/bin" "$PUB"; chmod 700 "$SHM" "$SHM/tmp" "$SHM/bin"; chmod 755 "$PUB"
U="$(id -u):$(id -g)"
wrap() { printf '#!/usr/bin/env bash\nexec docker run --rm -i --user %s -v %s:%s -v %s:%s -w %s --entrypoint %s %s "$@"\n' "$U" "$SHM" "$SHM" "$PUB" "$PUB" "$SHM" "$2" "$3" > "$SHM/bin/$1"; chmod 700 "$SHM/bin/$1"; }
wrap kagami kagami "$NODE_IMAGE"; wrap iroha iroha "$NODE_IMAGE"; wrap rd-dfabi /usr/local/bin/rd-dfabi "$DRIVER_IMAGE"
export KAGAMI="$SHM/bin/kagami" IROHA="$SHM/bin/iroha" RDDFABI="$SHM/bin/rd-dfabi" TMPDIR="$SHM/tmp"

lines=()
for p in bi bank-a bank-b bank-c; do lines+=("$("$here/keygen-party.sh" "$p" "$SHM/$p")"); done
printf '%s\n' "${lines[@]}" | jq -s '[.[] | {party, public_key, pop_hex}]' > "$PUB/peers.json"
printf '%s\n' "${lines[@]}" | jq -s '(map({(.party): .account_public_key}) | add) + {"bi-gov": (map(select(.party=="bi"))[0].gov_account_public_key)}' > "$PUB/accounts.json"
tri=(); i=0
for l in "${lines[@]}"; do i=$((i + 1)); jq -c '.mint_finality' <<<"$l" > "$SHM/triple$i.json"; tri+=("$SHM/triple$i.json"); done
"$RDDFABI" keys mint-finality-roster "$PUB/kagemusha-mint-finality-public.json" "${tri[@]}" >/dev/null
jq -n --arg bi "$LB_BI" --arg a "$LB_BANK_A" --arg b "$LB_BANK_B" --arg c "$LB_BANK_C" '
  def e($p; $ip): {($p): {dns: ($p + "-0." + $p + ".rd-iroha3-" + $p + ".svc.cluster.local:1337"), external: ($ip + ":1337")}};
  e("bi"; $bi) + e("bank-a"; $a) + e("bank-b"; $b) + e("bank-c"; $c)' > "$PUB/peers.addr.json"

# the signer: its own fresh ed25519 key in tmpfs, shredded right after the assembly
"$KAGAMI" keys --algorithm ed25519 --out-dir "$SHM/signer" >/dev/null
export GENESIS_PRIVATE_KEY_FILE="$SHM/signer/private.key" GENESIS_PUBLIC_KEY="$(tr -d '\n' < "$SHM/signer/public.key")" PUBLIC_DIR="$PUB"
"$here/assemble-s5.sh"
shred -u "$SHM/signer/private.key"; rm -r -- "$SHM/signer" "$SHM"/triple*.json "$SHM/tmp" "$SHM/bin"

echo "== proofs"
echo "public outputs:"; ls -l "$PUB" | awk 'NR>1{print "  "$1, $5, $9}'
echo "private material still present (until each party's Secret is created, S7a/S8; account seeds until S9):"
find "$SHM" -type f | sort | sed 's|^|  |'
echo "signer key gone: $([[ -z $(find "$SHM" -name 'private.key' -path '*signer*') ]] && echo yes || echo NO)"
