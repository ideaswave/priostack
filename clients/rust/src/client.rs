//! The JSON-RPC client and its builder.

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Mutex;
use std::thread;
use std::time::Duration;

use serde_json::{json, Map, Value};

use crate::error::{Error, Result};
use crate::types::{
    ConnectResult, FetchResult, GrantResult, Object, RegisterResult, SpaceResult, StoreResult,
};
use crate::{DEFAULT_ENDPOINT, DEFAULT_GRANT_RIGHTS};

const DEFAULT_TIMEOUT: Duration = Duration::from_secs(30);
const DEFAULT_MAX_RETRIES: u32 = 3;
const DEFAULT_BACKOFF_FACTOR: f64 = 0.5;
const DEFAULT_MAX_TOKENS: i64 = 4096;
const USER_AGENT: &str = concat!("priostack-acn-rust/", env!("CARGO_PKG_VERSION"));

/// Builder for a [`Client`].
///
/// ```no_run
/// use std::time::Duration;
/// use priostack_acn::Client;
///
/// let acn = Client::builder()
///     .timeout(Duration::from_secs(20))
///     .token("an-existing-token")
///     .build()?;
/// # Ok::<(), priostack_acn::Error>(())
/// ```
pub struct ClientBuilder {
    endpoint: String,
    timeout: Duration,
    token: Option<String>,
    user_agent: String,
    max_retries: u32,
    backoff_factor: f64,
}

impl Default for ClientBuilder {
    fn default() -> Self {
        ClientBuilder {
            endpoint: DEFAULT_ENDPOINT.to_string(),
            timeout: DEFAULT_TIMEOUT,
            token: None,
            user_agent: USER_AGENT.to_string(),
            max_retries: DEFAULT_MAX_RETRIES,
            backoff_factor: DEFAULT_BACKOFF_FACTOR,
        }
    }
}

impl ClientBuilder {
    /// Override the RPC endpoint (default [`DEFAULT_ENDPOINT`]).
    pub fn endpoint(mut self, endpoint: impl Into<String>) -> Self {
        self.endpoint = endpoint.into();
        self
    }

    /// Per-request timeout applied to every call (default 30s).
    pub fn timeout(mut self, timeout: Duration) -> Self {
        self.timeout = timeout;
        self
    }

    /// Seed a previously issued bearer token so [`Client::connect`] can be
    /// called without registering again.
    pub fn token(mut self, token: impl Into<String>) -> Self {
        self.token = Some(token.into());
        self
    }

    /// Override the `User-Agent` header.
    pub fn user_agent(mut self, user_agent: impl Into<String>) -> Self {
        self.user_agent = user_agent.into();
        self
    }

    /// How many times to retry *transport* faults (default 3). Only failures to
    /// establish the connection and back-pressure statuses (429/503) are
    /// retried; read timeouts are never retried, so a non-idempotent call such
    /// as `store` is never silently duplicated.
    pub fn max_retries(mut self, max_retries: u32) -> Self {
        self.max_retries = max_retries;
        self
    }

    /// Exponential backoff base, in seconds, between retries (default 0.5).
    pub fn backoff_factor(mut self, backoff_factor: f64) -> Self {
        self.backoff_factor = backoff_factor;
        self
    }

    /// Build the client, constructing the pooled HTTP client.
    pub fn build(self) -> Result<Client> {
        let mut headers = reqwest::header::HeaderMap::new();
        // Ask for a plain JSON reply; the Streamable-HTTP endpoint would
        // otherwise be free to answer a POST as a one-shot SSE frame.
        headers.insert(
            reqwest::header::ACCEPT,
            reqwest::header::HeaderValue::from_static("application/json"),
        );
        let http = reqwest::blocking::Client::builder()
            .timeout(self.timeout)
            .user_agent(self.user_agent)
            .default_headers(headers)
            .build()
            .map_err(|e| Error::usage(format!("failed to build HTTP client: {e}")))?;

        Ok(Client {
            endpoint: self.endpoint,
            http,
            token: Mutex::new(self.token),
            session_id: Mutex::new(None),
            next_id: AtomicU64::new(1),
            max_retries: self.max_retries,
            backoff_factor: self.backoff_factor,
        })
    }
}

