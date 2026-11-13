# Iroha 3 gateway rules (package iroha3, decision path iroha3/allow), loaded by each gateway's own OPA from deploy/gateway/policy.
# Envoy tags the door {target: "iroha3", node: "bi"|"bank-a"|"bank-b"|"bank-c"}, forwards the verified client leaf in XFCC and
# sends method and path (path with the query string), never the body. Test PKI: gen-pki.sh.
package iroha3_test

import data.iroha3 as bi
import data.iroha3_pki as pki

nodes := ["bi", "bank-a", "bank-b", "bank-c"]

banks := ["bank-a", "bank-b", "bank-c"]

all_roles := ["lensa", "bank-a", "bank-b", "bank-c", "bi"]

# Public CA certificates the BI document carries (data.iroha3_config.iroha3_ca).
iroha3_ca := {
	"lensa": {"bi": pki.lensa_ca_bi, "bank-a": pki.lensa_ca_bank_a, "bank-b": pki.lensa_ca_bank_b, "bank-c": pki.lensa_ca_bank_c},
	"role": {"bank-a": pki.role_ca_bank_a, "bank-b": pki.role_ca_bank_b, "bank-c": pki.role_ca_bank_c, "bi": pki.role_ca_bi},
}

bi_cfg := {"iroha3_ca": iroha3_ca}

lensa_leaf := {"bi": pki.lensa_leaf_bi, "bank-a": pki.lensa_leaf_bank_a, "bank-b": pki.lensa_leaf_bank_b, "bank-c": pki.lensa_leaf_bank_c}

role_leaf := {"bi": pki.role_leaf_bi, "bank-a": pki.role_leaf_bank_a, "bank-b": pki.role_leaf_bank_b, "bank-c": pki.role_leaf_bank_c}

# The certificate a caller of this role presents at this node's gateway.
cert_of(node, role) := lensa_leaf[node] if role == "lensa"

cert_of(_, role) := role_leaf[role] if role != "lensa"

# What Envoy forwards (forward_client_cert_details SANITIZE_SET, cert: true): the verified client leaf, URL-encoded PEM.
xfcc(pem) := sprintf("Hash=00;Cert=\"%s\";Subject=\"x\"", [urlquery.encode(pem)])

door_with(node, method, path, headers) := {"attributes": {
	"contextExtensions": {"target": "iroha3", "node": node},
	"request": {"http": {"method": method, "path": path, "headers": headers}},
}}

door_as(node, method, path, pem) := door_with(node, method, path, {"x-forwarded-client-cert": xfcc(pem)})

allowed_as(node, method, path, pem) if {
	bi.allow with input as door_as(node, method, path, pem) with data.iroha3_config as bi_cfg
}

allowed(node, role, method, path) if allowed_as(node, method, path, cert_of(node, role))

hex := "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

i105 := "sorauROlmcAbLg1Tbhg4PwAyX9DbX1LhgMkBYMx5q6bwFx"

