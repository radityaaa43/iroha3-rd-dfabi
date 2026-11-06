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