/// A sturdy JSON-RPC client for the Priostack ACN.
///
/// One instance reuses a single pooled HTTPS connection and captures the bearer
/// token on [`register`](Client::register) and the session id on
/// [`connect`](Client::connect) automatically. It is `Send + Sync`, so it can
/// be wrapped in an `Arc` and shared across threads; the JSON-RPC id counter
/// and the captured token/session are guarded internally.
pub struct Client {
    endpoint: String,
    http: reqwest::blocking::Client,
    token: Mutex<Option<String>>,
    session_id: Mutex<Option<String>>,
    next_id: AtomicU64,
    max_retries: u32,
    backoff_factor: f64,
}

impl Client {
    /// A client pointed at [`DEFAULT_ENDPOINT`] with default settings.
    pub fn new() -> Result<Client> {
        ClientBuilder::default().build()
    }

    /// Start a [`ClientBuilder`].
    pub fn builder() -> ClientBuilder {
        ClientBuilder::default()
    }

    /// The RPC endpoint this client targets.
    pub fn endpoint(&self) -> &str {
        &self.endpoint
    }

    /// The captured bearer token, if any.
    pub fn token(&self) -> Option<String> {
        self.token.lock().unwrap().clone()
    }

    /// Seed or replace the bearer token used by [`connect`](Client::connect).
    pub fn set_token(&self, token: impl Into<String>) {
        *self.token.lock().unwrap() = Some(token.into());
    }

    /// The captured session id, if a session is open.
    pub fn session_id(&self) -> Option<String> {
        self.session_id.lock().unwrap().clone()
    }

    /// Whether a session id has been captured.
    pub fn is_connected(&self) -> bool {
        self.session_id.lock().unwrap().is_some()
    }

    // -- transport --------------------------------------------------------- //

    /// Invoke any `noetic.*` tool and return its unwrapped `data` value.
    ///
    /// This is the low-level escape hatch behind every typed method — use it to
    /// reach tools this client does not wrap explicitly. It performs the full
    /// round trip: builds the JSON-RPC `tools/call` envelope, unwraps
    /// `result.content[0].text`, and returns [`Error::Tool`] when the tool
    /// returns `ok: false`. `data` is optional; a tool that returns `ok` with
    /// no payload yields [`Value::Null`].
    pub fn call(&self, method: &str, arguments: Value) -> Result<Value> {
        let id = self.next_id.fetch_add(1, Ordering::Relaxed);
        let payload = json!({
            "jsonrpc": "2.0",
            "id": id,
            "method": "tools/call",
            "params": { "name": method, "arguments": arguments },
        });

        let resp = self.post_with_retries(method, &payload)?;

        let status = resp.status().as_u16();
        if status >= 400 {
            let body = resp.text().unwrap_or_default();
            return Err(Error::transport_http(
                format!("HTTP {status} calling {method}: {}", truncate(&body, 500)),
                method,
                status,
            ));
        }

        let text = resp.text().map_err(|e| {
            Error::transport(format!("could not read response body calling {method}: {e}"), method)
        })?;

        let body: Value = serde_json::from_str(&text).map_err(|_| {
            Error::transport(
                format!("non-JSON response calling {method}: {}", truncate(&text, 500)),
                method,
            )
        })?;

        // JSON-RPC protocol error (unknown method, bad params) — no result.
        if let Some(err) = body.get("error").filter(|e| !e.is_null()) {
            let message = err
                .get("message")
                .and_then(|m| m.as_str())
                .map(str::to_string)
                .unwrap_or_else(|| err.to_string());
            let code = err.get("code").and_then(|c| c.as_i64());
            return Err(Error::transport_jsonrpc(
                format!("JSON-RPC error calling {method}: {message}"),
                method,
                code,
            ));
        }

        let result = body.get("result").and_then(|r| r.as_object()).ok_or_else(|| {
            Error::transport(
                format!("malformed response calling {method}: {}", truncate(&text, 500)),
                method,
            )
        })?;

        let envelope = unwrap_envelope(result, method)?;

        let ok = envelope.get("ok").and_then(|v| v.as_bool()).unwrap_or(false);
        if !ok {
            let outcome = envelope.get("outcome").and_then(|v| v.as_str()).unwrap_or("");
            let detail = envelope
                .get("detail")
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string();
            let data = envelope.get("data").cloned();
            return Err(Error::tool(outcome, detail, method, data));
        }

        // ``data`` is optional (some tools return ok with no payload).
        Ok(envelope.get("data").cloned().unwrap_or(Value::Null))
    }