# One entry per SPEC row: the paths, who may call them where (allow), and who may not (deny). Paths include the query string.
rows := [
	{
		"row": 1, "method": "GET", "paths": ["/health", "/status"],
		"allow": [{"roles": all_roles, "nodes": nodes}], "deny": [],
	},
	{
		"row": 2, "method": "GET",
		"paths": ["/v1/parameters", "/v1/node/capabilities", "/v1/privacy/capabilities", "/v1/nexus/lifecycle"],
		"allow": [{"roles": all_roles, "nodes": nodes}], "deny": [],
	},
	{
		"row": 3, "method": "GET",
		"paths": [
			concat("", ["/v1/pipeline/transactions/status?hash=", hex]),
			concat("", ["/v1/pipeline/transactions/status?hash=", upper(hex)]),
			concat("", ["/v1/pipeline/transactions/status?hash=", hex, "&scope=auto_1"]),
		],
		"allow": [{"roles": all_roles, "nodes": nodes}], "deny": [],
	},
	{
		"row": 4, "method": "GET",
		"paths": [
			concat("", ["/v1/accounts/", i105, "/assets"]),
			concat("", ["/v1/explorer/assets?owned_by=", i105]),
			concat("", ["/v1/explorer/accounts/", i105]),
			"/v1/assets/definitions",
			"/v1/explorer/asset-definitions",
		],
		"allow": [{"roles": all_roles, "nodes": nodes}], "deny": [],
	},
	{
		"row": 5, "method": "POST", "paths": ["/v1/pipeline/transactions"],
		"allow": [{"roles": ["bank-a", "bank-b", "bank-c", "bi"], "nodes": nodes}],
		"deny": [{"roles": ["lensa"], "nodes": nodes}],
	},
	{
		"row": 6, "method": "POST",
		"paths": [
			"/v1/nexus/private-settlements/legs/availability-shares",
			"/v1/nexus/private-settlements/legs",
			"/v1/nexus/private-settlements/phases/prepare-votes",
			"/v1/nexus/private-settlements/phases/certificates",
			"/v1/nexus/private-settlements/phases/commit-votes",
			"/v1/nexus/private-settlements/bundles",
		],
		"allow": [{"roles": ["bank-a", "bank-b", "bank-c", "bi"], "nodes": nodes}],
		"deny": [{"roles": ["lensa"], "nodes": nodes}],
	},
	{
		"row": 7, "method": "GET",
		"paths": [
			concat("", ["/v1/nexus/private-settlements/bundles/", hex]),
			concat("", ["/v1/nexus/private-settlements/bundles/", i105, "/receipt"]),
			concat("", ["/v1/nexus/private-settlements/legs/", hex, "/phase-certificates"]),
		],
		"allow": [{"roles": ["bank-a", "bank-b", "bank-c", "bi"], "nodes": nodes}],
		"deny": [{"roles": ["lensa"], "nodes": nodes}],
	},
	{
		"row": 8, "method": "POST",
		"paths": [
			concat("", ["/v1/nexus/private-settlements/legs/", hex, "/audit-capsule"]),
			concat("", ["/v1/nexus/private-settlements/legs/", hex, "/audit-approvals"]),
		],
		"allow": [{"roles": ["bi"], "nodes": nodes}],
		"deny": [{"roles": ["lensa", "bank-a", "bank-b", "bank-c"], "nodes": nodes}],
	},
	{
		"row": 9, "method": "GET", "paths": ["/healthz"],
		"allow": [{"roles": ["lensa"], "nodes": nodes}],
		"deny": [{"roles": ["bank-a", "bank-b", "bank-c", "bi"], "nodes": nodes}],
	},
	{
		"row": 10, "method": "POST", "paths": ["/settle-grant", "/dvp-native", "/transfer"],
		"allow": [{"roles": ["lensa"], "nodes": nodes}],
		"deny": [{"roles": ["bank-a", "bank-b", "bank-c", "bi"], "nodes": nodes}],
	},
	{
		"row": 11, "method": "POST", "paths": ["/mint"],
		"allow": [{"roles": ["lensa"], "nodes": ["bi"]}],
		"deny": [
			{"roles": ["lensa"], "nodes": ["bank-a", "bank-b", "bank-c"]},
			{"roles": ["bank-a", "bank-b", "bank-c", "bi"], "nodes": nodes},
		],
	},
	{
		"row": 12, "method": "GET", "paths": [concat("", ["/tx/", hex]), concat("", ["/tx/", upper(hex)])],
		"allow": [{"roles": ["lensa"], "nodes": nodes}, {"roles": ["bi"], "nodes": ["bi"]}],
		"deny": [
			{"roles": ["bank-a", "bank-b", "bank-c"], "nodes": nodes},
			{"roles": ["bi"], "nodes": ["bank-a", "bank-b", "bank-c"]},
		],
	},
	{
		"row": 15, "method": "GET", "paths": ["/keys"],
		"allow": [{"roles": all_roles, "nodes": auditor_nodes}],
		"deny": [{"roles": all_roles, "nodes": ["bank-c"]}],
	},
	{
		"row": 15, "method": "POST", "paths": ["/approve"],
		"allow": [{"roles": ["bank-a", "bank-b", "bank-c", "bi"], "nodes": auditor_nodes}],
		"deny": [{"roles": ["lensa"], "nodes": nodes}, {"roles": ["bank-a", "bank-b", "bank-c", "bi"], "nodes": ["bank-c"]}],
	},
	{
		"row": 16, "method": "POST", "paths": ["/aps/intent"],
		"allow": [{"roles": ["lensa"], "nodes": nodes}],
		"deny": [{"roles": ["bank-a", "bank-b", "bank-c", "bi"], "nodes": nodes}],
	},
	{
		"row": 16, "method": "GET", "paths": ["/aps/wallet"],
		"allow": [{"roles": ["lensa"], "nodes": nodes}],
		"deny": [{"roles": ["bank-a", "bank-b", "bank-c", "bi"], "nodes": nodes}],
	},
	{
		"row": 16, "method": "POST", "paths": ["/aps/submit"],
		"allow": [{"roles": ["lensa"], "nodes": nodes}],
		"deny": [{"roles": ["bi"], "nodes": nodes}],
	},
	{
		"row": 17, "method": "POST", "paths": ["/aps/address", "/aps/leg"],
		"allow": [{"roles": ["bi"], "nodes": nodes}],
		"deny": [{"roles": ["lensa", "bank-a", "bank-b", "bank-c"], "nodes": nodes}],
	},
	{
		"row": 18, "method": "POST", "paths": ["/aps/submit"],
		"allow": [{"roles": banks, "nodes": ["bi"]}],
		"deny": [{"roles": banks, "nodes": ["bank-a", "bank-b", "bank-c"]}],
	},
]

