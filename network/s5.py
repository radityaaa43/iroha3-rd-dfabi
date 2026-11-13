#!/usr/bin/env python3
"""S5 genesis assembly from PUBLIC per-org data (iroha3 PLAN S2/S3/S5b, DELTA 1/2).

Subcommands (all offline, no cluster; run with `python3 -I`):
  genesis   transform a throwaway `kagami localnet` genesis.json into the S5 genesis manifest
  template  build the public peer.toml template from the throwaway localnet peer0.toml
  render    fill the template with ONE org's own keys and the public addresses -> that org's peer.toml

The throwaway localnet is only a TEMPLATE of upstream's bootstrap content (fee asset, stake asset, fee sponsor program,
aliases, lane-0 validators). Every key it generated (4 peers, genesis, client) is replaced here and never used; the real
peer keys, PoPs, account keys and the KAGEMUSHA roster come from the orgs' public files. Ported from network/generate.sh
(which stays untouched for the old chain): lane validators/stake, RD/DFABI overlay, gas parameters dropped, Committee keys,
nexus.toml merge, container paths.
"""
import argparse
import base64
import hashlib
import json
import os
import re
import struct
import subprocess
import sys
import tomllib


# ---------------------------------------------------------------- helpers
def walk_strings(o, fn):
    if isinstance(o, dict):
        return {k: walk_strings(v, fn) for k, v in o.items()}
    if isinstance(o, list):
        return [walk_strings(v, fn) for v in o]
    return fn(o) if isinstance(o, str) else o


def crc16(data: bytes) -> int:  # CRC-16/CCITT-FALSE as in addr checksums
    c = 0xFFFF
    for b in data:
        c ^= b << 8
        for _ in range(8):
            c = ((c << 1) ^ 0x1021) & 0xFFFF if c & 0x8000 else (c << 1) & 0xFFFF
    return c


def addr(host_port: str) -> str:
    s = "addr:" + host_port
    return "%s#%04X" % (s, crc16(s.encode()))


def bare(k):
    return k and all(c.isalnum() and c.isascii() or c in "_-" for c in k)


def key(k):
    return k if bare(k) else json.dumps(k, ensure_ascii=False)


def val(v):
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        return repr(v)
    if isinstance(v, str):
        return json.dumps(v, ensure_ascii=False)
    if isinstance(v, list):
        return "[" + ", ".join(val(x) for x in v) + "]"
    raise TypeError(type(v))


def is_table_array(v):
    return isinstance(v, list) and v and all(isinstance(x, dict) for x in v)


def emit(t, path, lines):
    for k, v in t.items():
        if not isinstance(v, dict) and not is_table_array(v):
            lines.append("%s = %s" % (key(k), val(v)))
    for k, v in t.items():
        sub = path + [key(k)]
        if isinstance(v, dict):
            lines += ["", "[%s]" % ".".join(sub)]
            emit(v, sub, lines)
        elif is_table_array(v):
            for item in v:
                lines += ["", "[[%s]]" % ".".join(sub)]
                emit(item, sub, lines)


def to_toml(t):
    lines = []
    emit(t, [], lines)
    text = "\n".join(lines).lstrip("\n") + "\n"
    assert tomllib.loads(text) == t, "toml writer round trip failed"
    return text


def merge(base, over):
    for k, v in over.items():
        if isinstance(v, dict) and isinstance(base.get(k), dict):
            merge(base[k], v)
        else:
            base[k] = v


def strip0x(h):
    return h[2:] if h.startswith("0x") else h


# ---------------------------------------------------------------- Norito frames (ported from generate.sh:315-397)
def load_frames_from_generate_sh(path):
    """The three fixed base64 frames live in network/generate.sh; read them from there so there is one copy."""
    src = open(path).read()
    out = {}
    for name in ("REGISTER_ACTIVATION", "TRANSITION_ACTIVE", "SAMPLE_KEY"):
        m = re.search(r'^%s = "([A-Za-z0-9+/=]+)"' % name, src, re.M)
        assert m, "frame %s not found in %s" % (name, path)
        out[name] = m.group(1)
    m = re.search(r'^SAMPLE_PEER = \{"public_key": "([0-9A-Za-z]+)",\s*\n\s*"pop_hex": "(0x[0-9a-f]+)"\}', src, re.M)
    assert m, "SAMPLE_PEER not found in %s" % path
    out["SAMPLE_PEER"] = {"public_key": m.group(1), "pop_hex": m.group(2)}
    return out


