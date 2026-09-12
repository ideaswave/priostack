// Priostack Agent Context Network (ACN) — official C++ client.
//
// The ACN is a Model Context Protocol (MCP) server reached over JSON-RPC 2.0.
// An agent self-registers, opens a session with the returned bearer token,
// creates isolated context spaces, stores typed facts, reads them back, and
// shares them with other agents through scoped capability grants.
//
// This header-only client speaks the exact wire contract of the live server:
// it unwraps the MCP ``result.content[0].text`` envelope, throws typed
// exceptions on tool-level denials, reuses one pooled libcurl connection, and
// captures the session id automatically on connect().
//
// It is a faithful port of the verified Python reference client
// (priostack.ACNClient). See clients/SPEC.md for the authoritative contract.
//
// Dependencies: libcurl (HTTP) and the vendored nlohmann/json single header.
// Link with -lcurl. Requires C++17.
//
// Quickstart:
//
//     #include <priostack/priostack.hpp>
//     priostack::ACNClient acn;                       // default endpoint
//     acn.register_agent("my-agent");                 // token captured
//     acn.connect();                                  // session captured
//     auto space = acn.create_space("prod-memory");
//     acn.store(space.space_id, {
//         {"Refunds over $500 need manager approval.", "declaration"},
//     });
//     auto hits = acn.fetch(space.space_id, "refund");
//     for (const auto& c : hits.contents()) std::cout << c << "\n";
//
// SPDX-License-Identifier: MIT

#ifndef PRIOSTACK_PRIOSTACK_HPP
#define PRIOSTACK_PRIOSTACK_HPP

#include <array>
#include <atomic>
#include <mutex>
#include <optional>
#include <stdexcept>
#include <string>
#include <vector>

#include <curl/curl.h>

#include "vendor/json.hpp"

namespace priostack {

using json = nlohmann::json;

/// This client library's version (reported in the User-Agent header).
inline constexpr const char* kVersion = "0.3.0";

/// Canonical MCP endpoint (Streamable HTTP). ``/acn/rpc`` is a working alias.
inline constexpr const char* kDefaultEndpoint = "https://priostack.com/mcp";

/// Object ``type`` values the ``store`` tool accepts. Anything else is
/// rejected server-side with ``invalid-query``.
inline const std::array<const char*, 3> kStoreKinds = {
    "declaration", "observation", "measurement"};

// --------------------------------------------------------------------------- //
// Exceptions
//
// Two very different kinds of failure map to two branches of this hierarchy:
//   * transport / protocol failures (no valid tool envelope was produced) ->
//     ACNTransportError;
//   * tool failures (the tool declined the call, envelope ``ok:false``) ->
//     the ACNToolError subclass matching the server ``outcome``.
// Everything derives from ACNError, so ``catch (const ACNError&)`` catches all.
// --------------------------------------------------------------------------- //

/// Base class for every error raised by ACNClient.
class ACNError : public std::runtime_error {
 public:
  explicit ACNError(const std::string& message, std::string method = "")
      : std::runtime_error(message), method_(std::move(method)) {}

  /// The tool name (``noetic.*``) the failing call targeted, if known.
  const std::string& method() const noexcept { return method_; }

 private:
  std::string method_;
};

/// A network, HTTP, decoding, or JSON-RPC protocol failure.
///
/// Raised before a valid tool envelope could be obtained: connection errors,
/// timeouts, non-2xx HTTP responses, non-JSON bodies, envelopes missing the
/// ``content[0].text`` payload, or a JSON-RPC ``error`` object.
class ACNTransportError : public ACNError {
 public:
  explicit ACNTransportError(const std::string& message, std::string method = "",
                             std::optional<long> code = std::nullopt,
                             std::optional<long> http_status = std::nullopt)
      : ACNError(message, std::move(method)),
        code_(code),
        http_status_(http_status) {}

  /// JSON-RPC error code, when the failure was a JSON-RPC ``error``.
  std::optional<long> code() const noexcept { return code_; }
  /// HTTP status code, when the failure was an HTTP error.
  std::optional<long> http_status() const noexcept { return http_status_; }

