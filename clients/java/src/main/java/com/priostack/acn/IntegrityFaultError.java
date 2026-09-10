package com.priostack.acn;

import com.fasterxml.jackson.databind.JsonNode;

/** {@code integrity-fault} — an internal consistency check failed. */
public class IntegrityFaultError extends ACNToolError {

    private static final long serialVersionUID = 1L;

    public IntegrityFaultError(String outcome, String detail, String method, JsonNode data) {
        super(outcome, detail, method, data);
    }
}
