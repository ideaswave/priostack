package com.priostack.acn;

import com.fasterxml.jackson.databind.JsonNode;

/**
 * {@code not-implemented} — the tool is unavailable on this ACN deployment.
 *
 * <p>Most commonly: calling {@link ACNClient#register(String)} against a
 * single-tenant/offline ACN that does not offer self-registration.
 */
public class NotSupportedError extends ACNToolError {

    private static final long serialVersionUID = 1L;

    public NotSupportedError(String outcome, String detail, String method, JsonNode data) {
        super(outcome, detail, method, data);
    }
}