def crc64_xz(data, _t=[]):
    if not _t:
        for i in range(256):
            c = i
            for _ in range(8):
                c = (c >> 1) ^ 0xC96C5795D7870F42 if c & 1 else c >> 1
            _t.append(c)
    c = 0xFFFFFFFFFFFFFFFF
    for b in data:
        c = _t[(c ^ b) & 0xFF] ^ (c >> 8)
    return c ^ 0xFFFFFFFFFFFFFFFF


def refresh(frame):  # 40-byte Norito header: length at 23, CRC64 at 31
    h, p = bytearray(frame[:40]), frame[40:]
    h[23:31] = struct.pack("<Q", len(p))
    h[31:39] = struct.pack("<Q", crc64_xz(p))
    return bytes(h) + p


def key_suffix(peer):  # core state.rs derive_committee_key_id
    return hashlib.blake2b(peer["public_key"].encode(), digest_size=64).digest()[:16].hex().encode()


def key_bytes(peer):  # Vec<u8> elements are length-prefixed one by one
    return b"".join(b"\x01" + bytes([x]) for x in bytes.fromhex(peer["public_key"][6:]))


def pop_bytes(peer):
    return bytes.fromhex(strip0x(peer["pop_hex"]))


def register_committee_key(frames, peer):
    frame = base64.b64decode(frames["SAMPLE_KEY"])
    for f in (key_suffix, key_bytes, pop_bytes):
        old, new = f(frames["SAMPLE_PEER"]), f(peer)
        assert len(old) == len(new) and old in frame, f.__name__
        frame = frame.replace(old, new)
    i = frame.find(b"NRT0", 4)  # nested payload frame
    return base64.b64encode(refresh(frame[:i] + refresh(frame[i:]))).decode()