 private:
  std::optional<long> code_;
  std::optional<long> http_status_;
};

/// A tool declined the call (envelope ``ok:false``).
///
/// Carries the server ``outcome`` string and human-readable ``detail``. Prefer
/// catching a specific subclass; catch this base only when any tool-level
/// failure should be handled the same way.
class ACNToolError : public ACNError {
 public:
  ACNToolError(const std::string& detail, std::string outcome = "",
               std::string method = "", json data = nullptr)
      : ACNError(detail.empty() ? (outcome.empty() ? "ACN tool error" : outcome)
                                : detail,
                 std::move(method)),
        outcome_(std::move(outcome)),
        detail_(detail),
        data_(std::move(data)) {}

  /// The server outcome (e.g. ``"capability-denied"``).
  const std::string& outcome() const noexcept { return outcome_; }
  /// The server's ``detail`` message, if any.
  const std::string& detail() const noexcept { return detail_; }
  /// Any partial ``data`` the server attached to the failure.
  const json& data() const noexcept { return data_; }

 private:
  std::string outcome_;
  std::string detail_;
  json data_;
};

// Concrete outcome subclasses. Each mirrors one server ``outcome`` string so
// callers can catch exactly the failure they expect.
#define PRIOSTACK_TOOL_ERROR(Name)                                            \
  class Name : public ACNToolError {                                          \
   public:                                                                    \
    using ACNToolError::ACNToolError;                                         \
  }

PRIOSTACK_TOOL_ERROR(NotFoundError);            // not-found
PRIOSTACK_TOOL_ERROR(InvalidQueryError);        // invalid-query
PRIOSTACK_TOOL_ERROR(CapabilityDeniedError);    // capability-denied
PRIOSTACK_TOOL_ERROR(PolicyDeniedError);        // policy-denied
PRIOSTACK_TOOL_ERROR(RequiresGovernanceError);  // requires-governance
PRIOSTACK_TOOL_ERROR(StaleBaseError);           // stale-base
PRIOSTACK_TOOL_ERROR(IntegrityFaultError);      // integrity-fault
PRIOSTACK_TOOL_ERROR(ConflictError);            // conflict
PRIOSTACK_TOOL_ERROR(CapacityExhaustedError);   // capacity-exhausted
PRIOSTACK_TOOL_ERROR(NotSupportedError);        // not-implemented

#undef PRIOSTACK_TOOL_ERROR

namespace detail {

/// Throw the most specific ACNToolError subclass for a server ``outcome``.
/// Unknown outcomes fall back to the ACNToolError base so a new server outcome
/// degrades gracefully instead of being mis-mapped.
[[noreturn]] inline void throw_tool_error(const std::string& outcome,
                                          const std::string& detail,
                                          const std::string& method,
                                          json data) {
  if (outcome == "not-found")
    throw NotFoundError(detail, outcome, method, std::move(data));
  if (outcome == "invalid-query")
    throw InvalidQueryError(detail, outcome, method, std::move(data));
  if (outcome == "capability-denied")
    throw CapabilityDeniedError(detail, outcome, method, std::move(data));
  if (outcome == "policy-denied")
    throw PolicyDeniedError(detail, outcome, method, std::move(data));
  if (outcome == "requires-governance")
    throw RequiresGovernanceError(detail, outcome, method, std::move(data));
  if (outcome == "stale-base")
    throw StaleBaseError(detail, outcome, method, std::move(data));
  if (outcome == "integrity-fault")
    throw IntegrityFaultError(detail, outcome, method, std::move(data));
  if (outcome == "conflict")
    throw ConflictError(detail, outcome, method, std::move(data));
  if (outcome == "capacity-exhausted")
    throw CapacityExhaustedError(detail, outcome, method, std::move(data));
  if (outcome == "not-implemented")
    throw NotSupportedError(detail, outcome, method, std::move(data));
  throw ACNToolError(detail, outcome, method, std::move(data));
}

/// Ensure curl_global_init runs exactly once for the process. libcurl is
/// initialised on first client construction; a matching global cleanup is
/// intentionally omitted (standard for a long-lived library).
inline void ensure_global_init() {
  static const CURLcode rc = curl_global_init(CURL_GLOBAL_DEFAULT);
  (void)rc;
}

}  // namespace detail

// --------------------------------------------------------------------------- //
// Typed result objects
//
// The server returns plain JSON. These lightweight structs give ergonomic
// access to the common calls while still exposing the full raw ``data`` via
// ``.raw`` for anything not surfaced as a field.
// --------------------------------------------------------------------------- //

struct RegisterResult {
  std::string token;
  std::string agent_id;
  std::string account_id;
  std::string tier;
  json raw;
};

/// Result of connect(). Note the server serialises these with Go field names
/// (PascalCase); the client reads ``SessionID`` etc. and exposes them here.
struct ConnectResult {
  std::string session_id;
  std::string resolved_account;
  std::vector<std::string> granted_capabilities;
  std::vector<std::string> granted_context_rights;
  std::string bound_space;
  long resolved_max_tokens = 0;
  json raw;
};

struct SpaceResult {
  std::string space_id;
  std::string account_id;
  std::string persistence_mode;
  std::string protection_level;
  json raw;
};

struct StoreResult {
  std::vector<json> object_refs;
  json raw;

