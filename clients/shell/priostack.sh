# shellcheck shell=bash
#
# Official Shell (curl + jq) client for the Priostack Agent Context Network (ACN).
#
# The ACN is a Model Context Protocol (MCP) server reached over JSON-RPC 2.0. An
# agent self-registers, opens a session with the returned bearer token, creates
# isolated context spaces, stores typed facts, reads them back, and shares them
# with other agents through scoped capability grants.
#
# This is a *sourced* bash library: it defines `acn_*` functions and holds the
# token / session id / JSON-RPC id as shell state, so one shell process behaves
# like one client instance (the equivalent of the Python `ACNClient`). Every
# call shells out to curl and parses the reply with jq, unwrapping the MCP
# `result.content[0].text` envelope to reach the `{ok,outcome,data,detail}`
# object exactly as the wire contract requires.
#
#   Usage:
#     . ./priostack.sh
#     acn_register "my-agent"          # token captured in $ACN_TOKEN
#     acn_connect                      # session id captured in $ACN_SESSION_ID
#     space=$(acn_create_space "mem" | jq -r .spaceId)
#     acn_store "$space" "$(jq -cn '[{content:"hi",type:"declaration"}]')"
#     acn_fetch "$space" "hi" | jq -r '.objects[].content'
#
# On success each `acn_*` function returns 0, sets the global $ACN_DATA to the
# unwrapped tool `data` (JSON), and ALSO echoes it on stdout for piping. On
# failure it prints a diagnostic to stderr, sets $ACN_LAST_ERROR /
# $ACN_LAST_OUTCOME / $ACN_LAST_DETAIL, and returns a non-zero exit code — 1 for
# transport/protocol faults, 2 for a client-side usage error, and a distinct
# code per server outcome for tool-level denials (see $ACN_ERR_* below),
# mirroring the Python exception hierarchy.
#
# STATE + SUBSHELLS: because a shell holds the token / session id / id counter
# as process state, call the functions in the CURRENT shell and read $ACN_DATA
# (or $ACN_TOKEN / $ACN_SESSION_ID) — do NOT wrap a state-mutating call such as
# acn_register / acn_connect in `$(...)`, since that runs it in a subshell and
# the captured token/session would not survive. Piping a read-only call's stdout
# (e.g. `acn_discover | jq ...`) is always fine.

# --------------------------------------------------------------------------- #
# Configuration (override by exporting before sourcing, or assigning after).
# --------------------------------------------------------------------------- #
ACN_VERSION="0.3.0"
: "${ACN_ENDPOINT:=https://priostack.com/mcp}"   # canonical MCP endpoint; /acn/rpc is an alias
: "${ACN_TIMEOUT:=30}"                            # per-call timeout in seconds
: "${ACN_USER_AGENT:=priostack-shell/${ACN_VERSION}}"

# --------------------------------------------------------------------------- #
# Client state (per shell process). `acn_reset` clears it.
# --------------------------------------------------------------------------- #
: "${ACN_TOKEN:=}"          # bearer token, captured by acn_register / passed to acn_connect
: "${ACN_SESSION_ID:=}"     # session id, captured by acn_connect (from PascalCase data.SessionID)
: "${ACN_AGENT_ID:=}"       # this agent's principal id, captured by acn_register
: "${ACN_ACCOUNT_ID:=}"     # this agent's account id, captured by acn_register
: "${ACN_ACCOUNT:=}"        # resolved account, captured by acn_connect
: "${ACN_DATA:=}"           # unwrapped tool `data` from the most recent successful call
ACN_RPC_ID=0                # last JSON-RPC id used (mirrors the counter file)
# The id counter is file-backed and keyed on the shell PID ($$), which is stable
# across command-substitution subshells, so ids stay monotonic no matter how a
# read-only call is invoked. Override the path if $TMPDIR is not writable.
: "${ACN_RPC_ID_FILE:=${TMPDIR:-/tmp}/priostack-rpc-$$}"
ACN_LAST_ERROR=""
ACN_LAST_OUTCOME=""
ACN_LAST_DETAIL=""