    fn post_with_retries(
        &self,
        method: &str,
        payload: &Value,
    ) -> Result<reqwest::blocking::Response> {
        let mut attempt: u32 = 0;
        loop {
            match self.http.post(self.endpoint.as_str()).json(payload).send() {
                Ok(resp) => {
                    let status = resp.status().as_u16();
                    if (status == 429 || status == 503) && attempt < self.max_retries {
                        let wait = retry_after(&resp).unwrap_or_else(|| self.backoff(attempt));
                        attempt += 1;
                        thread::sleep(wait);
                        continue;
                    }
                    return Ok(resp);
                }
                Err(err) => {
                    // Retry ONLY when the connection was never established, so a
                    // request the server may already have applied is not resent.
                    if err.is_connect() && attempt < self.max_retries {
                        thread::sleep(self.backoff(attempt));
                        attempt += 1;
                        continue;
                    }
                    return Err(Error::transport(
                        format!("network error calling {method}: {err}"),
                        method,
                    ));
                }
            }
        }
    }

    fn backoff(&self, attempt: u32) -> Duration {
        let secs = self.backoff_factor * 2f64.powi(attempt as i32);
        Duration::from_secs_f64(secs.clamp(0.0, 30.0))
    }

    fn require_session(&self) -> Result<String> {
        self.session_id
            .lock()
            .unwrap()
            .clone()
            .ok_or_else(|| Error::usage("no active session: call connect() first"))
    }

    // -- identity ---------------------------------------------------------- //

    /// Self-register a new agent and capture its bearer token.
    ///
    /// The token is shown once; it is stored on this client and returned so you
    /// can persist it for future sessions.
    pub fn register(&self, display_name: &str) -> Result<RegisterResult> {
        let data = self.call("noetic.register", json!({ "displayName": display_name }))?;
        let token = data
            .get("token")
            .and_then(|v| v.as_str())
            .ok_or_else(|| Error::transport("register returned no token".to_string(), "noetic.register"))?
            .to_string();
        *self.token.lock().unwrap() = Some(token.clone());
        Ok(RegisterResult {
            token,
            agent_id: str_field(&data, "agentId"),
            account_id: str_field(&data, "accountId"),
            tier: str_field(&data, "tier"),
            raw: as_object(data),
        })
    }

    /// Open a session with the captured token and default max response tokens.
    pub fn connect(&self) -> Result<ConnectResult> {
        self.connect_with(None, DEFAULT_MAX_TOKENS)
    }

    /// Open a session, optionally overriding the token and max response tokens.
    ///
    /// Pass `token = None` to use the token captured by
    /// [`register`](Client::register) or seeded on the builder. Re-call after
    /// being granted access to a space so the widened scope is applied.
    pub fn connect_with(&self, token: Option<&str>, max_tokens: i64) -> Result<ConnectResult> {
        let tok = match token {
            Some(t) => t.to_string(),
            None => self.token.lock().unwrap().clone().ok_or_else(|| {
                Error::usage("connect() needs a token: register() first or pass a token")
            })?,
        };
        let data = self.call(
            "noetic.connect",
            json!({ "token": tok, "maxResponseTokens": max_tokens }),
        )?;
        // The server serializes ConnectResult with Go field names (PascalCase).
        let session_id = data
            .get("SessionID")
            .and_then(|v| v.as_str())
            .filter(|s| !s.is_empty())
            .ok_or_else(|| {
                Error::transport(format!("connect returned no SessionID: {data}"), "noetic.connect")
            })?
            .to_string();
        *self.session_id.lock().unwrap() = Some(session_id.clone());
        *self.token.lock().unwrap() = Some(tok);
        Ok(ConnectResult {
            session_id,
            resolved_account: str_field(&data, "ResolvedAccount"),
            granted_capabilities: str_list(&data, "GrantedCapabilities"),
            granted_context_rights: str_list(&data, "GrantedContextRights"),
            bound_space: str_field(&data, "BoundSpace"),
            resolved_max_tokens: data.get("ResolvedMaxTokens").and_then(|v| v.as_i64()).unwrap_or(0),
            raw: as_object(data),
        })
    }

