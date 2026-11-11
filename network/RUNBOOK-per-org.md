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

## 4. Known gaps (why `ASSEMBLE_ACCEPT_GAP=1` is required)
1. Base genesis: today's comes from `kagami localnet` + `network/generate.sh:262-400` (RD/DFABI overlay, lane validators and stake, gas parameters dropped,
   committee keys, `--config` peer.toml binding the DA policy). Not ported.
2. `--topology` JSON shape: README says "four validators at distinct canonical addresses"; `embed_pop.rs` entries carry a public-key `peer` + `pop_hex`.
3. The mint-finality parameters source (table above).
4. `--ivm-dir` location inside the node image.
Points 2-4 are what `.github/workflows/genesis-probe.yml` prints (help texts, throwaway keys, the error `genesis generate` gives without the parameters).
