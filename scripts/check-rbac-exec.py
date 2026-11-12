#!/usr/bin/env python3
"""RBAC guard (iroha lane, after the gha-runner finding): no Role / ClusterRole in this repo, and no rendered one, may grant
  - pods/exec, pods/attach, pods/portforward (or pods/*), or a wildcard resource `*`;
  - get / list / watch (or `*`) on secrets WITHOUT resourceNames (a named, single-Secret rule is allowed: the auditor client-key Job).
Usage: check-rbac-exec.py <label> [file ...]   (no files: read YAML/JSON documents from stdin; files with @PLACEHOLDER@ templating are read after replacing @X@ by x)
Walks every given file; use with `git ls-files` in the test so a new manifest anywhere in the repo is covered."""
import json
import re
import sys

import yaml

label = sys.argv[1]
files = sys.argv[2:]
SUBRES = {"pods/exec", "pods/attach", "pods/portforward", "pods/*"}
READ = {"get", "list", "watch", "*"}


UNPARSEABLE = []


def docs_of(text, name):
    # template placeholder: a line that is ONLY @X@ becomes empty, any other @X@ becomes x
    text = "\n".join("" if re.fullmatch(r"\s*@[A-Z_]+@\s*", l) else l for l in text.split("\n"))
    text = re.sub(r"@[A-Z_]+@", "x", text)
    try:
        return [d for d in yaml.safe_load_all(text) if isinstance(d, dict)]
    except yaml.YAMLError:
        # never skip silently: a file that cannot be parsed but declares a Role/ClusterRole is a failure
        if re.search(r"^\s*kind:\s*(Cluster)?Role\s*$", text, re.M):
            UNPARSEABLE.append(name)
        return []


def items(d):
    return d["items"] if d.get("kind") == "List" and isinstance(d.get("items"), list) else [d]


def violations(name, d):
    out = []
    if d.get("kind") not in ("Role", "ClusterRole"):
        return out
    who = f"{name}: {d['kind']} {d.get('metadata', {}).get('name')}"
    for i, r in enumerate(d.get("rules") or []):
        res, verbs, names = set(r.get("resources") or []), set(r.get("verbs") or []), r.get("resourceNames")
        bad = sorted(res & SUBRES)
        if bad:
            out.append(f"{who} rule[{i}] grants {bad}")
        if "*" in res:
            out.append(f"{who} rule[{i}] has a wildcard resource")
        if ("secrets" in res or "*" in res) and (verbs & READ) and not names:
            out.append(f"{who} rule[{i}] reads secrets ({sorted(verbs & READ)}) without resourceNames")
    return out


bad = []
n = 0
srcs = [(f, open(f, errors="replace").read()) for f in files] if files else [("<stdin>", sys.stdin.read())]
for name, text in srcs:
    if name.endswith(".json") or text.lstrip().startswith(("{", "[")):
        try:
            parsed = json.loads(text)
            ds = parsed if isinstance(parsed, list) else [parsed]
            ds = [x for d in ds if isinstance(d, dict) for x in items(d)]
        except ValueError:
            ds = [x for d in docs_of(text, name) for x in items(d)]
    else:
        ds = [x for d in docs_of(text, name) for x in items(d)]
    for d in ds:
        if d.get("kind") in ("Role", "ClusterRole"):
            n += 1
        bad += violations(name, d)
bad += [f"{u}: cannot be parsed but declares a Role/ClusterRole (never skipped silently)" for u in UNPARSEABLE]
if bad:
    print("\n".join(f"FAIL: rbac-exec {label}: {b}" for b in bad), file=sys.stderr)
    sys.exit(1)
print(f"ok:   rbac-exec {label}: {n} Role/ClusterRole documents, none grants exec/attach/portforward, a wildcard resource or unnamed secret reads")
