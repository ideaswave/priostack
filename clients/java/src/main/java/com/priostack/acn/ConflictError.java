package com.priostack.acn;

import com.fasterxml.jackson.databind.JsonNode;

/** {@code conflict} — the write conflicts with existing state. */
public class ConflictError extends ACNToolError {

    private static final long serialVersionUID = 1L;

    public ConflictError(String outcome, String detail, String method, JsonNode data) {
        super(outcome, detail, method, data);
    }
}
