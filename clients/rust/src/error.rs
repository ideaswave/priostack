//! Error types for the Priostack ACN client.
//!
//! The ACN reports two very different kinds of failure and this client models
//! each with a distinct [`Error`] variant:
//!
//! * [`Error::Transport`] — the request never produced a valid tool envelope:
//!   a network error, a non-2xx HTTP status, a non-JSON body, a malformed
//!   envelope, or a JSON-RPC `error` object (unknown method, bad params).
//! * [`Error::Tool`] — the call reached the tool but the tool declined it: the
//!   envelope came back with `ok: false` and an [`Outcome`] such as
//!   [`Outcome::CapabilityDenied`] or [`Outcome::NotFound`].
//!
//! A third variant, [`Error::Usage`], covers client-side precondition failures
//! (no active session, missing token) that never leave the process.
//!
//! Callers match on the outcome to handle exactly the failure they expect:
//!
//! ```no_run
//! use priostack_acn::{Client, Error, Object, Outcome};
//!
//! # fn demo(acn: &Client, space_id: &str) {
//! match acn.store(space_id, &[Object::declaration("hi")]) {
//!     Ok(_) => {}
//!     Err(Error::Tool { outcome: Outcome::CapabilityDenied, .. }) => {
//!         // the session lacks the write right / mutate capability
//!     }
//!     Err(e) => eprintln!("store failed: {e}"),
//! }
//! # }
//! ```

use std::fmt;

use serde_json::Value;

/// Convenience alias: every fallible client call returns this.
pub type Result<T> = std::result::Result<T, Error>;

/// The server `outcome` string carried by a tool-level failure.
///
/// Known outcomes map to their own variant; any outcome this client version
/// does not recognize degrades gracefully into [`Outcome::Unknown`] instead of
/// being mis-mapped.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Outcome {
    /// `not-found` — no such session, space, or entity.
    NotFound,
    /// `invalid-query` — malformed arguments or an unknown enum value.
    InvalidQuery,
    /// `capability-denied` — missing capability, or an invalid/revoked token.
    CapabilityDenied,
    /// `policy-denied` — a governance policy refused the operation.
    PolicyDenied,
    /// `requires-governance` — the change needs an explicit confirm step.
    RequiresGovernance,
    /// `stale-base` — the operation raced a newer state; re-read and retry.
    StaleBase,
    /// `integrity-fault` — an internal consistency check failed.
    IntegrityFault,
    /// `conflict` — the write conflicts with existing state.
    Conflict,
    /// `capacity-exhausted` — a tier/registration/store ceiling was hit.
    CapacityExhausted,
    /// `not-implemented` — the tool is unavailable on this ACN deployment.
    NotImplemented,
    /// An outcome string not recognized by this client version.
    Unknown(String),
}

impl Outcome {
    /// The wire string for this outcome.
    pub fn as_str(&self) -> &str {
        match self {
            Outcome::NotFound => "not-found",
            Outcome::InvalidQuery => "invalid-query",
            Outcome::CapabilityDenied => "capability-denied",
            Outcome::PolicyDenied => "policy-denied",
            Outcome::RequiresGovernance => "requires-governance",
            Outcome::StaleBase => "stale-base",
            Outcome::IntegrityFault => "integrity-fault",
            Outcome::Conflict => "conflict",
            Outcome::CapacityExhausted => "capacity-exhausted",
            Outcome::NotImplemented => "not-implemented",
            Outcome::Unknown(s) => s.as_str(),
        }
    }

    /// Parse a server outcome string into an [`Outcome`].
    pub(crate) fn from_wire(s: &str) -> Outcome {
        match s {
            "not-found" => Outcome::NotFound,
            "invalid-query" => Outcome::InvalidQuery,
            "capability-denied" => Outcome::CapabilityDenied,
            "policy-denied" => Outcome::PolicyDenied,
            "requires-governance" => Outcome::RequiresGovernance,
            "stale-base" => Outcome::StaleBase,
            "integrity-fault" => Outcome::IntegrityFault,
            "conflict" => Outcome::Conflict,
            "capacity-exhausted" => Outcome::CapacityExhausted,
            "not-implemented" => Outcome::NotImplemented,
            other => Outcome::Unknown(other.to_string()),
        }
    }
}