# Row 15: the three auditor nodes (bank-c runs no auditor).
auditor_nodes := ["bi", "bank-a", "bank-b"]

# Rows 16-18 are exact: another method, a query, a trailing slash, a sub-path or an unknown /aps/ route never passes for any role at any node.
test_aps_routes_are_exact if {
	every n in nodes {
		every r in all_roles {
			not allowed(n, r, "GET", "/aps/intent")
			not allowed(n, r, "GET", "/aps/submit")
			not allowed(n, r, "POST", "/aps/wallet")
			not allowed(n, r, "GET", "/aps/address")
			not allowed(n, r, "GET", "/aps/leg")
			not allowed(n, r, "PUT", "/aps/submit")
			not allowed(n, r, "DELETE", "/aps/intent")
			not allowed(n, r, "POST", "/aps/intent?x=1")
			not allowed(n, r, "POST", "/aps/submit?x=1")
			not allowed(n, r, "GET", "/aps/wallet?x=1")
			not allowed(n, r, "POST", "/aps/address?x=1")
			not allowed(n, r, "POST", "/aps/leg?x=1")
			not allowed(n, r, "POST", "/aps/submit/")
			not allowed(n, r, "POST", "/aps/intent/x")
			not allowed(n, r, "POST", "/aps/")
			not allowed(n, r, "POST", "/aps")
			not allowed(n, r, "POST", "/aps/unknown")
			not allowed(n, r, "POST", "/x/aps/submit")
			not allowed(n, r, "POST", "/aps/leg\n")
		}
	}
}

# Lensa never reaches the coordinator-to-party routes (row 17), a bank never reaches them or the Lensa-only routes (row 16).
test_aps_party_routes_are_not_lensa_or_bank if {
	every n in nodes {
		not allowed(n, "lensa", "POST", "/aps/address")
		not allowed(n, "lensa", "POST", "/aps/leg")
		every role in banks {
			not allowed(n, role, "POST", "/aps/address")
			not allowed(n, role, "POST", "/aps/leg")
			not allowed(n, role, "POST", "/aps/intent")
			not allowed(n, role, "GET", "/aps/wallet")
		}
	}
}