  /// How many objects were ingested.
  std::size_t count() const noexcept { return object_refs.size(); }
};

struct FetchResult {
  std::string space;
  std::vector<json> objects;
  long matched = 0;
  long total = 0;
  long returned_tokens = 0;
  json raw;

  /// Just the ``content`` strings of the returned objects.
  std::vector<std::string> contents() const {
    std::vector<std::string> out;
    out.reserve(objects.size());
    for (const auto& o : objects) out.push_back(o.value("content", std::string()));
    return out;
  }
};

struct GrantResult {
  std::string capability_ref;
  std::string subject;
  std::string resource;
  std::vector<std::string> effective_rights;
  json raw;
};

/// A single typed fact to store. ``type`` must be one of kStoreKinds.
struct StoreObject {
  std::string content;
  std::string type = "declaration";
  std::vector<std::string> provenance;

  StoreObject() = default;
  StoreObject(std::string content_, std::string type_ = "declaration",
              std::vector<std::string> provenance_ = {})
      : content(std::move(content_)),
        type(std::move(type_)),
        provenance(std::move(provenance_)) {}
};

// --------------------------------------------------------------------------- //
// The client
// --------------------------------------------------------------------------- //

/// A sturdy JSON-RPC client for the Priostack ACN.
///
/// One ACNClient owns a single reusable libcurl handle (keep-alive connection
/// reuse) and serialises its calls with an internal mutex, so a client is safe
/// to share but processes one request at a time. Create several clients for
/// concurrency. The bearer token and session id are captured automatically by
/// register_agent()/connect().
class ACNClient {
 public:
  explicit ACNClient(std::string endpoint = kDefaultEndpoint,
                     std::string token = "", long timeout_seconds = 30)
      : endpoint_(std::move(endpoint)),
        token_(std::move(token)),
        timeout_seconds_(timeout_seconds) {
    detail::ensure_global_init();
    curl_ = curl_easy_init();
    if (!curl_) throw ACNTransportError("failed to initialise libcurl handle");

    headers_ = curl_slist_append(headers_, "Content-Type: application/json");
    // Ask for a plain JSON reply; the Streamable-HTTP endpoint would otherwise
    // be free to answer a POST as a one-shot SSE frame.
    headers_ = curl_slist_append(headers_, "Accept: application/json");

    const std::string ua = std::string("priostack-cpp/") + kVersion;
    curl_easy_setopt(curl_, CURLOPT_URL, endpoint_.c_str());
    curl_easy_setopt(curl_, CURLOPT_POST, 1L);
    curl_easy_setopt(curl_, CURLOPT_HTTPHEADER, headers_);
    curl_easy_setopt(curl_, CURLOPT_USERAGENT, ua.c_str());
    curl_easy_setopt(curl_, CURLOPT_TIMEOUT, timeout_seconds_);
    curl_easy_setopt(curl_, CURLOPT_CONNECTTIMEOUT, timeout_seconds_);
    curl_easy_setopt(curl_, CURLOPT_ACCEPT_ENCODING, "");  // all supported
    curl_easy_setopt(curl_, CURLOPT_WRITEFUNCTION, &ACNClient::write_cb);
  }

