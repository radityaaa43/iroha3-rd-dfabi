# Per-org keys and public-only genesis (iroha3 PLAN S2, S4, S5, S6)

Status: pre-stage. `keygen-party.sh` and `assemble.sh` are tested offline against stubs (`scripts/test-assemble.sh`); the real `kagami`
behaviour is read from the `genesis-probe` workflow log. Items marked [unverified] are not settled yet. Nothing here touches a cluster.

## 1. Each org, in its own custody (BI, A, B, C)
```
KAGAMI="docker run --rm --user $(id -u):$(id -g) -v $PWD/custody:/work --entrypoint kagami ghcr.io/radityaaa43/iroha3-rd-node:071e281e-stark" \
RDDFABI="docker run --rm --user $(id -u):$(id -g) -v $PWD/custody:/work ghcr.io/radityaaa43/iroha3-rd-driver:<tag>" \
network/keygen-party.sh <party> custody/<party>      # docker paths are inside the container: adapt the -v mounts
```
- Writes into the org's own custody dir (0700): `validator/{public.key,private.key,pop.hex}` (BLS key and Committee-role PoP,
  `kagami keys --algorithm bls_normal --pop`, README `iroha_kagami:223-235`), `<party>.seed`, `<party>.note` (`rd-dfabi keys new`,
  `keys new-note`), and for BI also `bi-gov.seed` (governance account, PLAN S3).
- Prints ONE JSON line with public values only: `party`, `public_key`, `pop_hex`, `account_public_key` (+ `gov_account_public_key` for bi).
  The org sends exactly that line to the assembler; nothing else leaves custody.
- BI's auditor keys (`bi-auditor.seed`, `bi-auditor.hybrid`) are made by the BI org with `rd-dfabi keys new` / `keys new-hybrid` (S4) and
  stay in `rd-iroha3-bi` only.

## 2. Public files (committed under `network/public/`; never a seed, note, hybrid or private key)
| File | Content | Producer |
|---|---|---|
| `peers.json` | `[{party, public_key, pop_hex}]` x 4 (bi, bank-a, bank-b, bank-c) | collected from the four JSON lines |
| `accounts.json` | `{bi, "bi-gov", bank-a, bank-b, bank-c}` -> account public keys | same lines; [unverified] mapping to the account ids `genesis-rd-dfabi.jq` needs |
| `peers.addr.json` | `{party: {dns, external}}`; `dns` = `<p>-0.<p>.rd-iroha3-<p>.svc.cluster.local:1337` (same-cluster peers), `external` = the LoadBalancer address (required for bank-c; S6) | S6 |
| `kagemusha-mint-finality-public.json` | public KAGEMUSHA mint-finality parameters | [unverified] who produces the epoch-zero file: not a `kagami` release subcommand (`kagemusha derive-mint-finality-next-epoch-v1` takes four private seed blocks in one process; the profile bundles come from `cargo xtask kagami-profiles`) |

## 3. Assembler (one signer, once)
```
GENESIS_PRIVATE_KEY_FILE=<signer key file> GENESIS_PUBLIC_KEY=<its public key> ASSEMBLE_ACCEPT_GAP=1 network/assemble.sh
```
Reads only the public files; refuses secrets in `network/public`, fewer than 4 peers, a missing PoP, a missing bank-c external address, a missing `bi-gov`
account or mint-finality file. Runs `kagami genesis generate ... default`, then `kagami genesis sign --topology ... --peer-pop PK=POP x4
--private-key-file --expected-public-key --out-file --expected-hash-out` (README `:236-262`). Destroy the signer key afterwards.

## 4. Settled by the probe (real kagami of `iroha3-rd-node:071e281e-stark`, workflow run 43006538345 on `d40ff82`)
- `kagami keys --algorithm bls_normal --pop --out-dir D` works with throwaway keys: `public.key` 103 bytes, `pop.hex` 193 bytes; `--algorithm ed25519` gives a
  genesis key whose public key starts `ed0120`.
- `genesis sign`: `--topology` is a "JSON-serialized vector of `PeerId`" (so `assemble.sh` passes the 4 public keys, not objects with PoPs), the final topology
  must be an exact `3f + 1` committee in 4..=31; `--peer-pop <public_key=pop_hex>` is repeatable and embeds the PoPs; `--config <PATH>` (TOML DA proof-policy)
  and `--bound-manifest-out` exist (today's `generate.sh:403-406` signs with the nodes' own peer.toml for the DA policy).
