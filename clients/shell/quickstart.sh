#!/usr/bin/env bash
#
# Quickstart for the Priostack ACN shell client:
#   register -> connect -> create_space -> store -> fetch
#
# It talks to the live ACN and registers a throwaway agent. Run it directly:
#
#   ./quickstart.sh                 # display name defaults to "shell-sdk-smoke"
#   ./quickstart.sh my-agent-name   # or pass your own
#
# Override the endpoint with, e.g., ACN_ENDPOINT=https://priostack.com/acn/rpc.

set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=priostack.sh
. "$here/priostack.sh"

main() {
	local display=${1:-shell-sdk-smoke}

	# 1. Self-register (no API key, no dashboard). The token is captured in
	#    $ACN_TOKEN and returned so you can persist it for next time.
	local reg
	reg=$(acn_register "$display")
	printf '1. registered agent %s (tier %s)\n' \
		"$(printf '%s' "$reg" | jq -r '.agentId')" \
		"$(printf '%s' "$reg" | jq -r '.tier')"
	printf '   token (store this, shown once): %s\n' "$ACN_TOKEN"

	# 2. Open a session. The session id is captured in $ACN_SESSION_ID.
	local conn
	conn=$(acn_connect)
	printf '2. session %s | capabilities %s\n' \
		"$ACN_SESSION_ID" \
		"$(printf '%s' "$conn" | jq -c '.GrantedCapabilities // []')"

	# 3. Create an isolated memory space. Use the RETURNED id for writes.
	local space space_id
	space=$(acn_create_space "shell-quickstart-memory")
	space_id=$(printf '%s' "$space" | jq -r '.spaceId')
	printf '3. created space %s\n' "$space_id"

	# 4. Persist typed facts. type is declaration | observation | measurement.
	local objects stored
	objects=$(jq -cn '[
		{content: "User approved execution workflow #402.", type: "declaration"},
		{content: "Export pipeline latency was 1.8s at 14:02 UTC.", type: "observation"}
	]')
	stored=$(acn_store "$space_id" "$objects")
	printf '4. stored %s objects\n' "$(printf '%s' "$stored" | jq '(.objectRefs // []) | length')"

	# 5. Read them back. query is a case-insensitive substring filter.
	local hits
	hits=$(acn_fetch "$space_id" "workflow")
	printf '5. fetched %s/%s (viewport %s tokens):\n' \
		"$(printf '%s' "$hits" | jq -r '.matched')" \
		"$(printf '%s' "$hits" | jq -r '.total')" \
		"$(printf '%s' "$hits" | jq -r '.returnedTokens')"
	printf '%s' "$hits" | jq -r '.objects[]?.content | "     - " + .'

	# Best-effort tidy up: end the session (durable facts are not revoked).
	acn_disconnect >/dev/null || true
	printf 'done.\n'
}

main "$@"
