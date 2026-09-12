#!/usr/bin/env bash
#
# Sharing quickstart for the Priostack ACN shell client: two agents, one space, an explicit grant.
#
# quickstart.sh shows one agent keeping its own memory. This is the other half, and the reason the
# network exists: an owner agent stores knowledge, a second agent registers separately, and the
# owner grants it scoped read + quote on that one space. Nothing is shared until the grant exists,
# the grant names the grantee's agent id, and it can be revoked in one call.
#
#   ./share_quickstart.sh
#
# Against a self-hosted or local node:
#
#   PRIOSTACK_ENDPOINT=http://127.0.0.1:8091/rpc ./share_quickstart.sh
#
# The shell client keeps ONE agent's state in shell globals (ACN_TOKEN, ACN_SESSION_ID), so this
# script switches between the two agents by resetting that state and reconnecting with the other
# agent's token — which is all an agent identity is: a bearer token and the session it opens.

set -euo pipefail

# ACN_ENDPOINT is this client's own variable; PRIOSTACK_ENDPOINT is the one the other language
# clients read. Accept either, so one exported variable drives every example in the repository.
: "${ACN_ENDPOINT:=${PRIOSTACK_ENDPOINT:-https://priostack.com/mcp}}"
export ACN_ENDPOINT

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=priostack.sh
. "$here/priostack.sh"

# as <token> — become the agent that owns this token: clear the previous agent's state, then open
# a fresh session. Reconnecting is also how a grantee picks up a newly widened scope.
as() {
	local token=$1
	acn_reset
	ACN_TOKEN=$token
	acn_connect >/dev/null
}

# can_read <spaceId> — whether the current agent can reach the space at all. A space it holds no
# capability on answers not-found, the same answer a space that does not exist gives: the network
# does not confirm the existence of context you were never granted.
can_read() {
	local space_id=$1
	if acn_fetch "$space_id" >/dev/null 2>&1; then
		return 0
	fi
	return 1
}

main() {
	printf '1. onboarding two agents\n'

	# acn_register mutates shell state, so it is called in the CURRENT shell (never inside
	# `$(...)`, which would run it in a subshell and lose the token) and its result is read from
	# $ACN_DATA. Here both agents' tokens are kept in variables so the script can switch identity.
	local owner_token owner_id worker_token worker_id
	acn_register "shell-owner" >/dev/null
	owner_token=$ACN_TOKEN
	owner_id=$ACN_AGENT_ID
	printf '  shell-owner: agent %s\n' "$owner_id"

	acn_reset
	acn_register "shell-worker" >/dev/null
	worker_token=$ACN_TOKEN
	worker_id=$ACN_AGENT_ID
	printf '  shell-worker: agent %s\n' "$worker_id"

	# ---- owner ----------------------------------------------------------------------------- #
	as "$owner_token"

	# The default rights are the ceiling of what this space may ever offer. They grant nothing by
	# themselves: until there is a grant, only the owner can read it.
	local space space_id
	space=$(acn_create_space "shift-handover" "read,quote")
	space_id=$(printf '%s' "$space" | jq -r '.spaceId')
	printf '2. owner created space %s\n' "$space_id"

	local objects stored
	objects=$(jq -cn '[
		{content: "Night shift found a stuck consumer on queue orders-v2.", type: "observation"},
		{content: "Restarting the consumer requires a change ticket after 22:00.", type: "declaration"}
	]')
	stored=$(acn_store "$space_id" "$objects")
	printf '3. owner stored %s object(s)\n' "$(printf '%s' "$stored" | jq '(.objectRefs // []) | length')"

	# ---- worker, before any grant ----------------------------------------------------------- #
	as "$worker_token"
	if can_read "$space_id"; then
		printf '4. worker could read the space BEFORE a grant — that would be a bug\n'
	else
		printf '4. worker cannot see the space yet (as expected)\n'
	fi

	# ---- owner grants ----------------------------------------------------------------------- #
	# The subject of a grant is the grantee's AGENT ID, not its display name or its account.
	as "$owner_token"
	local grant cap
	grant=$(acn_grant "$space_id" "$worker_id" "read,quote")
	cap=$(printf '%s' "$grant" | jq -r '.capabilityRef')
	printf '5. granted %s (%s)\n' "$(printf '%s' "$grant" | jq -r '(.effectiveRights // []) | join(", ")')" "$cap"

	# ---- worker reads ----------------------------------------------------------------------- #
	as "$worker_token"
	local hits
	hits=$(acn_fetch "$space_id" "consumer")
	printf '6. worker reads %s of %s object(s):\n' \
		"$(printf '%s' "$hits" | jq -r '.matched')" \
		"$(printf '%s' "$hits" | jq -r '.total')"
	printf '%s' "$hits" | jq -r '.objects[]?.content | "     - " + .'

	# ---- owner revokes ---------------------------------------------------------------------- #
	# Revoking is immediate and forward-only: the worker keeps nothing it has already read, and
	# loses the space on its next session.
	as "$owner_token"
	acn_revoke "$cap" >/dev/null

	as "$worker_token"
	if can_read "$space_id"; then
		printf '7. worker still reads the space after revoke — that would be a bug\n'
	else
		printf '7. grant revoked — the worker cannot read the space any more\n'
	fi

	acn_disconnect >/dev/null || true
}

main "$@"
