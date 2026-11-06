# rd-dfabi

APS helper for the Lensa frontend (JSON in, JSON out). Design: see the iroha3 spec/plan for the driver and
`design-b-aps-helper.md`. All commands are stubs returning `not_implemented`.

    scripts/fetch-iroha.sh                 # .iroha-src at 071e281e (needed even for the stub: path deps must resolve)
    cargo test -p rd-dfabi                 # contract + schema drift test
    cargo run -p rd-dfabi -- schema --out apps/rd-dfabi/schema
    cargo build --release -p rd-dfabi --features aps   # CI only: iroha_core + zk-stark, hours cold