# Row 18: a bank's driver forwards /aps/submit to the BI gateway only (the coordinator); BI itself submits as lensa (row 16), never as role bi.
test_aps_bank_submit_only_at_bi if {
	every role in banks {
		allowed("bi", role, "POST", "/aps/submit")
		every n in banks {
			not allowed(n, role, "POST", "/aps/submit")
		}
	}
	every n in nodes {
		not allowed(n, "bi", "POST", "/aps/submit")
	}
}

# Row 15 is exact: other methods, a query, a sub-path or BI's /records never pass for any role at any node.
test_auditor_routes_are_exact if {
	every n in nodes {
		every r in all_roles {
			not allowed(n, r, "POST", "/keys")
			not allowed(n, r, "GET", "/approve")
			not allowed(n, r, "GET", "/keys?x=1")
			not allowed(n, r, "GET", "/keys/x")
			not allowed(n, r, "POST", "/approve?x=1")
			not allowed(n, r, "GET", "/records")
		}
	}
}

test_allow_rows if {
	every r in rows {
		every g in r.allow {
			every p in r.paths {
				every role in g.roles {
					every n in g.nodes {
						allowed(n, role, r.method, p)
					}
				}
			}
		}
	}
}

test_deny_rows if {
	every r in rows {
		every g in r.deny {
			every p in r.paths {
				every role in g.roles {
					every n in g.nodes {
						not allowed(n, role, r.method, p)
					}
				}
			}
		}
	}
}

# --- named SPEC denials

test_lensa_cannot_submit if {
	every n in nodes {
		not allowed(n, "lensa", "POST", "/v1/pipeline/transactions")
	}
}

test_bank_cannot_settle_grant if {
	every role in banks {
		every n in nodes {
			not allowed(n, role, "POST", "/settle-grant")
			not allowed(n, role, "POST", "/dvp-native")
			not allowed(n, role, "POST", "/transfer")
		}
	}
}

test_bank_cannot_read_tx_detail_anywhere if {
	every role in banks {
		every n in nodes {
			not allowed(n, role, "GET", concat("", ["/tx/", hex]))
		}
	}
}

test_bi_lens_tx_only_at_bi if {
	allowed("bi", "bi", "GET", concat("", ["/tx/", hex]))
	not allowed("bank-a", "bi", "GET", concat("", ["/tx/", hex]))
}

test_mint_only_at_bi if {
	allowed("bi", "lensa", "POST", "/mint")
	every n in banks {
		not allowed(n, "lensa", "POST", "/mint")
	}
}

test_unlisted_paths_denied if {
	every role in all_roles {
		every n in nodes {
			not allowed(n, role, "GET", "/v1/unlisted")
			not allowed(n, role, "GET", "/v1/sumeragi/status")
			not allowed(n, role, "GET", "/v1/sumeragi/new_view/json")
			not allowed(n, role, "POST", "/v1/sumeragi/status")
			not allowed(n, role, "GET", "/v1/configuration")
			not allowed(n, role, "POST", "/v1/configuration")
			not allowed(n, role, "GET", "/")
			not allowed(n, role, "GET", "")
			not allowed(n, role, "GET", "/auditor/keys")
			not allowed(n, role, "GET", "/metrics")
		}
	}
}

test_other_methods_denied if {
	every m in ["DELETE", "PUT", "PATCH", "HEAD", "OPTIONS", "get", ""] {
		every role in all_roles {
			every p in ["/health", "/v1/pipeline/transactions", "/settle-grant", "/mint", "/healthz", concat("", ["/tx/", hex])] {
				not allowed("bi", role, m, p)
			}
		}
	}
}