- `genesis generate` requires `--ivm-dir`, `--genesis-public-key` and `--kagemusha-mint-finality-parameters` (a regular file; without it: `read KAGEMUSHA
  mint-finality parameter metadata from ... No such file or directory`, `crates/iroha_kagami/src/genesis/generate.rs:54`).
- No `ivm_libs` or `*.to` file was found within 4 levels of `/` in the image ([unverified] if `find` ran: the step printed nothing).

## 5. Known gaps (why `ASSEMBLE_ACCEPT_GAP=1` is required)
1. Base genesis: today's comes from `kagami localnet` + `network/generate.sh:262-400` (RD/DFABI overlay, lane validators and stake, gas parameters dropped,
   committee keys, `--config` peer.toml binding the DA policy). Not ported.
2. The source of the epoch-zero KAGEMUSHA mint-finality public parameters file (table in section 2) and the location of the IVM libraries for `--ivm-dir`.

## 6. Secrets and ConfigMaps of S7 (binding condition from lead)
`Secret peer-<party>` (that org's own `peer.toml`, with its own private keys) and `ConfigMap genesis-<hash8>` are PRODUCED BY S5 (this runbook's sections 1-3).
Each party's Secret is created in its OWN namespace `rd-iroha3-<party>` from that org's OWN material only, with that party's own credential
(`~/iroha3-party-kubeconfigs`, Role verbs create/update/patch for Secrets). The old loader `deploy/secrets.sh` (it loads every party's peer Secret from one shared
place into one namespace) must not be used or referenced for the new chain.

## 7. Egress IPs for the p2p `/32` lists (S6 PRE input)
`deploy/p2p/render.sh --acl-id <id> --external-cidr X/32` and `deploy/peers/render.sh` take the PEER cluster's egress address. Read it in the PRE, never from a namespace listing:
run a throwaway pod in the party's OWN namespace on each cluster (`rd-iroha3-bi` on cluster 1, `rd-iroha3-bank-c` on cluster 2), `curl -s https://ifconfig.me` (or an equivalent),
delete the pod, and hand the two addresses to qa as a PRE input. Each address becomes one `/32` (never wider) in both the ingress NetworkPolicy ipBlock and `loadBalancerSourceRanges`.

## 8. Secret `bi-auditor-key` (S4)
`deploy/ns/auditor-secret.sh` uses plain `kubectl create` with the BI party credential. The party-admin Role has no secrets `get`, so `apply` and `--dry-run` are Forbidden.
A re-run fails with AlreadyExists and changes nothing. Rotation is a separate `replace` step, written when a rotation is ordered.

## 9. S7 apply helpers
`deploy/peers/peer-secret.sh <party> <peer.toml> <mint-finality.seed>` creates Secret `peer-<party>` in `rd-iroha3-<party>` with that party's own kubeconfig (plain `create`; re-run = AlreadyExists).
It refuses files that are not mode 600, a seed that is not 32 bytes, files inside a git checkout, a `peer.toml` missing a secret key name or still holding an `@...@` placeholder.
`deploy/peers/genesis-cm.sh <party> <network/public>` only PRINTS the immutable ConfigMap `genesis-<hash8>`; the operator pipes it to `kubectl apply -f -` with the ADMIN kubeconfig (ConfigMaps are outside the party-admin Role).
Offline tests: `scripts/test-peer-secret.sh`, `scripts/test-genesis-cm.sh`.
The ConfigMap value of `genesis.expected_hash` MUST end with exactly one LF: `iroha3d` refuses the mounted file otherwise ("must contain exactly one LF-terminated canonical public identity", seen live in S7b on 2026-11-11 with a hash printed without LF). `genesis-cm.sh` emits `"<hash>\n"` and the test compares the rendered value byte for byte with the file that `iroha3d --check-config` accepts. An immutable ConfigMap cannot be edited: a wrong one is deleted and re-applied under the same name, then the pod is deleted (OnDelete) to remount it.
`scripts/smoke-genesis-mount.sh <party> <public-dir> <peer.toml> [--strip-lf]` runs the real `iroha3d --sora --check-config` on the layout the pod mounts (ConfigMap decoded as kubelet does), not on disk files; `--strip-lf` is the negative control (must fail). Run it with the real artifact before any ConfigMap apply.
