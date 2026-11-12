# BI rules for the Iroha 3 gateways (target "iroha3"), one gateway per party. Envoy tags the door {target: "iroha3", node: "bi"|"bank-a"|
# Ported from rd-besu opa/bundles/bi/bi/platform/iroha3/iroha3.rego at 8a0b94c (main 61d7fdf + row 10 /transfer, rd-besu#113); iroha3 owns it
# here since 2026-11-13 (user decision: separate iroha OPA). Each gateway OPA loads it from ConfigMap gateway-policy (decision path iroha3/allow).
# "bank-b"|"bank-c"}, forwards the verified client leaf in x-forwarded-client-cert (SANITIZE_SET) and sends method and path (the path
# carries the query string); there is no body. `allow` = a role from the verified leaf AND a route row that allows that role at this node.
# Roles by certificate CN, exactly: lensa, bank-a, bank-b, bank-c, bi. The leaf is verified for ClientAuth against a public CA from
# data.iroha3_config.iroha3_ca (no CA data: nothing passes):
#   lensa              CN `lensa`, signed directly by iroha3_ca.lensa[<node>], the Lensa client CA of THIS gateway's party
#   bank-a/b/c, bi     CN = the role, signed directly by iroha3_ca.role[<that role>], the role's own CA
# No certificate, a second Cert element, a leaf of another CA, another CN or server-only key usage: denied.
# Routes (iroha3-opa-ops rows 1-12; method and path match exactly, anchored, nothing else passes; row 13, the auditor, is below the rows):
#   1-4   GET   health, public reads, tx status (hash=<64 hex>[&scope=]), balance reads (owned_by=<I105>)   lensa, bank-*, bi
#   5-7   POST/GET  signed tx submit, APS client calls and reads                                            bank-*, bi (not lensa)
#   8     POST  audit capsule/approvals                                                                     bi
#   9-10  GET /healthz, POST /settle-grant, /dvp-native, /transfer                                          lensa
#   11    POST /mint                                                                                        lensa, node bi only
#   12    GET /tx/<64 hex>                                                                                  lensa; bi role at node bi only
#   14    GET /balance?asset=<Base58> (exactly one param)                                                   lensa only
#   15    GET /keys, POST /approve of the node's own auditor (nodes bi, bank-a, bank-b)                     bank-*, bi; lensa GET /keys only
# Query strings are allowed only in the rows that name them; a path with any other query never matches.
package iroha3

own := input.attributes.contextExtensions.node

method := input.attributes.request.http.method

path := input.attributes.request.http.path

bank_roles := {"bank-a", "bank-b", "bank-c"}

default allow := false

allow if {
	some role in roles
	route(role)
}

# The leaf Envoy forwarded: exactly one Cert element, one certificate in it.
leaf_pem := pem if {
	h := input.attributes.request.http.headers["x-forwarded-client-cert"]
	count(regex.find_all_string_submatch_n(`Cert="`, h, -1)) == 1
	pem := urlquery.decode(regex.find_all_string_submatch_n(`Cert="([^"]+)"`, h, 1)[0][1])
	count(crypto.x509.parse_certificates(pem)) == 1
}

# The leaf, when it verifies directly against ca for client auth. Input order is [root, leaf]; the result lists the leaf first, so
# the leaf is the one entry that is not a CA.
verified(ca) := leaf if {
	[ok, certs] := crypto.x509.parse_and_verify_certificates_with_options(concat("\n", [ca, leaf_pem]), {"KeyUsages": ["KeyUsageClientAuth"]})
	ok == true
	count(certs) == 2
	some leaf in certs
	not leaf.IsCA
}

roles contains "lensa" if verified(data.iroha3_config.iroha3_ca.lensa[own]).Subject.CommonName == "lensa"

roles contains role if {
	some role in (bank_roles | {"bi"})
	verified(data.iroha3_config.iroha3_ca.role[role]).Subject.CommonName == role
}

# Rows 1-4: every role.
route(_) if {
	method == "GET"
	some p in public_reads
	regex.match(p, path)
}

