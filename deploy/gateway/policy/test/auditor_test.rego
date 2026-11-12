# Iroha 3 auditor rows (orchestrator FREEZE exception, iroha's confirmation): auditors exist for bi, bank-a, bank-b only (CN `<p>-auditor`, the leaf signed by that
# party's ROLE CA, the same CA that already signs the party's own client leaf, so the CN decides). Each auditor reaches ALL FOUR gateways, only with its own party's CA, and
# only for POST /v1/nexus/private-settlements/legs/<64 hex>/(audit-capsule|audit-approvals), no query string. Everything else is 403. Test PKI: gen-pki.sh.
package iroha3_auditor_test

import data.iroha3 as bi
import data.iroha3_pki as pki

nodes := ["bi", "bank-a", "bank-b", "bank-c"]

bi_cfg := {"iroha3_ca": {
	"lensa": {"bi": pki.lensa_ca_bi, "bank-a": pki.lensa_ca_bank_a, "bank-b": pki.lensa_ca_bank_b, "bank-c": pki.lensa_ca_bank_c},
	"role": {"bank-a": pki.role_ca_bank_a, "bank-b": pki.role_ca_bank_b, "bank-c": pki.role_ca_bank_c, "bi": pki.role_ca_bi},
}}

hex := "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

base := "/v1/nexus/private-settlements"

capsule := concat("", [base, "/legs/", hex, "/audit-capsule"])

approvals := concat("", [base, "/legs/", hex, "/audit-approvals"])

auditor_leaf := {"bi": pki.bi_auditor, "bank-a": pki.bank_a_auditor, "bank-b": pki.bank_b_auditor}

xfcc(pem) := sprintf("Hash=00;Cert=\"%s\";Subject=\"x\"", [urlquery.encode(pem)])

door(node, method, path, pem) := {"attributes": {
	"contextExtensions": {"target": "iroha3", "node": node},
	"request": {"http": {"method": method, "path": path, "headers": {"x-forwarded-client-cert": xfcc(pem)}}},
}}

allowed(node, method, path, pem) if {
	bi.allow with input as door(node, method, path, pem) with data.iroha3_config as bi_cfg
}

test_each_auditor_may_post_both_routes_at_every_gateway if {
	every p in ["bi", "bank-a", "bank-b"] {
		every n in nodes {
			allowed(n, "POST", capsule, auditor_leaf[p])
			allowed(n, "POST", approvals, auditor_leaf[p])
			allowed(n, "POST", concat("", [base, "/legs/", upper(hex), "/audit-capsule"]), auditor_leaf[p])
		}
	}
}

test_cn_of_one_party_with_the_ca_of_another_is_denied if {
	every n in nodes {
		not allowed(n, "POST", capsule, pki.bank_a_auditor_by_b)
		not allowed(n, "POST", approvals, pki.bank_a_auditor_by_b)
		not allowed(n, "POST", capsule, pki.bank_a_auditor_by_lensa)
	}
}

test_bank_c_has_no_auditor if {
	every n in nodes {
		not allowed(n, "POST", capsule, pki.bank_c_auditor)
		not allowed(n, "POST", approvals, pki.bank_c_auditor)
	}
}

test_server_only_key_usage_is_denied if {
	every n in nodes {
		not allowed(n, "POST", capsule, pki.bank_a_auditor_server_eku)
	}
}

test_auditor_on_any_other_route_or_method_is_denied if {
	other := [
		["GET", capsule], ["PUT", capsule], ["DELETE", capsule], ["POST", concat("", [capsule, "?x=1"])], ["POST", concat("", [capsule, "/"])],
		["POST", concat("", [base, "/legs/abc/audit-capsule"])], ["POST", concat("", [base, "/legs/", hex, "/audit-other"])],
		["POST", concat("", [base, "/legs/", hex])], ["POST", concat("", [base, "/legs/", hex, "/phase-certificates"])],
		["GET", concat("", [base, "/legs/", hex, "/phase-certificates"])], ["POST", concat("", [base, "/legs"])], ["POST", concat("", [base, "/bundles"])],
		["POST", concat("", [base, "/phases/prepare-votes"])], ["POST", "/v1/pipeline/transactions"], ["POST", "/mint"], ["POST", "/settle-grant"],
		["POST", "/dvp-native"], ["GET", "/health"], ["GET", "/status"], ["GET", "/v1/parameters"], ["GET", "/healthz"], ["GET", "/balance?asset=abc"],
		["GET", concat("", ["/tx/", hex])], ["GET", concat("", ["/v1/pipeline/transactions/status?hash=", hex])], ["POST", "/"],
		["POST", concat("", [base, "/../legs/", hex, "/audit-capsule"])], ["POST", concat("", ["/x", base, "/legs/", hex, "/audit-capsule"])],
	]
	every p in ["bi", "bank-a", "bank-b"] {
		every n in nodes {
			every r in other {
				not allowed(n, r[0], r[1], auditor_leaf[p])
			}
		}
	}
}

test_role_leaves_keep_their_rows_and_gain_no_auditor_row if {
	# the party's own role leaf (CN = the role) is not an auditor: row 8 stays bi-only, banks stay denied
	not allowed("bi", "POST", capsule, pki.role_leaf_bank_a)
	not allowed("bank-a", "POST", approvals, pki.role_leaf_bank_b)
	allowed("bi", "POST", capsule, pki.role_leaf_bi)
}

test_no_certificate_and_garbage_are_denied if {
	not bi.allow with input as {"attributes": {"contextExtensions": {"target": "iroha3", "node": "bi"}, "request": {"http": {"method": "POST", "path": capsule, "headers": {}}}}} with data.iroha3_config as bi_cfg
	not allowed("bi", "POST", capsule, "not a certificate")
}

# The SHIPPED data (no override): the role CAs the auditor rows verify against exist for the three auditor parties.
test_shipped_data_carries_the_role_cas_the_auditors_need if {
	every p in ["bi", "bank-a", "bank-b"] {
		startswith(data.iroha3_config.iroha3_ca.role[p], "-----BEGIN CERTIFICATE-----")
	}
}
