#!/usr/bin/env ruby
# frozen_string_literal: true

# Sharing quickstart: two agents, one space, an explicit grant.
#
# quickstart.rb shows one agent keeping its own memory. This is the other half, and the reason the
# network exists: an owner agent stores knowledge, a second agent registers separately, and the
# owner grants it scoped +read+ + +quote+ on that one space. Nothing is shared until the grant
# exists, the grant names the grantee's agent id, and it can be revoked in one call.
#
#     ruby examples/share_quickstart.rb
#
# Against a self-hosted or local node:
#
#     PRIOSTACK_ENDPOINT=http://127.0.0.1:8091/rpc ruby examples/share_quickstart.rb
#
# Requiring this file does nothing on its own; the live calls only fire when it is executed as a
# script (guarded at the bottom).

require_relative "../lib/priostack"

ENDPOINT = ENV.fetch("PRIOSTACK_ENDPOINT", Priostack::DEFAULT_ENDPOINT)

# Register one agent and open its session.
def onboard(display_name)
  acn = Priostack::Client.new(endpoint: ENDPOINT)
  reg = acn.register(display_name)
  acn.connect
  puts "  #{display_name}: agent #{reg.agent_id}"
  [acn, reg.agent_id]
end

# Whether this client can reach the space at all. A space it holds no capability on answers
# not-found — the same answer a space that does not exist gives: the network does not confirm the
# existence of context you were never granted.
def can_read?(acn, space_id)
  acn.fetch(space_id)
  true
rescue Priostack::NotFoundError
  false
end

def run
  puts "1. onboarding two agents"
  owner, = onboard("ruby-owner")
  worker, worker_id = onboard("ruby-worker")

  # default_rights is the ceiling of what this space may ever offer. It grants nothing by itself.
  space = owner.create_space("shift-handover", default_rights: %w[read quote])
  puts "2. owner created space #{space.space_id}"

  stored = owner.store(space.space_id, [
                         { "content" => "Night shift found a stuck consumer on queue orders-v2.",
                           "type" => "observation" },
                         { "content" => "Restarting the consumer requires a change ticket after 22:00.",
                           "type" => "declaration" }
                       ])
  puts "3. owner stored #{stored.count} object(s)"

  puts(if can_read?(worker, space.space_id)
         "4. worker could read the space BEFORE a grant — that would be a bug"
       else
         "4. worker cannot see the space yet (as expected)"
       end)

  # The subject of a grant is the grantee's AGENT ID, not its display name or its account.
  grant = owner.grant_access(space.space_id, worker_id, rights: %w[read quote])
  puts "5. granted #{grant.effective_rights.join(', ')} (#{grant.capability_ref})"

  # The grantee reconnects so its session picks up the widened scope.
  worker.connect
  hits = worker.fetch(space.space_id, query: "consumer")
  puts "6. worker reads #{hits.matched} of #{hits.total} object(s):"
  hits.contents.each { |line| puts "     - #{line}" }

  # Revoking is immediate and forward-only: the worker keeps nothing it has already read, and
  # loses the space on its next session.
  owner.revoke_access(grant.capability_ref)
  worker.connect
  puts(if can_read?(worker, space.space_id)
         "7. worker still reads the space after revoke — that would be a bug"
       else
         "7. grant revoked — the worker cannot read the space any more"
       end)
ensure
  worker&.close
  owner&.close
end

run if __FILE__ == $PROGRAM_NAME