test_get_on_post_only_and_reverse_denied if {
	every role in all_roles {
		not allowed("bi", role, "GET", "/v1/pipeline/transactions")
		not allowed("bi", role, "GET", "/settle-grant")
		not allowed("bi", role, "GET", "/dvp-native")
		not allowed("bi", role, "GET", "/mint")
		not allowed("bi", role, "GET", "/v1/nexus/private-settlements/bundles")
		not allowed("bi", role, "POST", "/health")
		not allowed("bi", role, "POST", "/healthz")
		not allowed("bi", role, "POST", "/v1/parameters")
		not allowed("bi", role, "POST", concat("", ["/tx/", hex]))
		not allowed("bi", role, "POST", concat("", ["/v1/pipeline/transactions/status?hash=", hex]))
		not allowed("bi", role, "POST", concat("", ["/v1/nexus/private-settlements/bundles/", hex]))
	}
}

test_tx_needs_64_hex if {
	every role in ["lensa", "bi"] {
		every p in [
			"/tx/", "/tx", "/tx/abc", "/tx/xyz",
			concat("", ["/tx/", substring(hex, 0, 63)]),
			concat("", ["/tx/", hex, "0"]),
			concat("", ["/tx/", replace(hex, "0", "g")]),
			concat("", ["/tx/", hex, "/"]),
			concat("", ["/tx/", hex, "/x"]),
			concat("", ["/tx/", hex, "?x=1"]),
			concat("", ["/tx/../", hex]),
			concat("", ["/tx/", hex, "\n"]),
			concat("", ["/x/tx/", hex]),
		] {
			not allowed("bi", role, "GET", p)
		}
	}
}

# --- query rules

test_row3_hash_must_be_64_hex if {
	base := "/v1/pipeline/transactions/status"
	allowed("bi", "lensa", "GET", concat("", [base, "?hash=", hex]))
	not allowed("bi", "lensa", "GET", base)
	not allowed("bi", "lensa", "GET", concat("", [base, "?"]))
	not allowed("bi", "lensa", "GET", concat("", [base, "?hash="]))
	not allowed("bi", "lensa", "GET", concat("", [base, "?hash=", substring(hex, 0, 63)]))
	not allowed("bi", "lensa", "GET", concat("", [base, "?hash=", hex, "0"]))
	not allowed("bi", "lensa", "GET", concat("", [base, "?hash=", replace(hex, "0", "g")]))
	not allowed("bi", "lensa", "GET", concat("", [base, "?hash=", hex, "&scope="]))
	not allowed("bi", "lensa", "GET", concat("", [base, "?hash=", hex, "&scope=a-b"]))
	not allowed("bi", "lensa", "GET", concat("", [base, "?hash=", hex, "&scope=a%20b"]))
	not allowed("bi", "lensa", "GET", concat("", [base, "?hash=", hex, "&other=1"]))
	not allowed("bi", "lensa", "GET", concat("", [base, "?scope=a&hash=", hex]))
	not allowed("bi", "lensa", "GET", concat("", [base, "?hash=", hex, "&scope=a&scope=b"]))
	not allowed("bi", "lensa", "GET", concat("", [base, "/x?hash=", hex]))
	not allowed("bi", "lensa", "GET", concat("", [base, "?hash=", hex, "#f"]))
}

test_row4_owned_by_one_segment if {
	base := "/v1/explorer/assets"
	allowed("bi", "bank-a", "GET", concat("", [base, "?owned_by=", i105]))
	not allowed("bi", "bank-a", "GET", base)
	not allowed("bi", "bank-a", "GET", concat("", [base, "?owned_by="]))
	not allowed("bi", "bank-a", "GET", concat("", [base, "?owned_by=a/b"]))
	not allowed("bi", "bank-a", "GET", concat("", [base, "?owned_by=a&x=1"]))
	not allowed("bi", "bank-a", "GET", concat("", [base, "?x=1"]))
	not allowed("bi", "bank-a", "GET", concat("", [base, "?owned_by=a%2Fb"]))
	not allowed("bi", "bank-a", "GET", concat("", [base, "/x?owned_by=a"]))
}

