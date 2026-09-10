using System.Text.Json;

namespace Priostack.Acn;

/// <summary>
/// Base class for every error raised by <see cref="AcnClient"/>. Catch this to
/// handle any client-originated failure — transport or tool — uniformly.
/// </summary>
public class AcnException : Exception
{
    /// <summary>Creates an ACN error.</summary>
    /// <param name="message">Human-readable description.</param>
    /// <param name="method">The tool name (<c>noetic.*</c>) the failing call targeted, if known.</param>
    /// <param name="innerException">The underlying exception, if any.</param>
    public AcnException(string message, string? method = null, Exception? innerException = null)
        : base(message, innerException)
    {
        Method = method;
    }

    /// <summary>The tool name (<c>noetic.*</c>) the failing call targeted, if known.</summary>
    public string? Method { get; }
}

/// <summary>
/// A network, HTTP, decoding, or JSON-RPC protocol failure — raised before a
/// valid tool envelope could be obtained. Covers connection errors, timeouts,
/// non-2xx HTTP responses, non-JSON bodies, envelopes missing the
/// <c>content[0].text</c> payload, and JSON-RPC <c>error</c> objects.
/// </summary>
public sealed class AcnTransportException : AcnException
{
    /// <summary>Creates a transport error.</summary>
    public AcnTransportException(
        string message,
        string? method = null,
        int? code = null,
        int? httpStatus = null,
        Exception? innerException = null)
        : base(message, method, innerException)
    {
        Code = code;
        HttpStatus = httpStatus;
    }

    /// <summary>JSON-RPC error code, when the failure was a JSON-RPC <c>error</c> object.</summary>
    public int? Code { get; }

    /// <summary>HTTP status code, when the failure was an HTTP error status.</summary>
    public int? HttpStatus { get; }
}

/// <summary>
/// A tool declined the call: the envelope came back with <c>ok: false</c>.
/// Carries the server <c>outcome</c> string and human-readable <c>detail</c>.
/// Prefer catching a specific subclass; catch this base only when any
/// tool-level failure should be handled the same way.
/// </summary>
public class AcnToolException : AcnException
{
    /// <summary>Creates a tool error for an arbitrary (possibly unknown) outcome.</summary>
    public AcnToolException(
        string outcome,
        string detail,
        string? method = null,
        JsonElement? data = null)
        : base(BuildMessage(detail, outcome), method)
    {
        Outcome = outcome;
        Detail = detail;
        Data = data;
    }

    /// <summary>The server outcome string, e.g. <c>"capability-denied"</c>.</summary>
    public string Outcome { get; }

    /// <summary>The server's <c>detail</c> message, if any.</summary>
    public string Detail { get; }

    /// <summary>
    /// Any partial <c>data</c> the server attached to the failure (for example,
    /// the objects that were stored before a capacity fault). Detached from the
    /// response document, so it stays valid for the lifetime of the exception.
    /// </summary>
    public JsonElement? Data { get; }

    private static string BuildMessage(string detail, string outcome)
    {
        if (!string.IsNullOrEmpty(detail)) return detail;
        if (!string.IsNullOrEmpty(outcome)) return outcome;
        return "ACN tool error";
    }

    /// <summary>
    /// Builds the most specific <see cref="AcnToolException"/> subclass for a
    /// server <c>outcome</c>. Unknown outcomes fall back to this base type so a
    /// new server outcome degrades gracefully instead of being mis-mapped.
    /// </summary>
    public static AcnToolException ForOutcome(
        string outcome,
        string detail,
        string? method = null,
        JsonElement? data = null)
        => outcome switch
        {
            AcnNotFoundException.OutcomeCode => new AcnNotFoundException(detail, method, data),
            AcnInvalidQueryException.OutcomeCode => new AcnInvalidQueryException(detail, method, data),
            AcnCapabilityDeniedException.OutcomeCode => new AcnCapabilityDeniedException(detail, method, data),
            AcnPolicyDeniedException.OutcomeCode => new AcnPolicyDeniedException(detail, method, data),
            AcnRequiresGovernanceException.OutcomeCode => new AcnRequiresGovernanceException(detail, method, data),
            AcnStaleBaseException.OutcomeCode => new AcnStaleBaseException(detail, method, data),
            AcnIntegrityFaultException.OutcomeCode => new AcnIntegrityFaultException(detail, method, data),
            AcnConflictException.OutcomeCode => new AcnConflictException(detail, method, data),
            AcnCapacityExhaustedException.OutcomeCode => new AcnCapacityExhaustedException(detail, method, data),
            AcnNotSupportedException.OutcomeCode => new AcnNotSupportedException(detail, method, data),
            _ => new AcnToolException(outcome, detail, method, data),
        };
}

