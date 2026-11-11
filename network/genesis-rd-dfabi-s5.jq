# S5 variant of genesis-rd-dfabi.jq (the old chain keeps genesis-rd-dfabi.jq). Differences: the BI operator account is registered by
# the localnet template (its client account is mapped to `bi`), so it is not registered again; the governance account `bi-gov` is
# registered and funded for fees (PLAN S3: CanEnactGovernance is granted to it in the privacy transaction, not to `bi`).
# RD and DFABI as DataspaceRestricted assets homed in ONE restricted dataspace ($ds, e.g. ds-rd).
# One dataspace for both on purpose: a DvpIsi whose legs sit in two different restricted dataspaces
# cannot execute (core isi/settlement.rs dvp_rejects_counterparty_consent_outside_execution_dataspace:
# "committed public balance scope .. does not match execution dataspace .."), so the DvP pair shares a home.
# A restricted definition needs an explicit owning domain (isi/domain.rs ensure_asset_definition_domain_context);
# execution takes the home dataspace from that domain's dataspace segment, the router from the alias first.
# Both are "wonderland.$ds" / "<name>#wonderland.$ds" here, so they agree.
def adef($id; $name; $desc): {Register:{AssetDefinition:{alias:null,balance_scope_policy:"DataspaceRestricted",description:$desc,id:$id,logo:null,metadata:{},mintable:"Infinitely",name:$name,owning_domain:$domain,spec:{scale:0}}}};
def acct($id): {Register:{Account:{id:$id,label:null,metadata:{},opaque_ids:[],uaid:null}}};
def xor($id): {Mint:{Asset:{destination:("6TEAJqbb8oEPmLncoNiMRbLEK6tw#" + $id),object:"1000"}}};
def mintperm($id): {Grant:{Permission:{destination:$bi,object:{name:"CanMintAssetWithDefinition",payload:{asset_definition:$id}}}}};
def owner($id): {Transfer:{AssetDefinition:{source:$gen,object:$id,destination:$bi}}};
def alias($a; $id): {SetAssetDefinitionAlias:{alias:$a,asset_definition_id:$id,lease_expiry_ms:null}};
# CanReadRestrictedDataspace is genesis-only (executor.rs INITIAL_GENESIS_ONLY_PERMISSION_NAMES). Torii reads it as a direct
# permission or from a role; kagami's private-dataspace bootstrap writes both, so both are written.
def readperm($acct; $d): {Grant:{Permission:{destination:$acct,object:{name:"CanReadRestrictedDataspace",payload:{dataspace:$d}}}}};
def readrole($acct; $label; $d): {Register:{Role:{grant_to:$acct,id:("restricted_reader_ds" + ($d | tostring) + "_" + $label),permissions:[{name:"CanReadRestrictedDataspace",payload:{dataspace:$d}}]}}};
($rd) as $rd | ($dfabi) as $df |
[{l:"bi",a:$bi},{l:"a",a:$a},{l:"b",a:$b}] as $readers |
.transactions += [
  # 1. universal: party accounts, their fee balances (XOR is a Global asset), and the read rights of every
  #    restricted dataspace: a signed query fans out to every route and 403s unless all of them are readable.
  #    Party C gets none: it is the outsider. Two transactions at most: a normalized genesis may hold 16.
  {instructions: [
    acct($gov), acct($a), acct($b), acct($c),
    xor($gov), xor($a), xor($b), xor($c),
    ($readds[] | . as $d | $readers[] | readperm(.a; $d)),
    ($readds[] | . as $d | $readers[] | readrole(.a; .l; $d))
  ], ivm_triggers: [], topology: []},
  # 2. home dataspace: domain, both definitions, aliases, BI ownership + mint right
  {instructions: [
    {Register:{Domain:{id:$domain,logo:null,metadata:{}}}},
    adef($rd; "RD"; "Rupiah Digital (PoC)"), adef($df; "DFABI"; "DFABI bond (PoC, ICMA BDT v1.2)"),
    alias("rd#" + $domain; $rd), alias("dfabi#" + $domain; $df),
    owner($rd), owner($df), mintperm($rd), mintperm($df)
  ], ivm_triggers: [], topology: []}
]