test_account_segments if {
	not allowed("bi", "bank-a", "GET", "/v1/accounts//assets")
	not allowed("bi", "bank-a", "GET", "/v1/accounts/a/b/assets")
	not allowed("bi", "bank-a", "GET", "/v1/accounts/a@b/assets")
	not allowed("bi", "bank-a", "GET", "/v1/accounts/../assets")
	not allowed("bi", "bank-a", "GET", "/v1/explorer/accounts/")
	not allowed("bi", "bank-a", "GET", "/v1/explorer/accounts/a/b")
	not allowed("bi", "bank-a", "GET", concat("", ["/v1/accounts/", i105]))
	not allowed("bi", "bank-a", "GET", concat("", ["/v1/accounts/", i105, "/assets?limit=1"]))
}

test_query_denied_on_other_rows if {
	every role in all_roles {
		not allowed("bi", role, "GET", "/health?x=1")
		not allowed("bi", role, "GET", "/status?")
		not allowed("bi", role, "GET", "/v1/parameters?x=1")
		not allowed("bi", role, "GET", "/v1/assets/definitions?limit=1")
		not allowed("bi", role, "POST", "/v1/pipeline/transactions?x=1")
		not allowed("bi", role, "POST", "/settle-grant?x=1")
		not allowed("bi", role, "POST", "/mint?x=1")
	}
}

test_aps_segments if {
	base := "/v1/nexus/private-settlements"
	not allowed("bi", "bank-a", "GET", concat("", [base, "/bundles/"]))
	not allowed("bi", "bank-a", "GET", concat("", [base, "/bundles/a/b"]))
	not allowed("bi", "bank-a", "GET", concat("", [base, "/bundles/a/receipt/x"]))
	not allowed("bi", "bank-a", "GET", concat("", [base, "/legs/", hex]))
	not allowed("bi", "bank-a", "GET", concat("", [base, "/legs/abc/phase-certificates"]))
	not allowed("bi", "bank-a", "GET", concat("", [base, "/legs/", hex, "/audit-capsule"]))
	not allowed("bi", "bank-a", "POST", concat("", [base, "/legs/", hex, "/audit-capsule"]))
	not allowed("bi", "bank-a", "POST", concat("", [base, "/legs/abc/audit-capsule"]))
	not allowed("bi", "bank-a", "POST", concat("", [base, "/phases/other"]))
	not allowed("bi", "bank-a", "POST", concat("", [base, "/bundles/x"]))
	not allowed("bi", "bi", "POST", concat("", [base, "/legs/abc/audit-capsule"]))
	not allowed("bi", "bi", "POST", concat("", [base, "/legs/", hex, "/audit-other"]))
	not allowed("bi", "bi", "POST", concat("", [base, "/legs/", hex, "/audit-capsule?x=1"]))
}

# --- identity

test_no_cert_denied if {
	not bi.allow with input as door_with("bi", "GET", "/health", {}) with data.iroha3_config as bi_cfg
	not bi.allow with input as door_with("bi", "GET", "/health", {"x-forwarded-client-cert": "Hash=00;Subject=\"x\""}) with data.iroha3_config as bi_cfg
	not bi.allow with input as door_with("bi", "GET", "/health", {"x-forwarded-client-cert": ""}) with data.iroha3_config as bi_cfg
}

test_two_cert_elements_denied if {
	hdr := sprintf("Cert=\"%s\";Subject=\"x\",Cert=\"%s\";Subject=\"y\"", [urlquery.encode(pki.lensa_leaf_bi), urlquery.encode(pki.role_leaf_bank_a)])
	not bi.allow with input as door_with("bi", "GET", "/health", {"x-forwarded-client-cert": hdr}) with data.iroha3_config as bi_cfg
	hdr2 := sprintf("Cert=\"%s\";Subject=\"x\",Cert=\"%s\";Subject=\"y\"", [urlquery.encode(pki.lensa_leaf_bi), urlquery.encode(pki.lensa_leaf_bi)])
	not bi.allow with input as door_with("bi", "GET", "/health", {"x-forwarded-client-cert": hdr2}) with data.iroha3_config as bi_cfg
}

