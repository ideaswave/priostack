"""Priostack Agent Context Network (ACN) — official Python SDK.

Model-agnostic, zero-setup long-term memory and multi-agent context sharing for
AI agents, over the Model Context Protocol (MCP).
"""

from .client import (
    DEFAULT_ENDPOINT,
    STORE_KINDS,
    ACNClient,
    ConnectResult,
    FetchResult,
    GrantResult,
    RegisterResult,
    SpaceResult,
    StoreResult,
)
from .exceptions import (
    ACNError,
    ACNToolError,
    ACNTransportError,
    CapabilityDeniedError,
    CapacityExhaustedError,
    ConflictError,
    IntegrityFaultError,
    InvalidQueryError,
    NotFoundError,
    NotSupportedError,
    PolicyDeniedError,
    RequiresGovernanceError,
    StaleBaseError,
)

__version__ = "0.2.0"

__all__ = [
    "ACNClient",
    "DEFAULT_ENDPOINT",
    "STORE_KINDS",
    "RegisterResult",
    "ConnectResult",
    "SpaceResult",
    "StoreResult",
    "FetchResult",
    "GrantResult",
    "ACNError",
    "ACNTransportError",
    "ACNToolError",
    "NotFoundError",
    "InvalidQueryError",
    "CapabilityDeniedError",
    "PolicyDeniedError",
    "RequiresGovernanceError",
    "StaleBaseError",
    "IntegrityFaultError",
    "ConflictError",
    "CapacityExhaustedError",
    "NotSupportedError",
    "__version__",
]
