#!/usr/bin/env bash
# One org generates ITS OWN keys in its own custody dir and prints only public values (iroha3 PLAN S2/S5).
#   network/keygen-party.sh <bi|bank-a|bank-b|bank-c> <custody-dir>
# Writes under <custody-dir> (mode 0700, must not exist or be empty): validator/{public.key,private.key,pop.hex}
# (BLS, Committee-role PoP), <party>.seed, <party>.note (account seed and note keys), and for bi also bi-gov.seed.
# Prints ONE JSON line to stdout with public values only; private files never leave the custody dir.
# Commands (override for tests or docker): KAGAMI (default `kagami`), RDDFABI (default `rd-dfabi`).
set -euo pipefail
party=${1:-} custody=${2:-}
case $party in bi | bank-a | bank-b | bank-c) ;; *) echo "usage: keygen-party.sh bi|bank-a|bank-b|bank-c <custody-dir>" >&2; exit 2 ;; esac
[[ -n $custody ]] || { echo "usage: keygen-party.sh bi|bank-a|bank-b|bank-c <custody-dir>" >&2; exit 2; }
if [[ -e $custody ]] && [[ -n $(ls -A "$custody" 2>/dev/null) ]]; then
  echo "keygen-party.sh: $custody exists and is not empty; refusing to reuse a custody dir" >&2; exit 2
fi
KAGAMI=${KAGAMI:-kagami}
RDDFABI=${RDDFABI:-rd-dfabi}
umask 077
mkdir -p "$custody" && chmod 700 "$custody"

# kagami creates validator/ itself (0700, refuses a non-empty dir) and never prints the private key.
"$KAGAMI" keys --algorithm bls_normal --pop --out-dir "$custody/validator" >/dev/null
# `keys new` prints "<name> <account public key>" and writes <name>.seed (0600); the seed is never printed.
account=$("$RDDFABI" keys new "$custody" "$party" | awk '{print $2}')
"$RDDFABI" keys new-note "$custody" "$party" >/dev/null
gov=""
if [[ $party == bi ]]; then gov=$("$RDDFABI" keys new "$custody" bi-gov | awk '{print $2}'); fi

jq -nc --arg party "$party" --arg pk "$(tr -d '\n' < "$custody/validator/public.key")" --arg pop "$(tr -d '\n' < "$custody/validator/pop.hex")" \
  --arg acct "$account" --arg gov "$gov" \
  '{party: $party, public_key: $pk, pop_hex: $pop, account_public_key: $acct} + (if $gov != "" then {gov_account_public_key: $gov} else {} end)'