  ~ACNClient() {
    // Best-effort disconnect; closing must never throw.
    try {
      if (!session_id_.empty()) disconnect();
    } catch (...) {
    }
    if (headers_) curl_slist_free_all(headers_);
    if (curl_) curl_easy_cleanup(curl_);
  }

  ACNClient(const ACNClient&) = delete;
  ACNClient& operator=(const ACNClient&) = delete;
  ACNClient(ACNClient&&) = delete;
  ACNClient& operator=(ACNClient&&) = delete;

  // -- state ------------------------------------------------------------- //
  const std::string& token() const noexcept { return token_; }
  const std::string& session_id() const noexcept { return session_id_; }
  bool connected() const noexcept { return !session_id_.empty(); }

  // -- transport --------------------------------------------------------- //

  /// Invoke any ``noetic.*`` tool and return its unwrapped ``data`` object.
  ///
  /// This is the low-level escape hatch behind every typed method — use it to
  /// reach tools this client does not wrap explicitly. It performs the full
  /// round trip: builds the JSON-RPC ``tools/call`` envelope, unwraps
  /// ``result.content[0].text``, and throws an ACNToolError subclass when the
  /// tool returns ``ok:false``.
  json call(const std::string& method, const json& arguments) {
    std::lock_guard<std::mutex> lock(mutex_);

    const json payload = {{"jsonrpc", "2.0"},
                          {"id", next_id_++},
                          {"method", "tools/call"},
                          {"params", {{"name", method}, {"arguments", arguments}}}};
    const std::string body = payload.dump();

    std::string response;
    response.reserve(4096);
    curl_easy_setopt(curl_, CURLOPT_POSTFIELDSIZE, static_cast<long>(body.size()));
    curl_easy_setopt(curl_, CURLOPT_COPYPOSTFIELDS, body.c_str());
    curl_easy_setopt(curl_, CURLOPT_WRITEDATA, &response);

    const CURLcode rc = curl_easy_perform(curl_);
    if (rc != CURLE_OK) {
      throw ACNTransportError(
          "network error calling " + method + ": " + curl_easy_strerror(rc),
          method);
    }

    long status = 0;
    curl_easy_getinfo(curl_, CURLINFO_RESPONSE_CODE, &status);
    if (status >= 400) {
      throw ACNTransportError("HTTP " + std::to_string(status) + " calling " +
                                  method + ": " + truncate(response, 500),
                              method, std::nullopt, status);
    }

    json parsed;
    try {
      parsed = json::parse(response);
    } catch (const json::exception&) {
      throw ACNTransportError(
          "non-JSON response calling " + method + ": " + truncate(response, 500),
          method);
    }

    // JSON-RPC protocol error (unknown method, bad params) — no result.
    if (parsed.is_object() && parsed.contains("error") &&
        !parsed["error"].is_null()) {
      const json& err = parsed["error"];
      const std::string msg =
          err.is_object() ? err.value("message", err.dump()) : err.dump();
      std::optional<long> code;
      if (err.is_object() && err.contains("code") && err["code"].is_number())
        code = err["code"].get<long>();
      throw ACNTransportError("JSON-RPC error calling " + method + ": " + msg,
                              method, code);
    }

    if (!parsed.is_object() || !parsed.contains("result") ||
        !parsed["result"].is_object()) {
      throw ACNTransportError(
          "malformed response calling " + method + ": " + truncate(response, 500),
          method);
    }

    const json envelope = unwrap(parsed["result"], method);

    if (!envelope.value("ok", false)) {
      detail::throw_tool_error(
          envelope.value("outcome", std::string()),
          envelope.value("detail", std::string()), method,
          envelope.contains("data") ? envelope["data"] : json(nullptr));
    }

    // ``data`` is optional (some tools return ok with no payload).
    if (envelope.contains("data") && envelope["data"].is_object())
      return envelope["data"];
    if (envelope.contains("data")) return json{{"data", envelope["data"]}};
    return json::object();
  }