    /// End the current session. Durable facts are **not** revoked.
    pub fn disconnect(&self) -> Result<Value> {
        let sid = self.require_session()?;
        let data = self.call("noetic.disconnect", json!({ "sessionId": sid }))?;
        *self.session_id.lock().unwrap() = None;
        Ok(data)
    }

    /// Mint a fresh bearer token for this agent and retire the old one.
    ///
    /// Existing sessions keep working; use the new token for future
    /// `connect` calls. The new token is stored on this client and returned.
    pub fn rotate_token(&self) -> Result<String> {
        let sid = self.require_session()?;
        let data = self.call("noetic.rotate_token", json!({ "sessionId": sid }))?;
        let token = data
            .get("token")
            .and_then(|v| v.as_str())
            .ok_or_else(|| {
                Error::transport("rotate_token returned no token".to_string(), "noetic.rotate_token")
            })?
            .to_string();
        *self.token.lock().unwrap() = Some(token.clone());
        Ok(token)
    }

    /// Discover the grantable rights + world-mutation vocabulary in scope.
    pub fn capabilities(&self) -> Result<Value> {
        let sid = self.require_session()?;
        self.call("noetic.capabilities", json!({ "sessionId": sid }))
    }

    // -- spaces + facts ---------------------------------------------------- //

    /// Create an isolated context space and return its resolved id.
    ///
    /// `default_rights` is the ceiling of rights the space may offer to others;
    /// it does not grant anything by itself. Pass an empty slice to omit it.
    /// For the less common `visibility`/`persistenceMode`/`protectionLevel`
    /// options, use [`call`](Client::call) directly.
    pub fn create_space(&self, display_name: &str, default_rights: &[&str]) -> Result<SpaceResult> {
        let sid = self.require_session()?;
        let mut args = Map::new();
        args.insert("sessionId".to_string(), Value::String(sid));
        args.insert("displayName".to_string(), Value::String(display_name.to_string()));
        if !default_rights.is_empty() {
            args.insert("defaultRights".to_string(), rights_to_json(default_rights));
        }
        let data = self.call("noetic.create_space", Value::Object(args))?;
        let space_id = data
            .get("spaceId")
            .and_then(|v| v.as_str())
            .ok_or_else(|| {
                Error::transport("create_space returned no spaceId".to_string(), "noetic.create_space")
            })?
            .to_string();
        Ok(SpaceResult {
            space_id,
            account_id: str_field(&data, "accountId"),
            persistence_mode: str_field(&data, "persistenceMode"),
            protection_level: str_field(&data, "protectionLevel"),
            raw: as_object(data),
        })
    }

    /// Persist typed facts into a space.
    ///
    /// Writing needs the write right and the `mutate` capability; the space
    /// owner has both. The `space` argument carries the space id.
    pub fn store(&self, space_id: &str, objects: &[Object]) -> Result<StoreResult> {
        let sid = self.require_session()?;
        let objs: Vec<Value> = objects.iter().map(Object::to_json).collect();
        let data = self.call(
            "noetic.store",
            json!({ "sessionId": sid, "space": space_id, "objects": objs }),
        )?;
        Ok(StoreResult {
            object_refs: data
                .get("objectRefs")
                .and_then(|v| v.as_array())
                .cloned()
                .unwrap_or_default(),
            raw: as_object(data),
        })
    }

    /// Read stored objects back from a space (this is the content reader).
    ///
    /// `query` is a case-insensitive **substring** filter over content (not
    /// semantic search); pass `""` for no filter. `limit` caps the count (0 =
    /// server default). The `space` argument carries the space id.
    pub fn fetch(&self, space_id: &str, query: &str, limit: u64) -> Result<FetchResult> {
        let sid = self.require_session()?;
        let mut args = Map::new();
        args.insert("sessionId".to_string(), Value::String(sid));
        args.insert("space".to_string(), Value::String(space_id.to_string()));
        if !query.is_empty() {
            args.insert("query".to_string(), Value::String(query.to_string()));
        }
        if limit != 0 {
            args.insert("limit".to_string(), Value::from(limit));
        }
        let data = self.call("noetic.fetch", Value::Object(args))?;
        Ok(FetchResult {
            space: data
                .get("space")
                .and_then(|v| v.as_str())
                .unwrap_or(space_id)
                .to_string(),
            objects: data.get("objects").and_then(|v| v.as_array()).cloned().unwrap_or_default(),
            matched: data.get("matched").and_then(|v| v.as_i64()).unwrap_or(0),
            total: data.get("total").and_then(|v| v.as_i64()).unwrap_or(0),
            returned_tokens: data.get("returnedTokens").and_then(|v| v.as_i64()).unwrap_or(0),
            raw: as_object(data),
        })
    }

