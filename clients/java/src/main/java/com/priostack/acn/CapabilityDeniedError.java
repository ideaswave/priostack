package com.priostack.acn;

import com.fasterxml.jackson.databind.JsonNode;

/** {@code capability-denied} — missing capability, or an invalid/revoked token. */
public class CapabilityDeniedError extends ACNToolError {

    private static final long serialVersionUID = 1L;

    public CapabilityDeniedError(String outcome, String detail, String method, JsonNode data) {
        super(outcome, detail, method, data);
    }
}
