# OPA's own REST API (localhost:8181) is closed: Envoy talks gRPC on :9191. Only the health check is open,
# because the probes on the diagnostic port (:8282) go through this policy too.
package system.authz

default allow := false

allow if {
	input.method == "GET"
	input.path == ["health"]
}
