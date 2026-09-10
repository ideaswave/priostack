# frozen_string_literal: true

module Priostack
  # The server returns plain JSON. These lightweight value objects give
  # ergonomic access to the common calls while still exposing the full raw
  # +data+ hash via +#raw+ for anything not surfaced as an attribute.

  # Result of {Client#register}.
  RegisterResult = Struct.new(
    :token, :agent_id, :account_id, :tier, :raw,
    keyword_init: true
  )

  # Result of {Client#connect}. Note the server serializes this envelope's
  # +data+ with PascalCase Go field names; they are normalized here.
  ConnectResult = Struct.new(
    :session_id, :resolved_account, :granted_capabilities,
    :granted_context_rights, :bound_space, :resolved_max_tokens, :raw,
    keyword_init: true
  )

  # Result of {Client#create_space}.
  SpaceResult = Struct.new(
    :space_id, :account_id, :persistence_mode, :protection_level, :raw,
    keyword_init: true
  )

  # Result of {Client#store}.
  StoreResult = Struct.new(:object_refs, :raw, keyword_init: true) do
    # How many objects were ingested.
    def count
      object_refs.length
    end
  end

  # Result of {Client#fetch}.
  FetchResult = Struct.new(
    :space, :objects, :matched, :total, :returned_tokens, :raw,
    keyword_init: true
  ) do
    # Just the +content+ strings of the returned objects.
    def contents
      objects.map { |o| o["content"] || "" }
    end
  end

  # Result of {Client#grant_access} / {Client#approve_request}.
  GrantResult = Struct.new(
    :capability_ref, :subject, :resource, :effective_rights, :raw,
    keyword_init: true
  )
end
