def adef($id; $name; $desc): {Register:{AssetDefinition:{alias:null,balance_scope_policy:"Global",description:$desc,id:$id,logo:null,metadata:{},mintable:"Infinitely",name:$name,owning_domain:null,spec:{scale:0}}}};
def acct($id): {Register:{Account:{id:$id,label:null,metadata:{},opaque_ids:[],uaid:null}}};
def xor($id): {Mint:{Asset:{destination:("6TEAJqbb8oEPmLncoNiMRbLEK6tw#" + $id),object:"1000"}}};
def mintperm($id): {Grant:{Permission:{destination:$bi,object:{name:"CanMintAssetWithDefinition",payload:{asset_definition:$id}}}}};
def owner($id): {Transfer:{AssetDefinition:{source:$gen,object:$id,destination:$bi}}};
def alias($a; $id): {SetAssetDefinitionAlias:{alias:$a,asset_definition_id:$id,lease_expiry_ms:null}};
($rd) as $rd | ($dfabi) as $df |
.transactions += [{instructions: [
  acct($bi), acct($a), acct($b), acct($c),
  adef($rd; "RD"; "Rupiah Digital (PoC)"), adef($df; "DFABI"; "DFABI bond (PoC, ICMA BDT v1.2)"),
  alias("rd#wonderland.universal"; $rd), alias("dfabi#wonderland.universal"; $df),
  owner($rd), owner($df), mintperm($rd), mintperm($df),
  xor($bi), xor($a), xor($b), xor($c)
], ivm_triggers: [], topology: []}]
