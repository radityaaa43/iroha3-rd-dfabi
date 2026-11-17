"""Genesis rows of network/check.sh (and scripts/test-neutral-genesis.sh).
usage: check-genesis.py <genesis.json> <nexus.toml> <sponsor account id> <sponsor_read 0|1>
Exit != 0 (AssertionError) on the first row that does not hold."""
import json, sys, tomllib

g = json.load(open(sys.argv[1]))
n = tomllib.load(open(sys.argv[2], "rb"))["nexus"]
sponsor, sponsor_read = sys.argv[3], sys.argv[4] == "1"
ids = {d["alias"]: d["id"] for d in n["dataspace_catalog"]}
lanes = {l["dataspace"]: l["visibility"] for l in n["lane_catalog"]}
restricted = sorted(ids[a] for a, v in lanes.items() if v == "restricted")
ins = [i for t in g["transactions"] for i in t["instructions"] if isinstance(i, dict)]
defs = {d["name"]: d for i in ins if "Register" in i and "AssetDefinition" in i["Register"] for d in [i["Register"]["AssetDefinition"]] if d["name"] in ("RD", "DFABI")}
assert set(defs) == {"RD", "DFABI"}, defs.keys()
homes = {d["owning_domain"].split(".")[-1] for d in defs.values()}
assert len(homes) == 1 and lanes[homes.copy().pop()] == "restricted", homes
assert all(d["balance_scope_policy"] == "DataspaceRestricted" for d in defs.values())
home = homes.pop()
assert sum(1 for i in ins if "Register" in i and "Domain" in i["Register"] and i["Register"]["Domain"]["id"] == "wonderland." + home) == 1
aliases = {i["SetAssetDefinitionAlias"]["asset_definition_id"]: i["SetAssetDefinitionAlias"]["alias"] for i in ins if "SetAssetDefinitionAlias" in i}
for name, d in defs.items():
    assert aliases.get(d["id"]) == name.lower() + "#wonderland." + home, (name, aliases.get(d["id"]))
fee = n["fees"]["fee_asset_id"]
# every account holding the fee asset; in the S5 genesis (assemble-s5.sh) bi replaces the localnet client and is funded by the template's
# own fee mints, while the 1000-XOR mints go to bi-gov, A, B, C and the sponsor (generate.sh: the 4 parties and the sponsor)
funded = {i["Mint"]["Asset"]["destination"].split("#")[1] for i in ins if "Mint" in i and i["Mint"]["Asset"]["destination"].startswith(fee + "#")}
parties = {i["Mint"]["Asset"]["destination"].split("#")[1] for i in ins if "Mint" in i and i["Mint"]["Asset"]["destination"].startswith(fee + "#") and i["Mint"]["Asset"]["object"] == "1000"}
# the neutral sponsor is funded the same way (fees for every carrier) but is no party: registered once
assert sponsor in parties and len(parties) == 5, parties
parties.discard(sponsor)
assert len(parties) == 4, parties
assert sum(1 for i in ins if "Register" in i and "Account" in i["Register"] and i["Register"]["Account"]["id"] == sponsor) == 1
# SPONSOR_READ=1 (genesis parameter, default 0: gate G2 decides): the sponsor holds CanReadRestrictedDataspace on every restricted
# dataspace (direct permission + role, as for the parties) and nothing else; unset: no permission, no role
sp_grants = [i["Grant"]["Permission"] for i in ins if i.get("Grant", {}).get("Permission", {}).get("destination") == sponsor]
sp_roles = [i["Register"]["Role"] for i in ins if i.get("Register", {}).get("Role", {}).get("grant_to") == sponsor]
want = restricted if sponsor_read else []
assert sorted(p["object"]["payload"]["dataspace"] for p in sp_grants if p["object"]["name"] == "CanReadRestrictedDataspace") == want and len(sp_grants) == len(want), ("sponsor permissions", sp_grants)
assert sorted(p["payload"]["dataspace"] for r in sp_roles for p in r["permissions"] if p["name"] == "CanReadRestrictedDataspace") == want and sum(len(r["permissions"]) for r in sp_roles) == len(want), ("sponsor roles", sp_roles)
# the pools are NOT in genesis: ActivatePrivateSettlementPoolV1 needs the APS activation height (>= 11)
def names(o):  # every dict key and string value, at any depth (the instruction may be wrapped, e.g. Custom)
    if isinstance(o, dict):
        for k, v in o.items(): yield k; yield from names(v)
    elif isinstance(o, list):
        for v in o: yield from names(v)
    elif isinstance(o, str): yield o
assert not [x for x in names(ins) if "ActivatePrivateSettlementPoolV1" in x], "genesis activates a private settlement pool"
grants = [i["Grant"]["Permission"] for i in ins if "Grant" in i and i["Grant"]["Permission"]["object"]["name"] == "CanReadRestrictedDataspace" and i["Grant"]["Permission"]["destination"] != sponsor]
readers = {}
for p in grants: readers.setdefault(p["destination"], []).append(p["object"]["payload"]["dataspace"])
assert len(readers) == 3 and set(readers) <= funded - {sponsor}, readers.keys()
assert all(sorted(v) == restricted for v in readers.values()), readers.values()
