# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

module Priostack
  # A sturdy JSON-RPC client for the Priostack Agent Context Network (ACN).
  #
  # The ACN is a Model Context Protocol (MCP) server reached over JSON-RPC 2.0.
  # An agent self-registers, opens a session with the returned bearer token,
  # creates isolated context spaces, stores typed facts, reads them back, and
  # shares them with other agents through scoped capability grants.
  #
  # This client speaks the exact wire contract of the live server: it unwraps
  # the MCP +result.content[0].text+ envelope, raises typed errors on tool-level
  # denials, reuses one pooled HTTPS connection, and captures the session id
  # automatically on {#connect}.
  #
  #   Priostack::Client.open do |acn|
  #     acn.register("my-agent")             # token captured internally
  #     acn.connect                          # session id captured internally
  #     space = acn.create_space("prod-memory")
  #     acn.store(space.space_id, [
  #       { content: "Refunds over $500 need manager approval.", type: "declaration" }
  #     ])
  #     acn.fetch(space.space_id, query: "refund").contents.each { |c| puts c }
  #   end
  class Client
    # Per-request timeout in seconds (open, read, and write), applied to every
    # call.
    DEFAULT_TIMEOUT = 30

    USER_AGENT = "priostack-ruby/#{VERSION}"

    # A previously issued bearer token. Set by {#register}; may be passed to the
    # constructor to reconnect an existing agent without registering again.
    attr_accessor :token

    # The session id captured on {#connect} (+nil+ until connected).
    attr_reader :session_id

    # The base RPC URL this client targets.
    attr_reader :endpoint

    # @param endpoint [String] base RPC URL. Defaults to the canonical
    #   Streamable-HTTP MCP endpoint; the legacy +/acn/rpc+ path is an alias.
    # @param token [String, nil] a previously issued bearer token.
    # @param timeout [Numeric] per-request timeout in seconds.
    def initialize(endpoint: DEFAULT_ENDPOINT, token: nil, timeout: DEFAULT_TIMEOUT)
      @endpoint = endpoint
      @uri = URI.parse(endpoint)
      unless @uri.is_a?(URI::HTTP)
        raise ArgumentError, "endpoint must be an http(s) URL, got #{endpoint.inspect}"
      end

      @token = token
      @session_id = nil
      @timeout = timeout
      @id = 0
      @mutex = Mutex.new
      @http = build_http
    end

    # Build a client, optionally yield it, and always {#close} it afterwards.
    # Without a block, returns the client (the caller owns {#close}).
    def self.open(**kwargs)
      client = new(**kwargs)
      return client unless block_given?

      begin
        yield client
      ensure
        client.close
      end
    end

    # Whether a session id has been captured.
    def connected?
      !@session_id.nil?
    end

    # Best-effort disconnect (if connected) and release the HTTP connection.
    # Closing never raises.
    def close
      disconnect if @session_id
    rescue StandardError
      # closing must never raise
    ensure
      @http.finish if @http&.started?
    end

    # ------------------------------------------------------------------ #
    # Low-level escape hatch
    # ------------------------------------------------------------------ #

    # Invoke any +noetic.*+ tool and return its unwrapped +data+ hash.
    #
    # This is the low-level call behind every typed method -- use it to reach
    # tools this client does not wrap explicitly. It performs the full round
    # trip: builds the JSON-RPC +tools/call+ envelope, unwraps
    # +result.content[0].text+, and raises a {ToolError} subclass when the tool
    # returns +ok: false+, or a {TransportError} on any protocol failure.
    def call(method, arguments = {})
      response = perform(method, arguments)

      status = response.code.to_i
      if status >= 400
        raise TransportError.new(
          "HTTP #{status} calling #{method}: #{truncate(response.body)}",
          method: method, http_status: status
        )
      end

      begin
        body = JSON.parse(response.body.to_s)
      rescue JSON::ParserError
        raise TransportError.new(
          "non-JSON response calling #{method}: #{truncate(response.body)}", method: method
        )
      end

      # JSON-RPC protocol error (unknown method, bad params) -- no result.
      if body.is_a?(Hash) && body["error"]
        err = body["error"]
        message = err.is_a?(Hash) ? (err["message"] || err) : err
        code = err.is_a?(Hash) ? err["code"] : nil
        raise TransportError.new(
          "JSON-RPC error calling #{method}: #{message}", method: method, code: code
        )
      end

      result = body.is_a?(Hash) ? body["result"] : nil
      unless result.is_a?(Hash)
        raise TransportError.new(
          "malformed response calling #{method}: #{truncate(body)}", method: method
        )
      end

      envelope = unwrap(result, method)

      unless envelope["ok"]
        raise Priostack.tool_error_for(
          envelope["outcome"].to_s,
          envelope["detail"].to_s,
          method: method,
          data: envelope["data"]
        )
      end

      # +data+ is optional (some tools return ok with no payload).
      data = envelope["data"]
      data.is_a?(Hash) ? data : { "data" => data }
    end

    # ------------------------------------------------------------------ #
    # Identity
    # ------------------------------------------------------------------ #

    # Self-register a new agent and capture its bearer token.
    #
    # Only available on the online multi-agent ACN. The token is shown once; it
    # is stored on this client (+#token+) and returned so you can persist it for
    # future sessions. Raises {NotSupportedError} on a single-tenant ACN.
    def register(display_name = "agent")
      data = call("noetic.register", { "displayName" => display_name })
      @token = data["token"]
      RegisterResult.new(
        token: data["token"],
        agent_id: data["agentId"] || "",
        account_id: data["accountId"] || "",
        tier: data["tier"] || "",
        raw: data
      )
    end

    # Open a session with a bearer token and capture the session id.
    #
    # Pass +token+ explicitly, or rely on the token captured by {#register} /
    # passed to the constructor. Re-call +connect+ after being granted access to
    # a space so the widened scope is applied.
    def connect(token = nil, max_tokens: 4096)
      tok = token || @token
      raise TransportError.new("connect needs a token: register first or pass a token") unless tok

      data = call("noetic.connect", { "token" => tok, "maxResponseTokens" => max_tokens })

      # The server serializes the connect result with Go field names (PascalCase).
      @session_id = data["SessionID"]
      @token = tok
      if @session_id.nil? || @session_id.empty?
        raise TransportError.new("connect returned no SessionID: #{data}", method: "noetic.connect")
      end

      ConnectResult.new(
        session_id: @session_id,
        resolved_account: data["ResolvedAccount"] || "",
        granted_capabilities: data["GrantedCapabilities"] || [],
        granted_context_rights: data["GrantedContextRights"] || [],
        bound_space: data["BoundSpace"] || "",
        resolved_max_tokens: data["ResolvedMaxTokens"] || 0,
        raw: data
      )
    end

    # End the current session. Durable facts are *not* revoked.
    def disconnect
      sid = require_session!
      data = call("noetic.disconnect", { "sessionId" => sid })
      @session_id = nil
      data
    end

    # Mint a fresh bearer token for this agent and retire the old one. Existing
    # sessions keep working; use the new token for future {#connect} calls. The
    # new token is stored on this client and returned.
    def rotate_token
      sid = require_session!
      data = call("noetic.rotate_token", { "sessionId" => sid })
      @token = data["token"]
      data["token"]
    end

    # Discover the grantable rights + world-mutation vocabulary in scope.
    def capabilities
      sid = require_session!
      call("noetic.capabilities", { "sessionId" => sid })
    end

    # ------------------------------------------------------------------ #
    # Spaces + facts
    # ------------------------------------------------------------------ #

    # Create an isolated context space and return its resolved id.
    #
    # +default_rights+ is the ceiling of rights the space may offer to others;
    # it does not grant anything by itself.
    def create_space(display_name, default_rights: nil, visibility: nil,
                     persistence_mode: nil, protection_level: nil)
      sid = require_session!
      args = { "sessionId" => sid, "displayName" => display_name }
      args["defaultRights"] = default_rights.to_a if default_rights
      args["visibility"] = visibility if visibility
      args["persistenceMode"] = persistence_mode if persistence_mode
      args["protectionLevel"] = protection_level if protection_level

      data = call("noetic.create_space", args)
      SpaceResult.new(
        space_id: data.fetch("spaceId"),
        account_id: data["accountId"] || "",
        persistence_mode: data["persistenceMode"] || "",
        protection_level: data["protectionLevel"] || "",
        raw: data
      )
    end

    # Persist typed facts into a space.
    #
    # Each object is <tt>{ content:, type:, provenance?: }</tt> where +type+ is
    # one of {Priostack::STORE_KINDS}
    # (+declaration+/+observation+/+measurement+). String or symbol keys are
    # both accepted. Writing needs the write right and the +mutate+ capability;
    # the space owner has both.
    def store(space_id, objects)
      sid = require_session!
      objs = objects.map { |o| normalize_object(o) }
      data = call("noetic.store", { "sessionId" => sid, "space" => space_id, "objects" => objs })
      StoreResult.new(object_refs: data["objectRefs"] || [], raw: data)
    end

    # Read stored objects back from a space (this is the content reader).
    #
    # +query+ is a case-insensitive *substring* filter over content (not
    # semantic search); +limit+ caps the count (0 = server default). This is
    # distinct from +noetic.query+, which is a geometric divergence probe.
    def fetch(space_id, query: "", limit: 0)
      sid = require_session!
      args = { "sessionId" => sid, "space" => space_id }
      args["query"] = query unless query.nil? || query.empty?
      args["limit"] = limit if limit && !limit.zero?

      data = call("noetic.fetch", args)
      FetchResult.new(
        space: data["space"] || space_id,
        objects: data["objects"] || [],
        matched: data["matched"] || 0,
        total: data["total"] || 0,
        returned_tokens: data["returnedTokens"] || 0,
        raw: data
      )
    end

    # ------------------------------------------------------------------ #
    # Sharing
    # ------------------------------------------------------------------ #

    # Grant another agent scoped access to a space you own.
    #
    # +subject_principal+ is the grantee's agentId. +rights+ are content rights
    # (+read+/+write+/+quote+/+share+/+export+/...). +world_mutation+ is the
    # separate mutation ladder (+read+/+propose+/+mutate+); leave it +nil+ and
    # the server derives it from the rights (granting +write+ confers +mutate+).
    def grant_access(space_id, subject_principal, rights: %w[read quote],
                     world_mutation: nil, persistence_mode: nil)
      sid = require_session!
      # The server names the space argument +resource+. +space+ is sent too as a
      # harmless alias for older builds; unknown fields are ignored server-side.
      args = {
        "sessionId" => sid,
        "subjectPrincipal" => subject_principal,
        "resource" => space_id,
        "space" => space_id,
        "rights" => rights.to_a
      }
      args["worldMutation"] = world_mutation if world_mutation
      args["persistenceMode"] = persistence_mode if persistence_mode

      grant_result(call("noetic.grant", args))
    end

    # Revoke a previously granted capability (immediate, forward-only).
    def revoke_access(capability_ref)
      sid = require_session!
      call("noetic.revoke", { "sessionId" => sid, "capabilityRef" => capability_ref })
    end

    # Ask the owner of a remote space for scoped access (consumer side).
    def request_access(space_id, rights, reason: "", persistence_mode: nil)
      sid = require_session!
      # The server names this argument +rights+ (not +requestedRights+).
      args = { "sessionId" => sid, "space" => space_id, "rights" => rights.to_a }
      args["persistenceMode"] = persistence_mode if persistence_mode
      args["reason"] = reason unless reason.nil? || reason.empty?

      call("noetic.request_access", args)
    end

    # List pending access requests on spaces you own (owner side).
    def list_requests
      sid = require_session!
      data = call("noetic.list_requests", { "sessionId" => sid })
      data["requests"] || []
    end

    # Approve a pending access request, minting the grant (owner side).
    def approve_request(request_id, rights: nil, world_mutation: nil, persistence_mode: nil)
      sid = require_session!
      args = { "sessionId" => sid, "requestId" => request_id }
      args["rights"] = rights.to_a if rights
      args["worldMutation"] = world_mutation if world_mutation
      args["persistenceMode"] = persistence_mode if persistence_mode

      grant_result(call("noetic.approve_request", args))
    end

    # Deny a pending access request (owner side).
    def deny_request(request_id)
      sid = require_session!
      call("noetic.deny_request", { "sessionId" => sid, "requestId" => request_id })
    end

    # ------------------------------------------------------------------ #
    # Discovery + introspection
    # ------------------------------------------------------------------ #

    # List publicly discoverable spaces (no session required).
    def discover(query = "", limit: 0)
      args = {}
      args["query"] = query unless query.nil? || query.empty?
      args["limit"] = limit if limit && !limit.zero?
      data = call("noetic.discover", args)
      data["spaces"] || []
    end

    # Set a space's discovery visibility.
    def publish(space_id, visibility: "public")
      sid = require_session!
      call("noetic.publish", { "sessionId" => sid, "space" => space_id, "visibility" => visibility })
    end

    # Return scope/account/space usage metrics for the session.
    def metrics
      sid = require_session!
      call("noetic.metrics", { "sessionId" => sid })
    end

    private

    def build_http
      http = Net::HTTP.new(@uri.host, @uri.port)
      http.use_ssl = (@uri.scheme == "https")
      http.open_timeout = @timeout
      http.read_timeout = @timeout
      http.write_timeout = @timeout if http.respond_to?(:write_timeout=)
      http.keep_alive_timeout = @timeout
      http
    end

    # Post one JSON-RPC request over the reused connection. Serialized by a mutex
    # because a single Net::HTTP connection is not safe for concurrent requests.
    def perform(method, arguments)
      @mutex.synchronize do
        payload = {
          "jsonrpc" => "2.0",
          "id" => (@id += 1),
          "method" => "tools/call",
          "params" => { "name" => method, "arguments" => arguments }
        }
        request = Net::HTTP::Post.new(@uri.request_uri)
        request["Content-Type"] = "application/json"
        # Ask for a plain JSON reply; the Streamable-HTTP endpoint would
        # otherwise be free to answer a POST as a one-shot SSE frame.
        request["Accept"] = "application/json"
        request["User-Agent"] = USER_AGENT
        request.body = JSON.generate(payload)

        begin
          @http.request(request)
        rescue StandardError => e
          raise TransportError.new(
            "network error calling #{method}: #{e.class}: #{e.message}", method: method
          )
        end
      end
    end

    # Parse the MCP +content[0].text+ JSON envelope out of a result.
    def unwrap(result, method)
      content = result["content"]
      unless content.is_a?(Array) && !content.empty?
        raise TransportError.new("response for #{method} had no content block", method: method)
      end

      first = content[0]
      text = first.is_a?(Hash) ? first["text"] : nil
      unless text.is_a?(String)
        raise TransportError.new("response for #{method} had no text payload", method: method)
      end

      begin
        envelope = JSON.parse(text)
      rescue JSON::ParserError
        raise TransportError.new(
          "could not decode envelope for #{method}: #{truncate(text, 300)}", method: method
        )
      end

      unless envelope.is_a?(Hash)
        raise TransportError.new("envelope for #{method} was not an object", method: method)
      end
      envelope
    end

    def require_session!
      raise TransportError.new("no active session: call connect first") unless @session_id

      @session_id
    end

    def normalize_object(obj)
      content = dig_key(obj, :content)
      raise ArgumentError, "each stored object needs a 'content' field" if content.nil?

      kind = dig_key(obj, :type) || "declaration"
      unless STORE_KINDS.include?(kind)
        raise ArgumentError,
              "invalid object type #{kind.inspect}; must be one of #{STORE_KINDS.join(', ')}"
      end

      out = { "content" => content, "type" => kind }
      provenance = dig_key(obj, :provenance)
      out["provenance"] = provenance.to_a if provenance && !provenance.to_a.empty?
      out
    end

    # Read a key from a hash that may use symbol or string keys.
    def dig_key(hash, key)
      return nil unless hash.is_a?(Hash)

      hash.fetch(key) { hash[key.to_s] }
    end

    def grant_result(data)
      GrantResult.new(
        capability_ref: data["capabilityRef"] || "",
        subject: data["subject"] || "",
        resource: data["resource"] || "",
        effective_rights: data["effectiveRights"] || [],
        raw: data
      )
    end

    def truncate(value, limit = 500)
      str = value.to_s
      str.length > limit ? str[0, limit] : str
    end
  end
end