  // -- identity ---------------------------------------------------------- //

  /// Self-register a new agent and capture its bearer token.
  ///
  /// The token is shown once; it is stored on this client and returned so you
  /// can persist it for future sessions. Throws NotSupportedError on a
  /// single-tenant ACN that does not offer self-registration.
  RegisterResult register_agent(const std::string& display_name = "agent") {
    json data = call("noetic.register", {{"displayName", display_name}});
    token_ = data.at("token").get<std::string>();
    return RegisterResult{token_, data.value("agentId", std::string()),
                          data.value("accountId", std::string()),
                          data.value("tier", std::string()), data};
  }

  /// Open a session with a bearer token and capture the session id.
  ///
  /// Pass ``token`` explicitly, or rely on the token captured by
  /// register_agent() / passed to the constructor. Re-call connect() after
  /// being granted access to a space so the widened scope is applied.
  ///
  /// CRITICAL: the connect envelope ``data`` uses PascalCase Go field names;
  /// the session id is read from ``SessionID`` (not ``sessionId``).
  ConnectResult connect(const std::string& token = "", long max_tokens = 4096) {
    const std::string tok = token.empty() ? token_ : token;
    if (tok.empty()) {
      throw ACNTransportError(
          "connect() needs a token: register_agent() first or pass one");
    }
    json data =
        call("noetic.connect", {{"token", tok}, {"maxResponseTokens", max_tokens}});

    session_id_ = data.value("SessionID", std::string());
    token_ = tok;
    if (session_id_.empty()) {
      throw ACNTransportError("connect returned no SessionID: " + data.dump(),
                              "noetic.connect");
    }
    return ConnectResult{session_id_,
                         data.value("ResolvedAccount", std::string()),
                         str_list(data, "GrantedCapabilities"),
                         str_list(data, "GrantedContextRights"),
                         data.value("BoundSpace", std::string()),
                         data.value("ResolvedMaxTokens", 0L),
                         data};
  }

  /// End the current session. Durable facts are NOT revoked.
  json disconnect() {
    const std::string sid = require_session();
    json data = call("noetic.disconnect", {{"sessionId", sid}});
    session_id_.clear();
    return data;
  }

  /// Mint a fresh bearer token for this agent and retire the old one. Existing
  /// sessions keep working; the new token is stored on this client and returned.
  std::string rotate_token() {
    const std::string sid = require_session();
    json data = call("noetic.rotate_token", {{"sessionId", sid}});
    token_ = data.at("token").get<std::string>();
    return token_;
  }

  /// Discover the grantable rights + world-mutation vocabulary in scope.
  json capabilities() {
    return call("noetic.capabilities", {{"sessionId", require_session()}});
  }

  // -- spaces + facts ---------------------------------------------------- //

  /// Create an isolated context space and return its resolved id.
  ///
  /// ``default_rights`` is the ceiling of rights the space may offer to others;
  /// it does not grant anything by itself. Use the RETURNED space id for writes.
  SpaceResult create_space(
      const std::string& display_name,
      std::optional<std::vector<std::string>> default_rights = std::nullopt,
      std::optional<std::string> visibility = std::nullopt,
      std::optional<std::string> persistence_mode = std::nullopt,
      std::optional<std::string> protection_level = std::nullopt) {
    json args = {{"sessionId", require_session()}, {"displayName", display_name}};
    if (default_rights) args["defaultRights"] = *default_rights;
    if (visibility) args["visibility"] = *visibility;
    if (persistence_mode) args["persistenceMode"] = *persistence_mode;
    if (protection_level) args["protectionLevel"] = *protection_level;
    json data = call("noetic.create_space", args);
    return SpaceResult{data.at("spaceId").get<std::string>(),
                       data.value("accountId", std::string()),
                       data.value("persistenceMode", std::string()),
                       data.value("protectionLevel", std::string()), data};
  }

