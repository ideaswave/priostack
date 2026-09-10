package com.priostack.acn;

import com.fasterxml.jackson.databind.JsonNode;

/**
 * A tool declined the call: the envelope came back with {@code ok: false}.
 *
 * <p>Carries the server {@code outcome} string and human-readable {@code
 * detail}. Prefer catching a specific subclass (e.g.
 * {@link CapabilityDeniedError}) so callers handle exactly the outcome they
 * expect; catch this base only when any tool-level failure is handled the same
 * way.
 */
public class ACNToolError extends ACNError {

    private static final long serialVersionUID = 1L;

    private final String outcome;
    private final String detail;
    private final transient JsonNode data;

    public ACNToolError(String outcome, String detail, String method, JsonNode data) {
        super(pickMessage(outcome, detail), method);
        this.outcome = outcome == null ? "" : outcome;
        this.detail = detail == null ? "" : detail;
        this.data = data;
    }

    private static String pickMessage(String outcome, String detail) {
        if (detail != null && !detail.isEmpty()) {
            return detail;
        }
        if (outcome != null && !outcome.isEmpty()) {
            return outcome;
        }
        return "ACN tool error";
    }

    /** The server outcome string (e.g. {@code "capability-denied"}). */
    public String outcome() {
        return outcome;
    }

    /** The server's {@code detail} message, if any (may be empty). */
    public String detail() {
        return detail;
    }

    /**
     * Any partial {@code data} the server attached to the failure (e.g. the
     * objects stored before a capacity fault), or {@code null}.
     */
    public JsonNode data() {
        return data;
    }

    /**
     * Build the most specific {@link ACNToolError} subclass for a server
     * {@code outcome}. Unknown outcomes fall back to the base {@code
     * ACNToolError} so a new server outcome degrades gracefully.
     */
    public static ACNToolError forOutcome(
            String outcome, String detail, String method, JsonNode data) {
        String o = outcome == null ? "" : outcome;
        switch (o) {
            case "not-found":
                return new NotFoundError(o, detail, method, data);
            case "invalid-query":
                return new InvalidQueryError(o, detail, method, data);
            case "capability-denied":
                return new CapabilityDeniedError(o, detail, method, data);
            case "policy-denied":
                return new PolicyDeniedError(o, detail, method, data);
            case "requires-governance":
                return new RequiresGovernanceError(o, detail, method, data);
            case "stale-base":
                return new StaleBaseError(o, detail, method, data);
            case "integrity-fault":
                return new IntegrityFaultError(o, detail, method, data);
            case "conflict":
                return new ConflictError(o, detail, method, data);
            case "capacity-exhausted":
                return new CapacityExhaustedError(o, detail, method, data);
            case "not-implemented":
                return new NotSupportedError(o, detail, method, data);
            default:
                return new ACNToolError(o, detail, method, data);
        }
    }
}
