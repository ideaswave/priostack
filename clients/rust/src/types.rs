//! Typed request/response shapes for the common ACN calls.
//!
//! The server returns plain JSON. These lightweight structs give ergonomic,
//! type-checked access to the frequently used fields while still exposing the
//! full raw `data` object via `.raw` for anything not surfaced as a field.

use serde_json::{Map, Value};

/// The `type` values the `store` tool accepts. Anything else is rejected
/// server-side with `invalid-query` (proposals/inferences go through the
/// propose/commit path, not `store`), so this client encodes the valid set in
/// the type system via [`ObjectType`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ObjectType {
    /// A stated fact or rule.
    Declaration,
    /// Something observed happening.
    Observation,
    /// A measured quantity.
    Measurement,
}

impl ObjectType {
    /// The wire string for this object type.
    pub fn as_str(&self) -> &'static str {
        match self {
            ObjectType::Declaration => "declaration",
            ObjectType::Observation => "observation",
            ObjectType::Measurement => "measurement",
        }
    }
}

/// A typed fact to persist into a space with [`Client::store`](crate::Client::store).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Object {
    /// The fact's content.
    pub content: String,
    /// The kind of fact.
    pub kind: ObjectType,
    /// Optional provenance references.
    pub provenance: Vec<String>,
}

impl Object {
    /// Build an object of an explicit [`ObjectType`].
    pub fn new(content: impl Into<String>, kind: ObjectType) -> Self {
        Object {
            content: content.into(),
            kind,
            provenance: Vec::new(),
        }
    }

    /// A [`ObjectType::Declaration`] object.
    pub fn declaration(content: impl Into<String>) -> Self {
        Object::new(content, ObjectType::Declaration)
    }

    /// An [`ObjectType::Observation`] object.
    pub fn observation(content: impl Into<String>) -> Self {
        Object::new(content, ObjectType::Observation)
    }

    /// A [`ObjectType::Measurement`] object.
    pub fn measurement(content: impl Into<String>) -> Self {
        Object::new(content, ObjectType::Measurement)
    }

    /// Attach provenance references (builder style).
    pub fn with_provenance<I, S>(mut self, provenance: I) -> Self
    where
        I: IntoIterator<Item = S>,
        S: Into<String>,
    {
        self.provenance = provenance.into_iter().map(Into::into).collect();
        self
    }

    /// Serialize to the wire shape `{content, type, provenance?}`.
    pub(crate) fn to_json(&self) -> Value {
        let mut m = Map::new();
        m.insert("content".to_string(), Value::String(self.content.clone()));
        m.insert(
            "type".to_string(),
            Value::String(self.kind.as_str().to_string()),
        );
        if !self.provenance.is_empty() {
            m.insert(
                "provenance".to_string(),
                Value::Array(
                    self.provenance
                        .iter()
                        .cloned()
                        .map(Value::String)
                        .collect(),
                ),
            );
        }
        Value::Object(m)
    }
}

/// Result of [`Client::register`](crate::Client::register).
#[derive(Debug, Clone)]
pub struct RegisterResult {
    /// The bearer token (shown once; also captured on the client).
    pub token: String,
    /// The new agent's id.
    pub agent_id: String,
    /// The account the agent belongs to.
    pub account_id: String,
    /// The account tier.
    pub tier: String,
    /// The full raw `data` object.
    pub raw: Map<String, Value>,
}

/// Result of [`Client::connect`](crate::Client::connect).
///
/// The server serializes this envelope with Go field names (**PascalCase**);
/// the fields below already carry the unwrapped values.
#[derive(Debug, Clone)]
pub struct ConnectResult {
    /// The session id (from the server's `SessionID` field).
    pub session_id: String,
    /// The resolved account (`ResolvedAccount`).
    pub resolved_account: String,
    /// Capabilities granted to the session (`GrantedCapabilities`).
    pub granted_capabilities: Vec<String>,
    /// Context rights granted to the session (`GrantedContextRights`).
    pub granted_context_rights: Vec<String>,
    /// The bound space, if any (`BoundSpace`).
    pub bound_space: String,
    /// The resolved max response tokens (`ResolvedMaxTokens`).
    pub resolved_max_tokens: i64,
    /// The full raw `data` object.
    pub raw: Map<String, Value>,
}

/// Result of [`Client::create_space`](crate::Client::create_space).
#[derive(Debug, Clone)]
pub struct SpaceResult {
    /// The resolved space id — use this for subsequent writes/reads.
    pub space_id: String,
    /// The owning account.
    pub account_id: String,
    /// The space's persistence mode.
    pub persistence_mode: String,
    /// The space's protection level.
    pub protection_level: String,
    /// The full raw `data` object.
    pub raw: Map<String, Value>,
}

/// Result of [`Client::store`](crate::Client::store).
#[derive(Debug, Clone)]
pub struct StoreResult {
    /// One reference per ingested object.
    pub object_refs: Vec<Value>,
    /// The full raw `data` object.
    pub raw: Map<String, Value>,
}

impl StoreResult {
    /// How many objects were ingested.
    pub fn count(&self) -> usize {
        self.object_refs.len()
    }
}

/// Result of [`Client::fetch`](crate::Client::fetch) — the content reader.
#[derive(Debug, Clone)]
pub struct FetchResult {
    /// The space the objects came from.
    pub space: String,
    /// The returned objects, each `{objectRef, kind, content, tokens}`.
    pub objects: Vec<Value>,
    /// How many objects matched the query.
    pub matched: i64,
    /// How many objects the space holds in total.
    pub total: i64,
    /// The token cost of the returned payload.
    pub returned_tokens: i64,
    /// The full raw `data` object.
    pub raw: Map<String, Value>,
}

impl FetchResult {
    /// Just the `content` strings of the returned objects.
    pub fn contents(&self) -> Vec<String> {
        self.objects
            .iter()
            .map(|o| {
                o.get("content")
                    .and_then(|v| v.as_str())
                    .unwrap_or("")
                    .to_string()
            })
            .collect()
    }
}

/// Result of [`Client::grant_access`](crate::Client::grant_access) /
/// [`Client::approve_request`](crate::Client::approve_request).
#[derive(Debug, Clone)]
pub struct GrantResult {
    /// The capability reference (pass to `revoke_access` to revoke it).
    pub capability_ref: String,
    /// The grantee principal.
    pub subject: String,
    /// The resource (space) the grant is scoped to.
    pub resource: String,
    /// The rights actually conferred.
    pub effective_rights: Vec<String>,
    /// The full raw `data` object.
    pub raw: Map<String, Value>,
}