# --------------------------------------------------------------------------- #
# Exit codes. Transport/usage vs. one distinct code per tool outcome, so a
# caller can branch on `case $?` the way Python code catches a subclass.
# --------------------------------------------------------------------------- #
ACN_ERR_TRANSPORT=1          # network / HTTP / JSON-RPC / decode failure
ACN_ERR_USAGE=2              # client-side argument / validation error
ACN_ERR_MISSING_TOOLING=3    # curl or jq not on PATH
ACN_ERR_TOOL=9               # tool declined with an unrecognised outcome
ACN_ERR_NOT_FOUND=10
ACN_ERR_INVALID_QUERY=11
ACN_ERR_CAPABILITY_DENIED=12
ACN_ERR_POLICY_DENIED=13
ACN_ERR_REQUIRES_GOVERNANCE=14
ACN_ERR_STALE_BASE=15
ACN_ERR_INTEGRITY_FAULT=16
ACN_ERR_CONFLICT=17
ACN_ERR_CAPACITY_EXHAUSTED=18
ACN_ERR_NOT_IMPLEMENTED=19

#: Object `type` values the store tool accepts.
ACN_STORE_KINDS="declaration observation measurement"

# --------------------------------------------------------------------------- #
# Internal helpers (prefixed `_acn_`).
# --------------------------------------------------------------------------- #
_acn_fail() { # code, message...
	local code=$1
	shift
	ACN_LAST_ERROR="$*"
	printf 'priostack: %s\n' "$*" >&2
	return "$code"
}

_acn_transport() { # message...
	ACN_LAST_OUTCOME=""
	ACN_LAST_DETAIL=""
	ACN_LAST_ERROR="$*"
	printf 'priostack: transport error: %s\n' "$*" >&2
	return "$ACN_ERR_TRANSPORT"
}

_acn_code_for_outcome() { # outcome -> exit code on stdout
	case "$1" in
	not-found) printf '%s' "$ACN_ERR_NOT_FOUND" ;;
	invalid-query) printf '%s' "$ACN_ERR_INVALID_QUERY" ;;
	capability-denied) printf '%s' "$ACN_ERR_CAPABILITY_DENIED" ;;
	policy-denied) printf '%s' "$ACN_ERR_POLICY_DENIED" ;;
	requires-governance) printf '%s' "$ACN_ERR_REQUIRES_GOVERNANCE" ;;
	stale-base) printf '%s' "$ACN_ERR_STALE_BASE" ;;
	integrity-fault) printf '%s' "$ACN_ERR_INTEGRITY_FAULT" ;;
	conflict) printf '%s' "$ACN_ERR_CONFLICT" ;;
	capacity-exhausted) printf '%s' "$ACN_ERR_CAPACITY_EXHAUSTED" ;;
	not-implemented) printf '%s' "$ACN_ERR_NOT_IMPLEMENTED" ;;
	*) printf '%s' "$ACN_ERR_TOOL" ;;
	esac
}

_acn_tool_error() { # method, outcome, detail
	local method=$1 outcome=$2 detail=$3 code
	ACN_LAST_OUTCOME="$outcome"
	ACN_LAST_DETAIL="$detail"
	ACN_LAST_ERROR="${detail:-$outcome}"
	code=$(_acn_code_for_outcome "$outcome")
	printf 'priostack: tool error [%s] calling %s: %s\n' \
		"${outcome:-unknown}" "$method" "${detail:-<no detail>}" >&2
	return "$code"
}

_acn_require_session() {
	[ -n "${ACN_SESSION_ID:-}" ] ||
		_acn_fail "$ACN_ERR_USAGE" "no active session: call acn_connect first"
}

_acn_is_uint() { # returns 0 if $1 is a non-negative integer
	case "$1" in
	'' | *[!0-9]*) return 1 ;;
	*) return 0 ;;
	esac
}

