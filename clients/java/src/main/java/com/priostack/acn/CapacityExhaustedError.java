package com.priostack.acn;

import com.fasterxml.jackson.databind.JsonNode;

/** {@code capacity-exhausted} — a tier/registration/store ceiling was hit. */
public class CapacityExhaustedError extends ACNToolError {

    private static final long serialVersionUID = 1L;

    public CapacityExhaustedError(String outcome, String detail, String method, JsonNode data) {
        super(outcome, detail, method, data);
    }
}