  /// Persist typed facts into a space.
  ///
  /// Each object's ``type`` must be one of kStoreKinds
  /// (declaration/observation/measurement). Writing needs the write right and
  /// the ``mutate`` capability; the space owner has both. The argument key for
  /// the space id is ``space``.
  StoreResult store(const std::string& space_id,
                    const std::vector<StoreObject>& objects) {
    json objs = json::array();
    for (const auto& o : objects) objs.push_back(normalize_object(o));
    json data = call("noetic.store", {{"sessionId", require_session()},
                                      {"space", space_id},
                                      {"objects", objs}});
    return StoreResult{json_array_to_vec(data, "objectRefs"), data};
  }

  /// Read stored objects back from a space (this is the content reader).
  ///
  /// ``query`` is a case-insensitive substring filter over content (not
  /// semantic search); ``limit`` caps the count (0 = server default). The
  /// argument key for the space id is ``space``.
  FetchResult fetch(const std::string& space_id, const std::string& query = "",
                    long limit = 0) {
    json args = {{"sessionId", require_session()}, {"space", space_id}};
    if (!query.empty()) args["query"] = query;
    if (limit) args["limit"] = limit;
    json data = call("noetic.fetch", args);
    return FetchResult{data.value("space", space_id),
                       json_array_to_vec(data, "objects"),
                       data.value("matched", 0L),
                       data.value("total", 0L),
                       data.value("returnedTokens", 0L),
                       data};
  }

  // -- sharing ----------------------------------------------------------- //

  /// Grant another agent scoped access to a space you own.
  ///
  /// ``subject_principal`` is the grantee's agentId. ``world_mutation`` is the
  /// separate mutation ladder (read/propose/mutate); leave it empty and the
  /// server derives it from the rights (granting ``write`` confers ``mutate``).
  /// NOTE: the space argument is named ``resource`` (not ``space``).
  GrantResult grant_access(
      const std::string& space_id, const std::string& subject_principal,
      std::vector<std::string> rights = {"read", "quote"},
      std::optional<std::string> world_mutation = std::nullopt,
      std::optional<std::string> persistence_mode = std::nullopt) {
    // The server names the space argument ``resource``; ``space`` is sent too
    // as a harmless alias for older builds (unknown fields are ignored).
    json args = {{"sessionId", require_session()},
                 {"subjectPrincipal", subject_principal},
                 {"resource", space_id},
                 {"space", space_id},
                 {"rights", rights}};
    if (world_mutation) args["worldMutation"] = *world_mutation;
    if (persistence_mode) args["persistenceMode"] = *persistence_mode;
    return grant_result(call("noetic.grant", args));
  }

  /// Revoke a previously granted capability (immediate, forward-only).
  json revoke_access(const std::string& capability_ref) {
    return call("noetic.revoke", {{"sessionId", require_session()},
                                  {"capabilityRef", capability_ref}});
  }

  /// Ask the owner of a remote space for scoped access (consumer side).
  /// NOTE: the rights argument is named ``rights`` (not ``requestedRights``).
  json request_access(const std::string& space_id,
                      const std::vector<std::string>& rights,
                      const std::string& reason = "",
                      std::optional<std::string> persistence_mode = std::nullopt) {
    json args = {{"sessionId", require_session()},
                 {"space", space_id},
                 {"rights", rights}};
    if (persistence_mode) args["persistenceMode"] = *persistence_mode;
    if (!reason.empty()) args["reason"] = reason;
    return call("noetic.request_access", args);
  }

  /// List pending access requests on spaces you own (owner side).
  std::vector<json> list_requests() {
    json data = call("noetic.list_requests", {{"sessionId", require_session()}});
    return json_array_to_vec(data, "requests");
  }

  /// Approve a pending access request, minting the grant (owner side).
  GrantResult approve_request(
      const std::string& request_id,
      std::optional<std::vector<std::string>> rights = std::nullopt,
      std::optional<std::string> world_mutation = std::nullopt,
      std::optional<std::string> persistence_mode = std::nullopt) {
    json args = {{"sessionId", require_session()}, {"requestId", request_id}};
    if (rights) args["rights"] = *rights;
    if (world_mutation) args["worldMutation"] = *world_mutation;
    if (persistence_mode) args["persistenceMode"] = *persistence_mode;
    return grant_result(call("noetic.approve_request", args));
  }

