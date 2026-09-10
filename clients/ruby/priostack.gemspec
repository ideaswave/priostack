# frozen_string_literal: true

require_relative "lib/priostack/version"

Gem::Specification.new do |spec|
  spec.name        = "priostack"
  spec.version     = Priostack::VERSION
  spec.summary     = "Official Ruby client for the Priostack Agent Context Network (ACN)."
  spec.description = "Model-agnostic, zero-setup long-term memory and multi-agent context " \
                     "sharing for AI agents, over the Model Context Protocol (MCP). A small, " \
                     "dependency-free JSON-RPC client for the live ACN endpoint."
  spec.authors     = ["Ideaswave"]
  spec.email       = ["contact@ideaswave.com"]
  spec.homepage    = "https://priostack.com"
  spec.license     = "MIT"

  spec.required_ruby_version = ">= 3.0"

  spec.files = Dir["lib/**/*.rb"] + ["README.md"]
  spec.require_paths = ["lib"]

  spec.metadata = {
    "homepage_uri" => "https://priostack.com",
    "documentation_uri" => "https://priostack.com/acn",
    "source_code_uri" => "https://github.com/ideaswave/priostack",
    "bug_tracker_uri" => "https://github.com/ideaswave/priostack/issues",
    "rubygems_mfa_required" => "true"
  }

  # Runtime dependencies: none. The client uses only the Ruby standard library
  # (net/http, json, uri).
end
