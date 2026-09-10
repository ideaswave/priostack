package com.priostack.acn;

import com.fasterxml.jackson.databind.JsonNode;

/** {@code stale-base} — the operation raced a newer state; re-read and retry. */
public class StaleBaseError extends ACNToolError {

    private static final long serialVersionUID = 1L;

    public StaleBaseError(String outcome, String detail, String method, JsonNode data) {
        super(outcome, detail, method, data);
    }
}
