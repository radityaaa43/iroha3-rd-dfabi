# The REAL bundle data (not a fixture): iroha3_ca.lensa[<node>] holds exactly the four PUBLIC Lensa client CAs of the W2 option 2 (one CA per party, iroha 2026-11-12).
# A Lensa leaf (CN lensa) must verify against THIS node's CA only, so the four must be distinct, CA:TRUE, pathlen 0, EC, named iroha3-<node>-lensa-ca, with no private key in the data.
package iroha3_lensa_ca_test

nodes := ["bi", "bank-a", "bank-b", "bank-c"]

cert(n) := c if {
	certs := crypto.x509.parse_certificates(data.iroha3_config.iroha3_ca.lensa[n])
	count(certs) == 1
	c := certs[0]
}

test_the_four_lensa_client_cas_are_present_public_cas if {
	every n in nodes {
		c := cert(n)
		c.IsCA
		c.MaxPathLen == 0
		c.MaxPathLenZero
		c.PublicKeyAlgorithm == 3 # x509.ECDSA (OPA reports the Go enum number)
		c.Subject.CommonName == sprintf("iroha3-%s-lensa-ca", [n])
		not contains(data.iroha3_config.iroha3_ca.lensa[n], "PRIVATE KEY")
	}
}

test_the_four_lensa_client_cas_are_distinct if {
	pems := {data.iroha3_config.iroha3_ca.lensa[n] | some n in nodes}
	count(pems) == 4
}

test_no_extra_lensa_node if {
	count(data.iroha3_config.iroha3_ca.lensa) == 4
}