  /// Deny a pending access request (owner side).
  json deny_request(const std::string& request_id) {
    return call("noetic.deny_request",
                {{"sessionId", require_session()}, {"requestId", request_id}});
  }

  // -- discovery + introspection ---------------------------------------- //

  /// List publicly discoverable spaces (no session required).
  std::vector<json> discover(const std::string& query = "", long limit = 0) {
    json args = json::object();
    if (!query.empty()) args["query"] = query;
    if (limit) args["limit"] = limit;
    json data = call("noetic.discover", args);
    return json_array_to_vec(data, "spaces");
  }

  /// Set a space's discovery visibility.
  json publish(const std::string& space_id,
               const std::string& visibility = "public") {
    return call("noetic.publish", {{"sessionId", require_session()},
                                   {"space", space_id},
                                   {"visibility", visibility}});
  }

  /// Return scope/account/space usage metrics for the session.
  json metrics() {
    return call("noetic.metrics", {{"sessionId", require_session()}});
  }

 private:
  static size_t write_cb(char* ptr, size_t size, size_t nmemb, void* userdata) {
    const size_t bytes = size * nmemb;
    static_cast<std::string*>(userdata)->append(ptr, bytes);
    return bytes;
  }

  static std::string truncate(const std::string& s, size_t n) {
    return s.size() <= n ? s : s.substr(0, n);
  }

  static std::vector<std::string> str_list(const json& data, const char* key) {
    std::vector<std::string> out;
    if (data.contains(key) && data[key].is_array()) {
      for (const auto& v : data[key])
        if (v.is_string()) out.push_back(v.get<std::string>());
    }
    return out;
  }

  static std::vector<json> json_array_to_vec(const json& data, const char* key) {
    std::vector<json> out;
    if (data.contains(key) && data[key].is_array())
      for (const auto& v : data[key]) out.push_back(v);
    return out;
  }

  static json normalize_object(const StoreObject& obj) {
    if (obj.content.empty())
      throw std::invalid_argument("each stored object needs a 'content' field");
    bool valid = false;
    for (const char* k : kStoreKinds)
      if (obj.type == k) valid = true;
    if (!valid) {
      throw std::invalid_argument(
          "invalid object type '" + obj.type +
          "'; must be declaration, observation, or measurement");
    }
    json out = {{"content", obj.content}, {"type", obj.type}};
    if (!obj.provenance.empty()) out["provenance"] = obj.provenance;
    return out;
  }

  static json unwrap(const json& result, const std::string& method) {
    if (!result.contains("content") || !result["content"].is_array() ||
        result["content"].empty()) {
      throw ACNTransportError("response for " + method + " had no content block",
                              method);
    }
    const json& first = result["content"][0];
    if (!first.is_object() || !first.contains("text") ||
        !first["text"].is_string()) {
      throw ACNTransportError("response for " + method + " had no text payload",
                              method);
    }
    const std::string text = first["text"].get<std::string>();
    json envelope;
    try {
      envelope = json::parse(text);
    } catch (const json::exception&) {
      throw ACNTransportError(
          "could not decode envelope for " + method + ": " + truncate(text, 300),
          method);
    }
    if (!envelope.is_object()) {
      throw ACNTransportError("envelope for " + method + " was not an object",
                              method);
    }
    return envelope;
  }

  static GrantResult grant_result(const json& data) {
    return GrantResult{data.value("capabilityRef", std::string()),
                       data.value("subject", std::string()),
                       data.value("resource", std::string()),
                       str_list(data, "effectiveRights"), data};
  }

  std::string require_session() {
    if (session_id_.empty())
      throw ACNTransportError("no active session: call connect() first");
    return session_id_;
  }

  std::string endpoint_;
  std::string token_;
  std::string session_id_;
  long timeout_seconds_;

  CURL* curl_ = nullptr;
  curl_slist* headers_ = nullptr;
  std::mutex mutex_;
  std::atomic<long long> next_id_{1};
};

}  // namespace priostack

#endif  // PRIOSTACK_PRIOSTACK_HPP