# Monotonic JSON-RPC id, persisted in $ACN_RPC_ID_FILE so it survives the
# command-substitution subshells a read-only call may run in. Prints the id.
_acn_next_id() {
	local n=0
	if [ -r "$ACN_RPC_ID_FILE" ]; then
		n=$(cat "$ACN_RPC_ID_FILE" 2>/dev/null) || n=0
	fi
	_acn_is_uint "$n" || n=0
	n=$((n + 1))
	printf '%s' "$n" >"$ACN_RPC_ID_FILE" 2>/dev/null || true
	ACN_RPC_ID=$n
	printf '%s' "$n"
}

# Turn a comma-separated list ("read, quote") into a JSON array of trimmed,
# non-empty strings. Prints the array on stdout.
_acn_csv_json() {
	jq -cn --arg s "$1" \
		'($s | split(",") | map(gsub("^\\s+|\\s+$";"")) | map(select(length > 0)))'
}

# --------------------------------------------------------------------------- #
# Core round trip: build the JSON-RPC tools/call envelope, POST it, unwrap the
# MCP content[0].text envelope, and print the tool `data` (or fail typed). This
# is the escape hatch behind every wrapper; use it directly for tools this
# library does not wrap (there are ~40 `noetic.*` tools).
#
#   acn_call <tool-name> [<arguments-json-object>]
# --------------------------------------------------------------------------- #
acn_call() {
	local name=$1
	local arguments=${2:-'{}'}

	if [ -z "$name" ]; then
		_acn_fail "$ACN_ERR_USAGE" "acn_call: a tool name is required"
		return
	fi
	if ! command -v curl >/dev/null 2>&1; then
		_acn_fail "$ACN_ERR_MISSING_TOOLING" "curl not found on PATH"
		return
	fi
	if ! command -v jq >/dev/null 2>&1; then
		_acn_fail "$ACN_ERR_MISSING_TOOLING" "jq not found on PATH"
		return
	fi
	if ! printf '%s' "$arguments" | jq -e . >/dev/null 2>&1; then
		_acn_fail "$ACN_ERR_USAGE" "acn_call: arguments for $name are not valid JSON"
		return
	fi

	local id payload
	id=$(_acn_next_id)
	payload=$(jq -cn --argjson id "$id" --arg name "$name" --argjson args "$arguments" \
		'{jsonrpc:"2.0", id:$id, method:"tools/call", params:{name:$name, arguments:$args}}')

	# One curl per call (a separate process cannot pool a socket the way the
	# Python Session does); the shared timeout + fixed options are the closest
	# faithful equivalent. --write-out appends the status on its own final line.
	local response rc
	response=$(curl -sS --max-time "$ACN_TIMEOUT" \
		-H 'Content-Type: application/json' \
		-H 'Accept: application/json' \
		-H "User-Agent: $ACN_USER_AGENT" \
		--data "$payload" \
		--write-out '\n%{http_code}' \
		"$ACN_ENDPOINT" 2>&1)
	rc=$?
	if [ "$rc" -ne 0 ]; then
		_acn_transport "network error calling $name: ${response:-curl exit $rc}"
		return
	fi

	local status body
	status=${response##*$'\n'}
	body=${response%$'\n'*}
	if ! _acn_is_uint "$status"; then
		_acn_transport "malformed response calling $name (no HTTP status): ${response:0:300}"
		return
	fi
	if [ "$status" -ge 400 ]; then
		_acn_transport "HTTP $status calling $name: ${body:0:300}"
		return
	fi
	if ! printf '%s' "$body" | jq -e . >/dev/null 2>&1; then
		_acn_transport "non-JSON response calling $name: ${body:0:300}"
		return
	fi

	# Top-level JSON-RPC error object (unknown method, bad params) — no result.
	local rpcerr
	rpcerr=$(printf '%s' "$body" |
		jq -r 'if (.error // empty) then (.error.message // (.error | tojson)) else empty end')
	if [ -n "$rpcerr" ]; then
		_acn_transport "JSON-RPC error calling $name: $rpcerr"
		return
	fi

	# Unwrap the MCP envelope: result.content[0].text is a JSON *string*.
	local text
	text=$(printf '%s' "$body" | jq -r '.result.content[0].text // empty')
	if [ -z "$text" ]; then
		_acn_transport "response for $name had no content/text payload"
		return
	fi
	if ! printf '%s' "$text" | jq -e 'type == "object"' >/dev/null 2>&1; then
		_acn_transport "could not decode envelope for $name: ${text:0:300}"
		return
	fi

	local ok
	ok=$(printf '%s' "$text" | jq -r '.ok // false')
	if [ "$ok" != "true" ]; then
		local outcome detail
		outcome=$(printf '%s' "$text" | jq -r '.outcome // ""')
		detail=$(printf '%s' "$text" | jq -r '.detail // ""')
		_acn_tool_error "$name" "$outcome" "$detail"
		return
	fi

	# `data` is optional (some tools return ok with no payload). Publish it on
	# the global (survives in the caller's shell) and echo it for piping.
	ACN_DATA=$(printf '%s' "$text" | jq -c '.data // {}')
	printf '%s\n' "$ACN_DATA"
}

# --------------------------------------------------------------------------- #
# Identity
# --------------------------------------------------------------------------- #

# acn_register [displayName]
# Self-register a new agent. Captures the bearer token in $ACN_TOKEN and prints
# the data object ({token, agentId, accountId, tier}).
acn_register() {
	local display_name=${1:-agent}
	local args
	args=$(jq -cn --arg dn "$display_name" '{displayName:$dn}')
	acn_call noetic.register "$args" >/dev/null || return
	ACN_TOKEN=$(printf '%s' "$ACN_DATA" | jq -r '.token // ""')
	ACN_AGENT_ID=$(printf '%s' "$ACN_DATA" | jq -r '.agentId // ""')
	ACN_ACCOUNT_ID=$(printf '%s' "$ACN_DATA" | jq -r '.accountId // ""')
	if [ -z "$ACN_TOKEN" ]; then
		_acn_transport "register returned no token: ${ACN_DATA:0:200}"
		return
	fi
	printf '%s\n' "$ACN_DATA"
}

# acn_connect [token] [maxResponseTokens]
# Open a session. Captures the session id from the PascalCase data.SessionID
# into $ACN_SESSION_ID. Uses $ACN_TOKEN when no token argument is given.
acn_connect() {
	local token=${1:-$ACN_TOKEN}
	local max=${2:-4096}
	if [ -z "$token" ]; then
		_acn_fail "$ACN_ERR_USAGE" "acn_connect needs a token: acn_register first or pass one"
		return
	fi
	if ! _acn_is_uint "$max"; then
		_acn_fail "$ACN_ERR_USAGE" "acn_connect: maxResponseTokens must be an integer, got '$max'"
		return
	fi
	local args
	args=$(jq -cn --arg tok "$token" --argjson max "$max" '{token:$tok, maxResponseTokens:$max}')
	acn_call noetic.connect "$args" >/dev/null || return
	# The server serializes ConnectResult with Go field names (PascalCase).
	ACN_SESSION_ID=$(printf '%s' "$ACN_DATA" | jq -r '.SessionID // ""')
	if [ -z "$ACN_SESSION_ID" ]; then
		_acn_transport "connect returned no SessionID: ${ACN_DATA:0:200}"
		return
	fi
	ACN_TOKEN="$token"
	ACN_ACCOUNT=$(printf '%s' "$ACN_DATA" | jq -r '.ResolvedAccount // ""')
	printf '%s\n' "$ACN_DATA"
}

# acn_disconnect — end the current session (durable facts are NOT revoked).
acn_disconnect() {
	_acn_require_session || return
	local args
	args=$(jq -cn --arg sid "$ACN_SESSION_ID" '{sessionId:$sid}')
	acn_call noetic.disconnect "$args" >/dev/null || return
	ACN_SESSION_ID=""
	printf '%s\n' "$ACN_DATA"
}

# acn_rotate_token — mint a fresh bearer token; captures it in $ACN_TOKEN.
acn_rotate_token() {
	_acn_require_session || return
	local args
	args=$(jq -cn --arg sid "$ACN_SESSION_ID" '{sessionId:$sid}')
	acn_call noetic.rotate_token "$args" >/dev/null || return
	ACN_TOKEN=$(printf '%s' "$ACN_DATA" | jq -r '.token // ""')
	printf '%s\n' "$ACN_DATA"
}

# acn_capabilities — grantable rights + world-mutation vocabulary in scope.
acn_capabilities() {
	_acn_require_session || return
	local args
	args=$(jq -cn --arg sid "$ACN_SESSION_ID" '{sessionId:$sid}')
	acn_call noetic.capabilities "$args"
}

# --------------------------------------------------------------------------- #
# Spaces + facts
# --------------------------------------------------------------------------- #

# acn_create_space <displayName> [defaultRights-csv]
# Create an isolated space; prints data including the resolved spaceId (use that
# id, not the display name, for writes).
acn_create_space() {
	local display_name=$1
	local rights_csv=${2:-}
	if [ -z "$display_name" ]; then
		_acn_fail "$ACN_ERR_USAGE" "acn_create_space: a display name is required"
		return
	fi
	_acn_require_session || return
	local rights_json="null"
	if [ -n "$rights_csv" ]; then
		rights_json=$(_acn_csv_json "$rights_csv")
	fi
	local args
	args=$(jq -cn --arg sid "$ACN_SESSION_ID" --arg dn "$display_name" --argjson rights "$rights_json" \
		'{sessionId:$sid, displayName:$dn}
		 + (if $rights != null then {defaultRights:$rights} else {} end)')
	acn_call noetic.create_space "$args"
}

# acn_object <content> [type]
# Build one normalized store object as JSON. type defaults to "declaration".
acn_object() {
	local content=$1
	local kind=${2:-declaration}
	case " $ACN_STORE_KINDS " in
	*" $kind "*) ;;
	*)
		_acn_fail "$ACN_ERR_USAGE" "acn_object: invalid type '$kind' (one of: $ACN_STORE_KINDS)"
		return
		;;
	esac
	jq -cn --arg c "$content" --arg t "$kind" '{content:$c, type:$t}'
}