test_two_certificates_in_one_element_denied if {
	pem := concat("\n", [pki.lensa_leaf_bi, pki.role_leaf_bank_a])
	not allowed_as("bi", "GET", "/health", pem)
	not allowed_as("bi", "GET", "/health", concat("\n", [pki.lensa_leaf_bi, pki.lensa_leaf_bi]))
}

test_garbage_cert_denied if {
	not allowed_as("bi", "GET", "/health", "not a certificate")
	not allowed_as("bi", "GET", "/health", "")
}

test_ca_cert_is_not_a_caller if {
	not allowed_as("bi", "GET", "/health", pki.lensa_ca_bi)
	not allowed_as("bi", "GET", "/health", pki.role_ca_bank_a)
}

test_cn_of_one_role_with_another_roles_ca_denied if {
	not allowed_as("bi", "GET", "/health", pki.bank_a_by_b)
	not allowed_as("bi", "GET", "/health", pki.bi_by_lensa)
	not allowed_as("bi", "GET", concat("", ["/tx/", hex]), pki.bi_by_lensa)
}

test_lensa_cn_from_a_role_ca_denied if {
	not allowed_as("bi", "GET", "/healthz", pki.lensa_by_role)
	not allowed_as("bank-a", "GET", "/healthz", pki.lensa_by_role)
	not allowed_as("bi", "POST", "/mint", pki.lensa_by_role)
}

test_lensa_of_another_party_denied if {
	every n in nodes {
		every m in [x | some x in nodes; x != n] {
			not allowed_as(n, "GET", "/health", lensa_leaf[m])
		}
	}
	not allowed_as("bi", "GET", "/health", pki.lensa_leaf_bank_a)
	not allowed_as("bi", "POST", "/mint", pki.lensa_leaf_bank_a)
}

test_server_only_eku_denied if {
	not allowed_as("bi", "GET", "/health", pki.server_eku)
	not allowed_as("bank-a", "GET", "/health", pki.server_eku)
}

test_unknown_cn_denied if {
	not allowed_as("bi", "GET", "/health", pki.bank_d)
	not allowed_as("bank-a", "GET", "/health", pki.bank_d)
}

test_role_leaf_is_not_lensa if {
	every r in ["bank-a", "bank-b", "bank-c", "bi"] {
		not allowed("bi", r, "GET", "/healthz")
		not allowed("bi", r, "POST", "/mint")
	}
}

# --- data

test_missing_ca_data_denies if {
	not bi.allow with input as door_as("bi", "GET", "/health", pki.lensa_leaf_bi) with data.iroha3_config as {}
	not bi.allow with input as door_as("bi", "GET", "/health", pki.lensa_leaf_bi) with data.iroha3_config as {"iroha3_ca": {"lensa": {}, "role": {}}}
	not bi.allow with input as door_as("bi", "GET", "/health", pki.role_leaf_bi) with data.iroha3_config as {"iroha3_ca": {"lensa": {}, "role": {}}}
}

# The shipped data.json carries the four public role CAs iroha handed over (iroha3-rd-dfabi public/gateway-ca/<role>-role-ca.pem) and
# NO Lensa CA yet (fe's Lensa client CA is not decided): a test-PKI leaf of any role passes nothing, and so does a `lensa` caller.
test_shipped_data_denies_foreign_leaves if {
	not bi.allow with input as door_as("bi", "GET", "/health", pki.lensa_leaf_bi)
	not bi.allow with input as door_as("bi", "GET", "/health", pki.role_leaf_bi)
}

shipped_role_sha256 := {
	"bi": "3c1408b9", "bank-a": "2a78033a", "bank-b": "bf75e5fb", "bank-c": "884e41ad",
}

