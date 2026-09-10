# frozen_string_literal: true

module Priostack
  # The ACN reports two very different kinds of failure and the client raises a
  # different branch of this hierarchy for each:
  #
  # * *Transport / protocol failures* -- the request never produced a valid tool
  #   envelope: a network error, an HTTP error status, malformed JSON, or a
  #   JSON-RPC +error+ object (unknown method, bad params). These raise
  #   {TransportError}.
  #
  # * *Tool failures* -- the call reached the tool but the tool declined it: the
  #   envelope came back with +ok: false+ and an +outcome+ such as
  #   +capability-denied+ or +not-found+. These raise the matching subclass of
  #   {ToolError}, so callers can rescue exactly the outcome they expect:
  #
  #     begin
  #       acn.store(space_id, objects)
  #     rescue Priostack::CapabilityDeniedError
  #       # the session lacks the write right / mutate capability
  #     end
  #
  # Everything derives from {Error}, so <tt>rescue Priostack::Error</tt> catches
  # anything the client can raise.
  class Error < StandardError
    # The tool name (+noetic.*+) the failing call targeted, if known.
    attr_reader :rpc_method

    def initialize(message = nil, method: nil)
      super(message)
      @rpc_method = method
    end
  end

  # A network, HTTP, decoding, or JSON-RPC protocol failure.
  #
  # Raised before a valid tool envelope could be obtained: connection errors,
  # timeouts, non-2xx HTTP responses, non-JSON bodies, envelopes missing the
  # +content[0].text+ payload, or a JSON-RPC +error+ object.
  class TransportError < Error
    # JSON-RPC error code, when the failure was a JSON-RPC +error+ object.
    attr_reader :code
    # HTTP status code, when the failure was an HTTP error.
    attr_reader :http_status

    def initialize(message = nil, method: nil, code: nil, http_status: nil)
      super(message, method: method)
      @code = code
      @http_status = http_status
    end
  end

  # A tool declined the call (envelope +ok: false+).
  #
  # Carries the server +outcome+ string and human-readable +detail+. Prefer
  # rescuing a specific subclass; rescue this base only when any tool-level
  # failure should be handled the same way.
  class ToolError < Error
    # The +outcome+ string this subclass corresponds to (overridden below).
    OUTCOME = ""

    # The server outcome (e.g. +"capability-denied"+); falls back to the class
    # default when the server omitted it.
    attr_reader :outcome
    # The server's +detail+ message, if any.
    attr_reader :detail
    # Any partial +data+ the server attached to the failure.
    attr_reader :data

    def initialize(detail = nil, outcome: "", method: nil, data: nil)
      message = present(detail) || present(outcome) || "ACN tool error"
      super(message, method: method)
      @outcome = present(outcome) || self.class::OUTCOME
      @detail = detail
      @data = data
    end

    private

    def present(str)
      str && !str.to_s.empty? ? str : nil
    end
  end

  # +not-found+ -- no such session, space, or entity.
  class NotFoundError < ToolError
    OUTCOME = "not-found"
  end

  # +invalid-query+ -- malformed arguments or an unknown enum value.
  class InvalidQueryError < ToolError
    OUTCOME = "invalid-query"
  end

  # +capability-denied+ -- missing capability, or an invalid/revoked token.
  class CapabilityDeniedError < ToolError
    OUTCOME = "capability-denied"
  end

  # +policy-denied+ -- a governance policy refused the operation.
  class PolicyDeniedError < ToolError
    OUTCOME = "policy-denied"
  end

  # +requires-governance+ -- the change needs an explicit confirm step.
  class RequiresGovernanceError < ToolError
    OUTCOME = "requires-governance"
  end

  # +stale-base+ -- the operation raced a newer state; re-read and retry.
  class StaleBaseError < ToolError
    OUTCOME = "stale-base"
  end

  # +integrity-fault+ -- an internal consistency check failed.
  class IntegrityFaultError < ToolError
    OUTCOME = "integrity-fault"
  end

  # +conflict+ -- the write conflicts with existing state.
  class ConflictError < ToolError
    OUTCOME = "conflict"
  end

  # +capacity-exhausted+ -- a tier/registration/store ceiling was hit.
  class CapacityExhaustedError < ToolError
    OUTCOME = "capacity-exhausted"
  end

  # +not-implemented+ -- the tool is unavailable on this ACN deployment.
  #
  # Most commonly: calling {Client#register} against a single-tenant/offline ACN
  # that does not offer self-registration.
  class NotSupportedError < ToolError
    OUTCOME = "not-implemented"
  end

  # Maps a server +outcome+ string to its {ToolError} subclass.
  OUTCOME_ERRORS = {
    NotFoundError::OUTCOME => NotFoundError,
    InvalidQueryError::OUTCOME => InvalidQueryError,
    CapabilityDeniedError::OUTCOME => CapabilityDeniedError,
    PolicyDeniedError::OUTCOME => PolicyDeniedError,
    RequiresGovernanceError::OUTCOME => RequiresGovernanceError,
    StaleBaseError::OUTCOME => StaleBaseError,
    IntegrityFaultError::OUTCOME => IntegrityFaultError,
    ConflictError::OUTCOME => ConflictError,
    CapacityExhaustedError::OUTCOME => CapacityExhaustedError,
    NotSupportedError::OUTCOME => NotSupportedError
  }.freeze

  # Build the most specific {ToolError} for a server +outcome+. Unknown outcomes
  # fall back to the {ToolError} base so a new server outcome degrades
  # gracefully instead of being mis-mapped.
  def self.tool_error_for(outcome, detail, method: nil, data: nil)
    klass = OUTCOME_ERRORS.fetch(outcome, ToolError)
    klass.new(detail, outcome: outcome, method: method, data: data)
  end
end
