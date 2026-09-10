package com.priostack.acn;

import com.fasterxml.jackson.databind.JsonNode;

/** {@code not-found} — no such session, space, or entity. */
public class NotFoundError extends ACNToolError {

    private static final long serialVersionUID = 1L;

    public NotFoundError(String outcome, String detail, String method, JsonNode data) {
        super(outcome, detail, method, data);
    }
}
