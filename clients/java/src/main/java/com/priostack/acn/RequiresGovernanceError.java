package com.priostack.acn;

import com.fasterxml.jackson.databind.JsonNode;

/** {@code requires-governance} — the change needs an explicit confirm step. */
public class RequiresGovernanceError extends ACNToolError {

    private static final long serialVersionUID = 1L;

    public RequiresGovernanceError(String outcome, String detail, String method, JsonNode data) {
        super(outcome, detail, method, data);
    }
}
