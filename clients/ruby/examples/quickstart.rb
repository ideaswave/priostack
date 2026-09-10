#!/usr/bin/env ruby
# frozen_string_literal: true

# Quickstart: register -> connect -> create_space -> store -> fetch.
#
# Run it directly:
#
#     ruby examples/quickstart.rb
#
# Override the target or display name with environment variables:
#
#     PRIOSTACK_ENDPOINT=https://priostack.com/mcp \
#     PRIOSTACK_DISPLAY_NAME=ruby-sdk-smoke \
#       ruby examples/quickstart.rb
#
# Requiring this file does nothing on its own; the live calls only fire when it
# is executed as a script (guarded at the bottom).

require_relative "../lib/priostack"

def run
  endpoint = ENV.fetch("PRIOSTACK_ENDPOINT", Priostack::DEFAULT_ENDPOINT)
  display  = ENV.fetch("PRIOSTACK_DISPLAY_NAME", "ruby-sdk-smoke")

  Priostack::Client.open(endpoint: endpoint) do |acn|
    reg = acn.register(display)
    puts "registered: agent=#{reg.agent_id} account=#{reg.account_id} tier=#{reg.tier}"

    conn = acn.connect
    puts "connected:  session=#{conn.session_id} account=#{conn.resolved_account}"

    space = acn.create_space("ruby-quickstart")
    puts "space:      #{space.space_id}"

    stored = acn.store(space.space_id, [
      { content: "Refunds over $500 need manager approval.", type: "declaration" },
      { content: "p95 checkout latency was 420ms on 2026-09-09.", type: "measurement" }
    ])
    puts "stored:     #{stored.count} object(s)"

    hits = acn.fetch(space.space_id, query: "refund")
    puts "fetched:    matched=#{hits.matched} total=#{hits.total}"
    hits.objects.each { |obj| puts "  - #{obj['content']}" }
  end
rescue Priostack::ToolError => e
  warn "tool error [#{e.outcome}]: #{e.detail}"
  exit 1
rescue Priostack::TransportError => e
  warn "transport error: #{e.message}"
  exit 1
end

run if __FILE__ == $PROGRAM_NAME