/// <summary><c>not-found</c> — no such session, space, or entity.</summary>
public sealed class AcnNotFoundException : AcnToolException
{
    public const string OutcomeCode = "not-found";

    public AcnNotFoundException(string detail, string? method = null, JsonElement? data = null)
        : base(OutcomeCode, detail, method, data) { }
}

/// <summary><c>invalid-query</c> — malformed arguments or an unknown enum value.</summary>
public sealed class AcnInvalidQueryException : AcnToolException
{
    public const string OutcomeCode = "invalid-query";

    public AcnInvalidQueryException(string detail, string? method = null, JsonElement? data = null)
        : base(OutcomeCode, detail, method, data) { }
}

/// <summary><c>capability-denied</c> — missing capability, or an invalid/revoked token.</summary>
public sealed class AcnCapabilityDeniedException : AcnToolException
{
    public const string OutcomeCode = "capability-denied";

    public AcnCapabilityDeniedException(string detail, string? method = null, JsonElement? data = null)
        : base(OutcomeCode, detail, method, data) { }
}

/// <summary><c>policy-denied</c> — a governance policy refused the operation.</summary>
public sealed class AcnPolicyDeniedException : AcnToolException
{
    public const string OutcomeCode = "policy-denied";

    public AcnPolicyDeniedException(string detail, string? method = null, JsonElement? data = null)
        : base(OutcomeCode, detail, method, data) { }
}

/// <summary><c>requires-governance</c> — the change needs an explicit confirm step.</summary>
public sealed class AcnRequiresGovernanceException : AcnToolException
{
    public const string OutcomeCode = "requires-governance";

    public AcnRequiresGovernanceException(string detail, string? method = null, JsonElement? data = null)
        : base(OutcomeCode, detail, method, data) { }
}

/// <summary><c>stale-base</c> — the operation raced a newer state; re-read and retry.</summary>
public sealed class AcnStaleBaseException : AcnToolException
{
    public const string OutcomeCode = "stale-base";

    public AcnStaleBaseException(string detail, string? method = null, JsonElement? data = null)
        : base(OutcomeCode, detail, method, data) { }
}

/// <summary><c>integrity-fault</c> — an internal consistency check failed.</summary>
public sealed class AcnIntegrityFaultException : AcnToolException
{
    public const string OutcomeCode = "integrity-fault";

    public AcnIntegrityFaultException(string detail, string? method = null, JsonElement? data = null)
        : base(OutcomeCode, detail, method, data) { }
}

/// <summary><c>conflict</c> — the write conflicts with existing state.</summary>
public sealed class AcnConflictException : AcnToolException
{
    public const string OutcomeCode = "conflict";

    public AcnConflictException(string detail, string? method = null, JsonElement? data = null)
        : base(OutcomeCode, detail, method, data) { }
}

/// <summary><c>capacity-exhausted</c> — a tier/registration/store ceiling was hit.</summary>
public sealed class AcnCapacityExhaustedException : AcnToolException
{
    public const string OutcomeCode = "capacity-exhausted";

    public AcnCapacityExhaustedException(string detail, string? method = null, JsonElement? data = null)
        : base(OutcomeCode, detail, method, data) { }
}

/// <summary>
/// <c>not-implemented</c> — the tool is unavailable on this ACN deployment.
/// Most commonly: calling <see cref="AcnClient.RegisterAsync"/> against a
/// single-tenant/offline ACN that does not offer self-registration.
/// </summary>
public sealed class AcnNotSupportedException : AcnToolException
{
    public const string OutcomeCode = "not-implemented";

    public AcnNotSupportedException(string detail, string? method = null, JsonElement? data = null)
        : base(OutcomeCode, detail, method, data) { }
}