# ---------------------------------------------------------------- genesis
def cmd_genesis(a):
    g = json.load(open(os.path.join(a.localnet, "genesis.json")))
    peers = json.load(open(a.peers))
    ids = json.load(open(a.ids))  # old_gen, old_client, gen, bi, bi-gov, bank-a, bank-b, bank-c (I105)
    params = json.load(open(a.params))
    assert len(peers) == 4
    old_pk = []
    for i in range(4):
        t = open(os.path.join(a.localnet, "peer%d.toml" % i)).read()
        old_pk.append(re.search(r'^public_key = "(ea0130[0-9A-Fa-f]+)"', t, re.M).group(1))

    # 1. accounts: localnet genesis account -> the signer's account; localnet client account -> BI's operator account.
    table = [(ids["old_gen"], ids["gen"]), (ids["old_client"], ids["bi"])]

    def sub(s):
        for old, new in table:
            s = s.replace(old, new)
        return s

    g = walk_strings(g, sub)

    # 2. peers: topology (with the orgs' PoPs), lane-0 validators and the KAGEMUSHA roster come from the public files.
    by_old = dict(zip(old_pk, peers))
    for tx in g["transactions"]:
        if tx.get("topology"):
            assert len(tx["topology"]) == 4
            tx["topology"] = [{"peer": p["public_key"], "pop_hex": strip0x(p["pop_hex"])} for p in peers]
        for ins in tx["instructions"]:
            if isinstance(ins, dict) and "RegisterPublicLaneValidator" in ins:
                v = ins["RegisterPublicLaneValidator"]
                v["peer_id"] = by_old[v["peer_id"]]["public_key"]
    g["kagemusha_mint_finality"] = params
    assert [v["validator"] for v in params["epoch_roster"]["validators"]] == sorted(
        v["validator"] for v in params["epoch_roster"]["validators"]
    ), "mint-finality roster must be sorted by PeerId"
    assert {v["validator"] for v in params["epoch_roster"]["validators"]} == {p["public_key"] for p in peers}

    # 3. NPoS parameters: epoch length (S5b) and gas parameters dropped (generate.sh:293-297).
    n = 0
    for tx in g["transactions"]:
        custom = (tx.get("parameters") or {}).get("custom") or {}
        for k in ("ivm_gas_accepted_assets", "ivm_gas_units_per_gas"):
            custom.pop(k, None)
        if "sumeragi_npos_parameters" in custom:
            custom["sumeragi_npos_parameters"]["payload"]["epoch_length_blocks"] = a.epoch_length
            n += 1
    assert n == 1, "expected exactly one sumeragi_npos_parameters"

    # 4. S3: CanEnactGovernance only at bi-gov; CanReadAllLedgerData only at bi (the localnet genesis account loses it).
    def keep(ins):
        t = json.dumps(ins, ensure_ascii=False)
        if "CanEnactGovernance" in t:  # re-granted to bi-gov in the last transaction
            return False
        if "CanReadAllLedgerData" in t and ids["gen"] in t:
            return False
        return True

    for tx in g["transactions"]:
        tx["instructions"] = [i for i in tx["instructions"] if keep(i)]

    # 5. lane validators on lanes 1..n (generate.sh:287-303).
    lanes = a.lanes
    v0 = [i["RegisterPublicLaneValidator"] for tx in g["transactions"] for i in tx["instructions"]
          if isinstance(i, dict) and "RegisterPublicLaneValidator" in i and i["RegisterPublicLaneValidator"]["lane_id"] == 0]
    assert len(v0) == 4, "expected 4 lane-0 validators"
    stake = a.stake_asset
    assert any(isinstance(i, dict) and i.get("Register", {}).get("AssetDefinition", {}).get("id") == stake
               for tx in g["transactions"] for i in tx["instructions"]), "stake asset not registered in genesis"
    # One Mint of the whole lane stake per validator BEFORE its first lane Register: fastpq chains the transfer deltas of a
    # transaction from the first delta's balance snapshot and does not see Mints, so a Mint between two Registers of the
    # same validator in one transaction leaves the second bond with "before=0" (CI run 43037250866 warning).
    lane_ins = [{"Mint": {"Asset": {"destination": stake + "#" + v["validator"], "object": str(int(v["initial_stake"]) * len(lanes))}}}
                for v in v0]
    for lane in lanes:
        for v in v0:
            lane_ins.append({"RegisterPublicLaneValidator": {**v, "lane_id": lane}})
            lane_ins.append({"ActivatePublicLaneValidator": {"lane_id": lane, "validator": v["validator"]}})
    g["transactions"].append({"instructions": lane_ins, "ivm_triggers": [], "topology": []})

    # 6. RD/DFABI overlay (jq file) then the privacy / committee transaction.
    tmp = json.dumps(g, ensure_ascii=False)
    gen_account = ids["gen"]
    jq = ["jq", "--arg", "bi", ids["bi"], "--arg", "gov", ids["bi-gov"], "--arg", "a", ids["bank-a"], "--arg", "b", ids["bank-b"],
          "--arg", "c", ids["bank-c"], "--arg", "gen", gen_account, "--arg", "rd", a.rd_id, "--arg", "dfabi", a.dfabi_id,
          "--arg", "domain", "wonderland." + a.home_ds, "--argjson", "readds", json.dumps(lanes), "-f", a.jq_file, "/dev/stdin"]
    r = subprocess.run(jq, input=tmp.encode(), capture_output=True)
    assert r.returncode == 0, r.stderr.decode()
    g = json.loads(r.stdout)

    frames = load_frames_from_generate_sh(a.generate_sh)

    def grant(name, dest):
        return {"Grant": {"Permission": {"destination": dest, "object": {"name": name, "payload": None}}}}

    g["transactions"].append({"instructions": [
        grant("CanEnactGovernance", ids["bi-gov"]),
        frames["REGISTER_ACTIVATION"],
        frames["TRANSITION_ACTIVE"],
        grant("CanManageConsensusKeys", gen_account),
        *[register_committee_key(frames, p) for p in peers],
    ], "ivm_triggers": [], "topology": []})
    json.dump(g, open(a.out, "w"), ensure_ascii=False)


# ---------------------------------------------------------------- peer template / render
PLACEHOLDERS = ("@PEER_PRIVATE_KEY@", "@PEER_PUBLIC_KEY@", "@TRANSPORT_PRIVATE_KEY@", "@TRANSPORT_PUBLIC_KEY@",
                "@IDENTITY_PRIVATE_KEY@", "@IDENTITY_PUBLIC_KEY@", "@PUBLIC_ADDRESS@", "@TRUSTED_PEERS@", "@TELEMETRY_URLS@")


