package com.priostack.acn;

import com.fasterxml.jackson.databind.JsonNode;

/** {@code invalid-query} — malformed arguments or an unknown enum value. */
public class InvalidQueryError extends ACNToolError {

    private static final long serialVersionUID = 1L;

    public InvalidQueryError(String outcome, String detail, String method, JsonNode data) {
        super(outcome, detail, method, data);
    }
}
