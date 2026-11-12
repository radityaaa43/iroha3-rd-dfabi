# Decision-log mask: keep method, domain, function, from and to; drop amounts, recipients and the raw body.
package system.log

mask contains "/input/attributes/request/http/body"

mask contains "/input/attributes/request/http/headers/authorization"

mask contains "/input/parsed_body/params/0/data"

# A view-key copy push (target stealth_viewcopy, body not sent to OPA): if a body ever reaches the input, the view key stays out of the log.
mask contains "/input/parsed_body/viewKey"