impl fmt::Display for Outcome {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

/// Every error [`Client`](crate::Client) can raise.
#[derive(Debug)]
pub enum Error {
    /// A network, HTTP, decoding, or JSON-RPC protocol failure — raised before
    /// a valid tool envelope could be obtained.
    Transport {
        /// Human-readable description of the failure.
        message: String,
        /// The tool name (`noetic.*`) the failing call targeted, if known.
        method: Option<String>,
        /// JSON-RPC error code, when the failure was a JSON-RPC `error` object.
        code: Option<i64>,
        /// HTTP status code, when the failure was a non-2xx HTTP response.
        http_status: Option<u16>,
    },
    /// A tool declined the call: the envelope returned `ok: false`.
    Tool {
        /// The server `outcome`.
        outcome: Outcome,
        /// The server's human-readable `detail` message (may be empty).
        detail: String,
        /// The tool name (`noetic.*`) the failing call targeted, if known.
        method: Option<String>,
        /// Any partial `data` the server attached to the failure.
        data: Option<Value>,
    },
    /// A client-side precondition failed (e.g. no active session, missing
    /// token). The request never left the process.
    Usage(String),
}

impl Error {
    pub(crate) fn transport(message: String, method: &str) -> Error {
        Error::Transport {
            message,
            method: Some(method.to_string()),
            code: None,
            http_status: None,
        }
    }

    pub(crate) fn transport_http(message: String, method: &str, http_status: u16) -> Error {
        Error::Transport {
            message,
            method: Some(method.to_string()),
            code: None,
            http_status: Some(http_status),
        }
    }

    pub(crate) fn transport_jsonrpc(message: String, method: &str, code: Option<i64>) -> Error {
        Error::Transport {
            message,
            method: Some(method.to_string()),
            code,
            http_status: None,
        }
    }

    pub(crate) fn tool(outcome: &str, detail: String, method: &str, data: Option<Value>) -> Error {
        Error::Tool {
            outcome: Outcome::from_wire(outcome),
            detail,
            method: Some(method.to_string()),
            data,
        }
    }

    pub(crate) fn usage(message: impl Into<String>) -> Error {
        Error::Usage(message.into())
    }

    /// Whether this is a transport/protocol failure.
    pub fn is_transport(&self) -> bool {
        matches!(self, Error::Transport { .. })
    }

    /// Whether this is a tool-level (`ok: false`) failure.
    pub fn is_tool(&self) -> bool {
        matches!(self, Error::Tool { .. })
    }

    /// The tool outcome, when this is an [`Error::Tool`].
    pub fn outcome(&self) -> Option<&Outcome> {
        match self {
            Error::Tool { outcome, .. } => Some(outcome),
            _ => None,
        }
    }

    /// The failing tool name (`noetic.*`), when known.
    pub fn method(&self) -> Option<&str> {
        match self {
            Error::Transport { method, .. } | Error::Tool { method, .. } => method.as_deref(),
            Error::Usage(_) => None,
        }
    }

    /// The server `detail` message, when this is an [`Error::Tool`].
    pub fn detail(&self) -> Option<&str> {
        match self {
            Error::Tool { detail, .. } => Some(detail),
            _ => None,
        }
    }
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Error::Transport { message, .. } => f.write_str(message),
            Error::Tool {
                outcome,
                detail,
                method,
                ..
            } => {
                let m = method.as_deref().unwrap_or("acn");
                if detail.is_empty() {
                    write!(f, "{m}: {outcome}")
                } else {
                    write!(f, "{m}: {outcome} ({detail})")
                }
            }
            Error::Usage(message) => f.write_str(message),
        }
    }
}

impl std::error::Error for Error {}