    // -- sharing ----------------------------------------------------------- //

    /// Grant another agent scoped access to a space you own.
    ///
    /// `subject_principal` is the grantee's agent id. `rights` are content
    /// rights (`read`/`write`/`quote`/`share`/`export`/...); an empty slice
    /// defaults to [`DEFAULT_GRANT_RIGHTS`]. `world_mutation` is the separate
    /// mutation ladder (`read`/`propose`/`mutate`); pass `None` and the server
    /// derives it from the rights (granting `write` confers `mutate`).
    pub fn grant_access(
        &self,
        space_id: &str,
        subject_principal: &str,
        rights: &[&str],
        world_mutation: Option<&str>,
    ) -> Result<GrantResult> {
        let sid = self.require_session()?;
        let rights_json = if rights.is_empty() {
            rights_to_json(&DEFAULT_GRANT_RIGHTS)
        } else {
            rights_to_json(rights)
        };
        let mut args = Map::new();
        args.insert("sessionId".to_string(), Value::String(sid));
        args.insert(
            "subjectPrincipal".to_string(),
            Value::String(subject_principal.to_string()),
        );
        // The server names the space argument ``resource``. ``space`` is sent
        // too as a harmless alias for older builds; unknown fields are ignored.
        args.insert("resource".to_string(), Value::String(space_id.to_string()));
        args.insert("space".to_string(), Value::String(space_id.to_string()));
        args.insert("rights".to_string(), rights_json);
        if let Some(wm) = world_mutation {
            args.insert("worldMutation".to_string(), Value::String(wm.to_string()));
        }
        let data = self.call("noetic.grant", Value::Object(args))?;
        Ok(grant_result(data))
    }

    /// Revoke a previously granted capability (immediate, forward-only).
    pub fn revoke_access(&self, capability_ref: &str) -> Result<Value> {
        let sid = self.require_session()?;
        self.call(
            "noetic.revoke",
            json!({ "sessionId": sid, "capabilityRef": capability_ref }),
        )
    }

    /// Ask the owner of a remote space for scoped access (consumer side).
    ///
    /// The rights argument is named `rights` on the wire (not
    /// `requestedRights`). Pass `""` for `reason` to omit it.
    pub fn request_access(&self, space_id: &str, rights: &[&str], reason: &str) -> Result<Value> {
        let sid = self.require_session()?;
        let mut args = Map::new();
        args.insert("sessionId".to_string(), Value::String(sid));
        args.insert("space".to_string(), Value::String(space_id.to_string()));
        args.insert("rights".to_string(), rights_to_json(rights));
        if !reason.is_empty() {
            args.insert("reason".to_string(), Value::String(reason.to_string()));
        }
        self.call("noetic.request_access", Value::Object(args))
    }

    /// List pending access requests on spaces you own (owner side).
    pub fn list_requests(&self) -> Result<Vec<Value>> {
        let sid = self.require_session()?;
        let data = self.call("noetic.list_requests", json!({ "sessionId": sid }))?;
        Ok(data.get("requests").and_then(|v| v.as_array()).cloned().unwrap_or_default())
    }

    /// Approve a pending access request, minting the grant (owner side).
    ///
    /// Pass an empty `rights` slice to accept the rights the requester asked
    /// for; `world_mutation` follows the same rule as [`grant_access`](Client::grant_access).
    pub fn approve_request(
        &self,
        request_id: &str,
        rights: &[&str],
        world_mutation: Option<&str>,
    ) -> Result<GrantResult> {
        let sid = self.require_session()?;
        let mut args = Map::new();
        args.insert("sessionId".to_string(), Value::String(sid));
        args.insert("requestId".to_string(), Value::String(request_id.to_string()));
        if !rights.is_empty() {
            args.insert("rights".to_string(), rights_to_json(rights));
        }
        if let Some(wm) = world_mutation {
            args.insert("worldMutation".to_string(), Value::String(wm.to_string()));
        }
        let data = self.call("noetic.approve_request", Value::Object(args))?;
        Ok(grant_result(data))
    }