public_reads := {
	`^/(health|status)$`,
	`^/v1/(parameters|node/capabilities|privacy/capabilities|nexus/lifecycle)$`,
	`^/v1/pipeline/transactions/status\?hash=[0-9a-fA-F]{64}(&scope=\w+)?$`,
	`^/v1/accounts/[A-Za-z0-9]+/assets$`,
	`^/v1/explorer/assets\?owned_by=[A-Za-z0-9]+$`,
	`^/v1/explorer/accounts/[A-Za-z0-9]+$`,
	`^/v1/(assets/definitions|explorer/asset-definitions)$`,
}

# Row 5-6: signed tx submit and APS client calls, not Lensa.
route(role) if {
	role != "lensa"
	method == "POST"
	regex.match(`^/v1/pipeline/transactions$`, path)
}

route(role) if {
	role != "lensa"
	method == "POST"
	regex.match(`^/v1/nexus/private-settlements/(legs/availability-shares|legs|phases/prepare-votes|phases/certificates|phases/commit-votes|bundles)$`, path)
}

# Row 7: APS reads, not Lensa.
route(role) if {
	role != "lensa"
	method == "GET"
	regex.match(`^/v1/nexus/private-settlements/(bundles/[A-Za-z0-9]+(/receipt)?|legs/[0-9a-fA-F]{64}/phase-certificates)$`, path)
}

# Row 13: the auditors. CN `<party>-auditor` exists for bi, bank-a and bank-b only (bank-c has none); the leaf is signed by that party's ROLE CA (the same CA that signs the
# party's own client leaf, so the CN decides, never the CA alone). Each auditor reaches every gateway, only with its own party's CA, and only the two row-8 POST routes.
auditors := {"bi", "bank-a", "bank-b"}

auditor if {
	some p in auditors
	verified(data.iroha3_config.iroha3_ca.role[p]).Subject.CommonName == concat("", [p, "-auditor"])
}

allow if {
	auditor
	method == "POST"
	regex.match(`^/v1/nexus/private-settlements/legs/[0-9a-fA-F]{64}/(audit-capsule|audit-approvals)$`, path)
}

# Row 8: auditor identity.
route("bi") if {
	method == "POST"
	regex.match(`^/v1/nexus/private-settlements/legs/[0-9a-fA-F]{64}/(audit-capsule|audit-approvals)$`, path)
}

# Row 9-10: the driver, Lensa only.
route("lensa") if {
	method == "GET"
	path == "/healthz"
}

route("lensa") if {
	method == "POST"
	path in {"/settle-grant", "/dvp-native", "/transfer"}
}

# Row 11: BI-only mint.
route("lensa") if {
	own == "bi"
	method == "POST"
	path == "/mint"
}

# Row 12: signed query with that driver's own key; at BI the BI-lens identity reads it too, bank roles never.
route("lensa") if tx_detail

route("bi") if {
	own == "bi"
	tx_detail
}

# Row 14 (node-build #25): the driver's signed balance read of its OWN account; one `asset` parameter, Base58 only (no 0 O I l).
route("lensa") if {
	method == "GET"
	regex.match(`^/balance\?asset=[1-9A-HJ-NP-Za-km-z]{1,128}$`, path)
}

# Row 15 (S11 transport A; dfabi auditor_urls): every party's driver identity (its [tls] client leaf, CN = role: pool-init, the APS
# coordinator) reads /keys and asks /approve of the auditor behind this gateway; Lensa only reads the public /keys. bank-c runs no
# auditor, so nothing passes there; BI's /records stays closed.
auditor_nodes := {"bi", "bank-a", "bank-b"}

route(role) if {
	role != "lensa"
	own in auditor_nodes
	method == "POST"
	path == "/approve"
}

route(_) if {
	own in auditor_nodes
	method == "GET"
	path == "/keys"
}

tx_detail if {
	method == "GET"
	regex.match(`^/tx/[0-9a-fA-F]{64}$`, path)
}
