#!/usr/bin/env bash
# Org-side, in the org's OWN session (party-admin kubeconfig is not needed here): makes the auditor client key (EC P-256) and its PUBLIC CSR, CN=<party>-auditor.
#   deploy/auditor-sign/keygen.sh <bi|bank-a|bank-b> <workdir>     (workdir: mode 700, under /dev/shm; AUDITOR_SIGN_ALLOW_DISK=1 only for the offline test)
# Output: <workdir>/tls.key (0400, never printed, never leaves the org), <workdir>/auditor-client.csr (public; its sha256 is printed). Then: render.sh -> Job -> secret.sh.
set -euo pipefail
usage() { echo "usage: keygen.sh bi|bank-a|bank-b <workdir>" >&2; exit 2; }
(( $# == 2 )) || usage
party=$1 W=$2
case $party in bi | bank-a | bank-b) ;; *) usage ;; esac
[[ -d $W ]] || { echo "keygen.sh: work dir $W not found" >&2; exit 2; }
W=$(cd "$W" && pwd -P)
[[ -n ${AUDITOR_SIGN_ALLOW_DISK:-} || $W == /dev/shm/* ]] || { echo "keygen.sh: the work dir must be under /dev/shm (the private key never touches disk)" >&2; exit 2; }
[[ $(stat -c %a "$W") == 700 ]] || { echo "keygen.sh: the work dir must have mode 700 (is $(stat -c %a "$W"))" >&2; exit 2; }
[[ ! -e $W/tls.key && ! -e $W/auditor-client.csr ]] || { echo "keygen.sh: $W already holds a key or CSR: use a fresh work dir" >&2; exit 2; }
umask 077
openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -keyout "$W/tls.key" -out "$W/auditor-client.csr" -subj "/CN=$party-auditor" 2>/dev/null
chmod 400 "$W/tls.key"
echo "keygen.sh: key made (not printed); public CSR $W/auditor-client.csr sha256=$(sha256sum "$W/auditor-client.csr" | cut -d' ' -f1)"
