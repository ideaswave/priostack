# frozen_string_literal: true

require_relative "priostack/version"

# Official Ruby client for the Priostack Agent Context Network (ACN).
#
# Model-agnostic, zero-setup long-term memory and multi-agent context sharing
# for AI agents, over the Model Context Protocol (MCP). See {Priostack::Client}.
module Priostack
  # Canonical MCP endpoint (Streamable HTTP). +/acn/rpc+ is a working alias.
  DEFAULT_ENDPOINT = "https://priostack.com/mcp"

  # Object +type+ values the +store+ tool accepts. Anything else is rejected
  # server-side with +invalid-query+.
  STORE_KINDS = %w[declaration observation measurement].freeze
end

require_relative "priostack/errors"
require_relative "priostack/results"
require_relative "priostack/client"