test_shipped_role_cas_are_the_handed_over_public_certs if {
	count(data.iroha3_config.iroha3_ca.role) == 4
	every role, prefix in shipped_role_sha256 {
		pem := data.iroha3_config.iroha3_ca.role[role]
		startswith(crypto.sha256(pem), prefix)
		count(crypto.x509.parse_certificates(pem)) == 1
		not contains(pem, "PRIVATE")
	}

	# W2 option 2: one public Lensa client CA per node (tests: iroha3_lensa_ca_test, lensa_ca_data_test.rego)
	count(data.iroha3_config.iroha3_ca.lensa) == 4
}

test_unknown_node_denied if {
	not bi.allow with input as door_as("bank-d", "GET", "/health", pki.lensa_leaf_bi) with data.iroha3_config as bi_cfg
	not bi.allow with input as door_as("", "GET", "/health", pki.lensa_leaf_bi) with data.iroha3_config as bi_cfg
}

# Only the five role names count even when the data carries more.
test_extra_role_in_data_denied if {
	cfg := {"iroha3_ca": {"lensa": iroha3_ca.lensa, "role": object.union(iroha3_ca.role, {"bank-d": pki.role_ca_bank_a})}}
	not bi.allow with input as door_as("bi", "GET", "/health", pki.bank_d) with data.iroha3_config as cfg
}

# --- Row 14 (iroha node-build #25, D5): GET /balance?asset=<Base58>, the driver's signed read of its OWN account: Lensa only, exact path,
# exactly one `asset` parameter, Base58 alphabet (1-9A-HJ-NP-Za-km-z: no 0 O I l). Lensa's cert is bound to the gateway's own node CA, so
# "lensa of another party" never passes (test_lensa_cert_of_another_node_denied); BI's lens reads at node bi only because it only exists there.
b58 := "5Zk3xYpq9WmRtHDnEv2JLbQ"

test_balance_row_14_lensa_only if {
	every node in nodes {
		allowed(node, "lensa", "GET", concat("", ["/balance?asset=", b58]))
		every role in ["bank-a", "bank-b", "bank-c", "bi"] {
			not allowed(node, role, "GET", concat("", ["/balance?asset=", b58]))
		}
	}
}

test_balance_row_14_shape_denied if {
	every node in nodes {
		every p in [
			"/balance", "/balance?", "/balance?asset=", "/balance/", concat("", ["/balance/", b58]), concat("", ["/balance/?asset=", b58]),
			concat("", ["/balance?asset=", b58, "&asset=", b58]), concat("", ["/balance?asset=", b58, "&x=1"]), concat("", ["/balance?x=1&asset=", b58]),
			concat("", ["/balance?asset=", b58, "&"]), concat("", ["/balance?Asset=", b58]), concat("", ["/balance?asset[]=", b58]),
			"/balance?asset=0abc", "/balance?asset=Oabc", "/balance?asset=Iabc", "/balance?asset=labc", "/balance?asset=ab-c", "/balance?asset=ab_c", "/balance?asset=ab.c",
			"/balance?asset=ab%20c", "/balance?asset=ab+c", "/balance?asset=ab c", "/balance?asset=ab\nc", concat("", ["/balance?asset=", b58, "#x"]),
			concat("", ["/x/balance?asset=", b58]), concat("", ["/balance;x?asset=", b58]), concat("", ["//balance?asset=", b58]),
			concat("", ["/balance?asset=", b58, "\n"]),
		] {
			not allowed(node, "lensa", "GET", p)
		}
		every m in ["POST", "PUT", "DELETE", "PATCH", "HEAD", "OPTIONS", "get"] {
			not allowed(node, "lensa", m, concat("", ["/balance?asset=", b58]))
		}
	}
}

test_balance_row_14_base58_alphabet if {
	allowed("bi", "lensa", "GET", "/balance?asset=123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz")
}

test_lensa_cert_of_another_node_denied if {
	not allowed_as("bank-a", "GET", concat("", ["/balance?asset=", b58]), lensa_leaf["bank-b"])
	not allowed_as("bi", "GET", concat("", ["/balance?asset=", b58]), lensa_leaf["bank-a"])
}