    /// Deny a pending access request (owner side).
    pub fn deny_request(&self, request_id: &str) -> Result<Value> {
        let sid = self.require_session()?;
        self.call(
            "noetic.deny_request",
            json!({ "sessionId": sid, "requestId": request_id }),
        )
    }

    // -- discovery + introspection ---------------------------------------- //

    /// List publicly discoverable spaces (no session required).
    pub fn discover(&self, query: &str, limit: u64) -> Result<Vec<Value>> {
        let mut args = Map::new();
        if !query.is_empty() {
            args.insert("query".to_string(), Value::String(query.to_string()));
        }
        if limit != 0 {
            args.insert("limit".to_string(), Value::from(limit));
        }
        let data = self.call("noetic.discover", Value::Object(args))?;
        Ok(data.get("spaces").and_then(|v| v.as_array()).cloned().unwrap_or_default())
    }

    /// Set a space's discovery visibility.
    pub fn publish(&self, space_id: &str, visibility: &str) -> Result<Value> {
        let sid = self.require_session()?;
        self.call(
            "noetic.publish",
            json!({ "sessionId": sid, "space": space_id, "visibility": visibility }),
        )
    }

    /// Return scope/account/space usage metrics for the session.
    pub fn metrics(&self) -> Result<Value> {
        let sid = self.require_session()?;
        self.call("noetic.metrics", json!({ "sessionId": sid }))
    }
}

impl std::fmt::Debug for Client {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        // Never print the bearer token.
        f.debug_struct("Client")
            .field("endpoint", &self.endpoint)
            .field("connected", &self.is_connected())
            .field(
                "has_token",
                &self.token.lock().map(|t| t.is_some()).unwrap_or(false),
            )
            .finish()
    }
}

// --------------------------------------------------------------------------- //
// Free helpers
// --------------------------------------------------------------------------- //

/// Parse the MCP `content[0].text` JSON envelope out of a result object.
fn unwrap_envelope(result: &Map<String, Value>, method: &str) -> Result<Map<String, Value>> {
    let content = result
        .get("content")
        .and_then(|c| c.as_array())
        .filter(|a| !a.is_empty())
        .ok_or_else(|| {
            Error::transport(format!("response for {method} had no content block"), method)
        })?;
    let text = content[0]
        .get("text")
        .and_then(|t| t.as_str())
        .ok_or_else(|| {
            Error::transport(format!("response for {method} had no text payload"), method)
        })?;
    let envelope: Value = serde_json::from_str(text).map_err(|_| {
        Error::transport(
            format!("could not decode envelope for {method}: {}", truncate(text, 300)),
            method,
        )
    })?;
    match envelope {
        Value::Object(m) => Ok(m),
        _ => Err(Error::transport(
            format!("envelope for {method} was not an object"),
            method,
        )),
    }
}

fn grant_result(data: Value) -> GrantResult {
    GrantResult {
        capability_ref: str_field(&data, "capabilityRef"),
        subject: str_field(&data, "subject"),
        resource: str_field(&data, "resource"),
        effective_rights: str_list(&data, "effectiveRights"),
        raw: as_object(data),
    }
}

fn rights_to_json(rights: &[&str]) -> Value {
    Value::Array(rights.iter().map(|r| Value::String(r.to_string())).collect())
}

fn str_field(data: &Value, key: &str) -> String {
    data.get(key).and_then(|v| v.as_str()).unwrap_or("").to_string()
}

fn str_list(data: &Value, key: &str) -> Vec<String> {
    data.get(key)
        .and_then(|v| v.as_array())
        .map(|a| a.iter().filter_map(|v| v.as_str().map(str::to_string)).collect())
        .unwrap_or_default()
}

fn as_object(data: Value) -> Map<String, Value> {
    match data {
        Value::Object(m) => m,
        _ => Map::new(),
    }
}

fn truncate(s: &str, max: usize) -> &str {
    match s.char_indices().nth(max) {
        Some((idx, _)) => &s[..idx],
        None => s,
    }
}

fn retry_after(resp: &reqwest::blocking::Response) -> Option<Duration> {
    resp.headers()
        .get(reqwest::header::RETRY_AFTER)?
        .to_str()
        .ok()?
        .trim()
        .parse::<u64>()
        .ok()
        .map(Duration::from_secs)
}