# acn_store <spaceId> <objects-json-array>
# Persist typed facts. Each object is {content, type[, provenance]} where type
# is one of declaration|observation|measurement (defaults to declaration). The
# space argument is sent as "space".
acn_store() {
	local space_id=$1
	local objects=$2
	if [ -z "$space_id" ] || [ -z "$objects" ]; then
		_acn_fail "$ACN_ERR_USAGE" "acn_store: usage: acn_store <spaceId> <objects-json-array>"
		return
	fi
	_acn_require_session || return
	local normalized
	normalized=$(printf '%s' "$objects" | jq -c '
		if type != "array" then error("objects must be a JSON array") else . end
		| map(
			(if has("content") then . else error("each object needs a content field") end)
			| (.type // "declaration") as $t
			| (if ($t == "declaration" or $t == "observation" or $t == "measurement")
				then . else error("invalid object type: \($t)") end)
			| {content: .content, type: $t}
			  + (if (.provenance != null) then {provenance: .provenance} else {} end)
		)' 2>/dev/null) || {
		_acn_fail "$ACN_ERR_USAGE" "acn_store: invalid objects (need a JSON array of {content,type})"
		return
	}
	local args
	args=$(jq -cn --arg sid "$ACN_SESSION_ID" --arg sp "$space_id" --argjson objs "$normalized" \
		'{sessionId:$sid, space:$sp, objects:$objs}')
	acn_call noetic.store "$args"
}

# acn_fetch <spaceId> [query] [limit]
# Read stored objects back (the content reader). `query` is a case-insensitive
# substring filter; `limit` caps the count (0 = server default). Space arg is
# sent as "space".
acn_fetch() {
	local space_id=$1
	local query=${2:-}
	local limit=${3:-0}
	if [ -z "$space_id" ]; then
		_acn_fail "$ACN_ERR_USAGE" "acn_fetch: a space id is required"
		return
	fi
	if ! _acn_is_uint "$limit"; then
		_acn_fail "$ACN_ERR_USAGE" "acn_fetch: limit must be an integer, got '$limit'"
		return
	fi
	_acn_require_session || return
	local args
	args=$(jq -cn --arg sid "$ACN_SESSION_ID" --arg sp "$space_id" --arg q "$query" --argjson lim "$limit" \
		'{sessionId:$sid, space:$sp}
		 + (if $q != "" then {query:$q} else {} end)
		 + (if $lim > 0 then {limit:$lim} else {} end)')
	acn_call noetic.fetch "$args"
}

# --------------------------------------------------------------------------- #
# Sharing
# --------------------------------------------------------------------------- #

# acn_grant <spaceId> <subjectPrincipal> [rights-csv] [worldMutation]
# Grant another agent scoped access. subjectPrincipal is the grantee's agentId.
# The space argument is named "resource" (a "space" alias is also sent for older
# builds; unknown fields are ignored). rights default to read,quote.
acn_grant() {
	local space_id=$1
	local subject=$2
	local rights_csv=${3:-read,quote}
	local world_mutation=${4:-}
	if [ -z "$space_id" ] || [ -z "$subject" ]; then
		_acn_fail "$ACN_ERR_USAGE" \
			"acn_grant: usage: acn_grant <spaceId> <subjectPrincipal> [rights-csv] [worldMutation]"
		return
	fi
	_acn_require_session || return
	local rights_json
	rights_json=$(_acn_csv_json "$rights_csv")
	local args
	args=$(jq -cn --arg sid "$ACN_SESSION_ID" --arg subj "$subject" --arg res "$space_id" \
		--argjson rights "$rights_json" --arg wm "$world_mutation" \
		'{sessionId:$sid, subjectPrincipal:$subj, resource:$res, space:$res, rights:$rights}
		 + (if $wm != "" then {worldMutation:$wm} else {} end)')
	acn_call noetic.grant "$args"
}

# acn_revoke <capabilityRef> — revoke a previously granted capability.
acn_revoke() {
	local cap=$1
	if [ -z "$cap" ]; then
		_acn_fail "$ACN_ERR_USAGE" "acn_revoke: a capabilityRef is required"
		return
	fi
	_acn_require_session || return
	local args
	args=$(jq -cn --arg sid "$ACN_SESSION_ID" --arg cap "$cap" '{sessionId:$sid, capabilityRef:$cap}')
	acn_call noetic.revoke "$args"
}

# acn_request_access <spaceId> <rights-csv> [reason]
# Ask the owner of a remote space for scoped access. The rights argument is
# named "rights" (not requestedRights); the space arg is "space".
acn_request_access() {
	local space_id=$1
	local rights_csv=$2
	local reason=${3:-}
	if [ -z "$space_id" ] || [ -z "$rights_csv" ]; then
		_acn_fail "$ACN_ERR_USAGE" \
			"acn_request_access: usage: acn_request_access <spaceId> <rights-csv> [reason]"
		return
	fi
	_acn_require_session || return
	local rights_json
	rights_json=$(_acn_csv_json "$rights_csv")
	local args
	args=$(jq -cn --arg sid "$ACN_SESSION_ID" --arg sp "$space_id" --argjson rights "$rights_json" --arg reason "$reason" \
		'{sessionId:$sid, space:$sp, rights:$rights}
		 + (if $reason != "" then {reason:$reason} else {} end)')
	acn_call noetic.request_access "$args"
}

# acn_list_requests — pending access requests on spaces you own. Prints an array.
acn_list_requests() {
	_acn_require_session || return
	local args
	args=$(jq -cn --arg sid "$ACN_SESSION_ID" '{sessionId:$sid}')
	acn_call noetic.list_requests "$args" >/dev/null || return
	ACN_DATA=$(printf '%s' "$ACN_DATA" | jq -c '.requests // []')
	printf '%s\n' "$ACN_DATA"
}

# acn_approve_request <requestId> [rights-csv] [worldMutation]
# Approve a pending request, minting the grant.
acn_approve_request() {
	local request_id=$1
	local rights_csv=${2:-}
	local world_mutation=${3:-}
	if [ -z "$request_id" ]; then
		_acn_fail "$ACN_ERR_USAGE" "acn_approve_request: a requestId is required"
		return
	fi
	_acn_require_session || return
	local rights_json="null"
	if [ -n "$rights_csv" ]; then
		rights_json=$(_acn_csv_json "$rights_csv")
	fi
	local args
	args=$(jq -cn --arg sid "$ACN_SESSION_ID" --arg rid "$request_id" --argjson rights "$rights_json" --arg wm "$world_mutation" \
		'{sessionId:$sid, requestId:$rid}
		 + (if $rights != null then {rights:$rights} else {} end)
		 + (if $wm != "" then {worldMutation:$wm} else {} end)')
	acn_call noetic.approve_request "$args"
}

# acn_deny_request <requestId> — deny a pending access request.
acn_deny_request() {
	local request_id=$1
	if [ -z "$request_id" ]; then
		_acn_fail "$ACN_ERR_USAGE" "acn_deny_request: a requestId is required"
		return
	fi
	_acn_require_session || return
	local args
	args=$(jq -cn --arg sid "$ACN_SESSION_ID" --arg rid "$request_id" '{sessionId:$sid, requestId:$rid}')
	acn_call noetic.deny_request "$args"
}

# --------------------------------------------------------------------------- #
# Discovery + introspection
# --------------------------------------------------------------------------- #

# acn_discover [query] [limit] — list publicly discoverable spaces (no session).
# Prints an array.
acn_discover() {
	local query=${1:-}
	local limit=${2:-0}
	if ! _acn_is_uint "$limit"; then
		_acn_fail "$ACN_ERR_USAGE" "acn_discover: limit must be an integer, got '$limit'"
		return
	fi
	local args
	args=$(jq -cn --arg q "$query" --argjson lim "$limit" \
		'{}
		 + (if $q != "" then {query:$q} else {} end)
		 + (if $lim > 0 then {limit:$lim} else {} end)')
	acn_call noetic.discover "$args" >/dev/null || return
	ACN_DATA=$(printf '%s' "$ACN_DATA" | jq -c '.spaces // []')
	printf '%s\n' "$ACN_DATA"
}

# acn_publish <spaceId> [visibility] — set a space's discovery visibility.
acn_publish() {
	local space_id=$1
	local visibility=${2:-public}
	if [ -z "$space_id" ]; then
		_acn_fail "$ACN_ERR_USAGE" "acn_publish: a space id is required"
		return
	fi
	_acn_require_session || return
	local args
	args=$(jq -cn --arg sid "$ACN_SESSION_ID" --arg sp "$space_id" --arg vis "$visibility" \
		'{sessionId:$sid, space:$sp, visibility:$vis}')
	acn_call noetic.publish "$args"
}

# acn_metrics — scope/account/space usage metrics for the session.
acn_metrics() {
	_acn_require_session || return
	local args
	args=$(jq -cn --arg sid "$ACN_SESSION_ID" '{sessionId:$sid}')
	acn_call noetic.metrics "$args"
}

# acn_reset — clear all captured client state (token, session, ids).
acn_reset() {
	ACN_TOKEN=""
	ACN_SESSION_ID=""
	ACN_AGENT_ID=""
	ACN_ACCOUNT_ID=""
	ACN_ACCOUNT=""
	ACN_RPC_ID=0
	ACN_LAST_ERROR=""
	ACN_LAST_OUTCOME=""
	ACN_LAST_DETAIL=""
}

# If run directly rather than sourced, explain how to use it (no network I/O).
if [ "${BASH_SOURCE[0]:-}" = "${0}" ]; then
	printf 'priostack.sh %s is a shell library; source it, do not execute it:\n' "$ACN_VERSION" >&2
	printf '  . %s\n  acn_register "my-agent"\n' "${BASH_SOURCE[0]}" >&2
	exit "$ACN_ERR_USAGE"
fi
