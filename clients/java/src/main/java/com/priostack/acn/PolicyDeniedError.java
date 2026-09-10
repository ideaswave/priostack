package com.priostack.acn;

import com.fasterxml.jackson.databind.JsonNode;

/** {@code policy-denied} — a governance policy refused the operation. */
public class PolicyDeniedError extends ACNToolError {

    private static final long serialVersionUID = 1L;

    public PolicyDeniedError(String outcome, String detail, String method, JsonNode data) {
        super(outcome, detail, method, data);
    }
}
