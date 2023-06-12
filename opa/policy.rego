package envoy.authz

import future.keywords

import input.attributes.request.http as http_request


default allow := false

allow if {
	action_allowed
}

action_allowed if {
	http_request.method == "GET"
	startswith(http_request.path, "/play/adminapi")
	[_, encoded] := split(http_request.headers.authorization, " ")
	tokenpayload := decodeJWT(encoded)
	print(tokenpayload)
	tokenpayload.role == "admin"
}

action_allowed if {
	http_request.method == "GET"
	print(http_request.path)
	startswith(http_request.path, "/play/userapi")
}


decodeJWT(token) = payload {
    [header, payload, signature] = io.jwt.decode(token)
}