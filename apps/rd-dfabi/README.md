# rd-dfabi

APS helper for the Lensa frontend (JSON in, JSON out). Design: see the iroha3 spec/plan for the driver and
`design-b-aps-helper.md`. All commands are stubs returning `not_implemented`.

    scripts/fetch-iroha.sh                 # .iroha-src at 071e281e (needed even for the stub: path deps must resolve)
    cargo test -p rd-dfabi                 # contract + schema drift test
    cargo run -p rd-dfabi -- schema --out apps/rd-dfabi/schema
    cargo build --release -p rd-dfabi --features aps   # CI only: iroha_core + zk-stark, hours cold

## Probe: committee-role keys on shared peer keys

One request tells whether the committee-role consensus keys are accepted as a private-settlement committee.
Build the body offline (needs `--features aps`; roster, lifecycle and network id are files you supply, none are in the repo):

    rd-dfabi probe availability-share-material --roster <peers-or-consensus-keys.json> --lifecycle <lifecycle.json> \
      --network-id-file <file> --sponsor-public-key <PUBLIC_KEY> --context-height <H> > material.json

stdout is the material; stderr is the `iroha ... availability-share` command with placeholders and the verdict table.
Run it once, signed by the sponsor account, against one validator's Torii. 200 Stored/AlreadyStored passes; a 400 is
only meaningful if the other inputs are right (see the design doc log).

## decode-tx: Norito tx decoder for the OPA gateway

`--features decode` (iroha_data_model + norito only; no iroha_core, no `aps`) adds a decoder for the body of
`POST /v1/pipeline/transactions`. It runs Torii's own `SignedTransaction::decode_all_versioned`, so bytes that are not the
canonical encoding (trailing data, odd framing) are refused exactly as Torii refuses them.

    rd-dfabi decode-tx --content-type application/x-norito < body.bin          # JSON on stdout, exit 3 + {"ok":false,...} on error
    rd-dfabi decode-tx serve --listen <host:port>                             # POST /decode -> JSON (listen has no default)

`POST /decode` takes either the raw body with its Content-Type, or the OPA `http.send` shape: `Content-Type: application/json`
and `{"b64": "<body, base64>", "ct": "<its Content-Type>"}` (`path`/`id` are ignored). A body that does not decode is HTTP 422.

Output contract: `schema/decode-tx.response.json` (request side: `schema/decode-tx.request.json`). Unknown instruction kinds
are `{"kind":"unknown","raw_kind":...}`; a body that does not decode is `{"ok":false,"error":{code,message}}` (HTTP 422 in
serve mode). Accounts print as I105 with the data model's default chain discriminant (the form the CLI prints).
The light build has the subcommand but answers `needs_decode_feature`. Golden tests on captured real bodies read the
directory in `$RD_DFABI_TXCAP_DIR` (`NNN-*.body`, `dvp-intent.txt`, `dvp-sid.txt`) and skip when it is unset; the captures hold
real account ids and are not in git.