def cmd_template(a):
    ids = json.load(open(a.ids))
    peers = json.load(open(a.peers))
    t = tomllib.load(open(os.path.join(a.localnet, "peer0.toml"), "rb"))
    old_gen_pk = open(os.path.join(a.localnet, "genesis.public_key")).read().strip()
    # per-peer values become placeholders; paths become the pod's
    t["private_key"], t["public_key"] = PLACEHOLDERS[0], PLACEHOLDERS[1]
    t["soranet_transport_private_key"], t["soranet_transport_public_key"] = PLACEHOLDERS[2], PLACEHOLDERS[3]
    t["streaming"]["identity_private_key"], t["streaming"]["identity_public_key"] = PLACEHOLDERS[4], PLACEHOLDERS[5]
    t["network"]["public_address"] = PLACEHOLDERS[6]
    t["network"]["address"] = addr("0.0.0.0:1337")
    t["torii"]["address"] = addr("0.0.0.0:8080")
    t["trusted_peers"] = PLACEHOLDERS[7]
    t["torii"]["peer_telemetry_urls"] = PLACEHOLDERS[8] if "peer_telemetry_urls" in t["torii"] else None
    if t["torii"]["peer_telemetry_urls"] is None:
        del t["torii"]["peer_telemetry_urls"]
    t["trusted_peers_pop"] = [{"public_key": p["public_key"], "pop_hex": strip0x(p["pop_hex"])} for p in peers]
    t["genesis"] = {"file": "/genesis/genesis.signed.nrt", "expected_hash_file": "/genesis/genesis.expected_hash",
                    "public_key": a.genesis_public_key}
    text = to_toml(t)
    # kagami localnet writes absolute paths under its --out-dir (assemble-s5.sh: $tmp/ln = /dev/shm/iroha3-new/tmp/tmp.X/ln, not
    # /work/out/...): rewrite ANY quoted path ending in /storage/peerN or /state/peerN. Live 2026-11-13: the old /work/out-only rewrite
    # left kura, state and the APS sidecars of all four peers in the container's /dev/shm instead of the PVC /storage.
    text = re.sub(r'"[^"\n]*/storage/peer\d+', '"/storage/kura', text)
    text = re.sub(r'"[^"\n]*/state/peer\d+', '"/storage/state', text)
    leftover = sorted(set(re.findall(r'"([^"\n]*' + re.escape(str(a.localnet).rstrip("/")) + r'/(?:storage|state)/[^"\n]*)"', text)))
    if leftover:
        raise SystemExit(f"s5.py template: storage/state paths under the localnet dir remain: {leftover[:3]}")
    text = text.replace(ids["old_gen"], ids["gen"]).replace(ids["old_client"], ids["bi"])
    text = text.replace(old_gen_pk, a.genesis_public_key)
    t = tomllib.loads(text)
    # sections that reference key/table files not shipped to the cluster (generate.sh:105-134)
    for k in ("account_onboarding", "faucet"):
        t["torii"].pop(k, None)
    t["streaming"].pop("codec", None)
    # nexus overlay (generate.sh:190-262)
    over = tomllib.load(open(a.nexus, "rb"))
    st = t["nexus"]["staking"]
    assert over["nexus"]["staking"]["stake_asset_id"] == st["stake_asset_id"], "nexus.toml stake asset differs from the genesis"

    def subst(o, table):
        if isinstance(o, dict):
            return {k: subst(v, table) for k, v in o.items()}
        if isinstance(o, list):
            return [subst(v, table) for v in o]
        return table.get(o, o) if isinstance(o, str) else o

    over = subst(over, {"@STAKE_ESCROW_ACCOUNT_ID@": st["stake_escrow_account_id"], "@SLASH_SINK_ACCOUNT_ID@": st["slash_sink_account_id"],
                        "@GAS_TECH_ACCOUNT_ID@": t["pipeline"]["gas"]["tech_account_id"]})
    merge(t, over)
    open(a.out, "w").write(to_toml(t))


def cmd_signcfg(a):
    """Config for `kagami genesis sign --config`: the template with the localnet's throwaway values and a placeholder hash."""
    t = tomllib.load(open(a.template, "rb"))
    ln = tomllib.load(open(os.path.join(a.localnet, "peer0.toml"), "rb"))
    peers = json.load(open(a.peers))
    for k in ("private_key", "public_key", "soranet_transport_private_key", "soranet_transport_public_key"):
        t[k] = ln[k]
    t["trusted_peers"] = ["%s@%s" % (p["public_key"], addr("127.0.0.1:%d" % (11337 + i))) for i, p in enumerate(peers)]
    t["streaming"]["identity_private_key"] = ln["streaming"]["identity_private_key"]
    t["streaming"]["identity_public_key"] = ln["streaming"]["identity_public_key"]
    t["network"]["public_address"] = ln["network"]["public_address"]
    if "peer_telemetry_urls" in t["torii"]:
        t["torii"]["peer_telemetry_urls"] = ln["torii"]["peer_telemetry_urls"]
    t["genesis"].pop("expected_hash_file", None)
    t["genesis"]["expected_hash"] = "REPLACE_WITH_GENESIS_EXPECTED_HASH"
    open(a.out, "w").write(to_toml(t))


def cmd_render(a):
    tpl = open(a.template).read()
    peers = json.load(open(a.peers))
    addrs = json.load(open(a.addrs))
    me = next(p for p in peers if p["party"] == a.party)

    def read(p):
        return open(p).read().strip()

    def hostport(party, same_cluster):
        # same-cluster peers by cluster DNS, other cluster by the external LoadBalancer address (PLAN S6)
        e = addrs[party]
        return e["dns"] if same_cluster else e["external"]

    cluster2 = {"bank-c"}
    mine_c2 = a.party in cluster2
    trusted = []
    for p in peers:
        same = (p["party"] in cluster2) == mine_c2
        trusted.append("%s@%s" % (p["public_key"], addr(hostport(p["party"], same))))
    telemetry = ["http://%s:8080/" % addrs[p["party"]]["dns"].rsplit(":", 1)[0] for p in peers if (p["party"] in cluster2) == mine_c2]
    d = a.custody
    sub = {
        "@PEER_PRIVATE_KEY@": read(os.path.join(d, "validator", "private.key")),
        "@PEER_PUBLIC_KEY@": me["public_key"],
        "@TRANSPORT_PRIVATE_KEY@": read(os.path.join(d, "transport", "private.key")),
        "@TRANSPORT_PUBLIC_KEY@": read(os.path.join(d, "transport", "public.key")),
        "@IDENTITY_PRIVATE_KEY@": read(os.path.join(d, "identity", "private.key")),
        "@IDENTITY_PUBLIC_KEY@": read(os.path.join(d, "identity", "public.key")),
        "@PUBLIC_ADDRESS@": addr(hostport(a.party, True) if not mine_c2 else addrs[a.party]["external"]),
    }
    assert read(os.path.join(d, "validator", "public.key")) == me["public_key"], "custody key differs from peers.json"
    out = tpl
    for k, v in sub.items():
        out = out.replace(json.dumps(k), json.dumps(v))
    out = out.replace(json.dumps("@TRUSTED_PEERS@"), json.dumps(trusted)).replace(json.dumps("@TELEMETRY_URLS@"), json.dumps(telemetry))
    assert not re.search(r"@[A-Z_]+@", out), "unfilled placeholder"
    fd = os.open(a.out, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(out)


def main():
    p = argparse.ArgumentParser()
    s = p.add_subparsers(dest="cmd", required=True)
    g = s.add_parser("genesis")
    g.add_argument("--localnet", required=True)
    g.add_argument("--peers", required=True)
    g.add_argument("--ids", required=True)
    g.add_argument("--params", required=True)
    g.add_argument("--epoch-length", type=int, required=True)
    g.add_argument("--lanes", type=int, nargs="+", required=True)
    g.add_argument("--stake-asset", required=True)
    g.add_argument("--rd-id", required=True)
    g.add_argument("--dfabi-id", required=True)
    g.add_argument("--home-ds", default="ds-rd")
    g.add_argument("--jq-file", required=True)
    g.add_argument("--generate-sh", required=True)
    g.add_argument("--out", required=True)
    g.set_defaults(f=cmd_genesis)
    t = s.add_parser("template")
    t.add_argument("--localnet", required=True)
    t.add_argument("--peers", required=True)
    t.add_argument("--ids", required=True)
    t.add_argument("--nexus", required=True)
    t.add_argument("--genesis-public-key", required=True)
    t.add_argument("--out", required=True)
    t.set_defaults(f=cmd_template)
    c = s.add_parser("signcfg")
    c.add_argument("--localnet", required=True)
    c.add_argument("--template", required=True)
    c.add_argument("--peers", required=True)
    c.add_argument("--out", required=True)
    c.set_defaults(f=cmd_signcfg)
    r = s.add_parser("render")
    r.add_argument("--template", required=True)
    r.add_argument("--peers", required=True)
    r.add_argument("--addrs", required=True)
    r.add_argument("--party", required=True)
    r.add_argument("--custody", required=True)
    r.add_argument("--out", required=True)
    r.set_defaults(f=cmd_render)
    a = p.parse_args()
    a.f(a)


if __name__ == "__main__":
    main()
