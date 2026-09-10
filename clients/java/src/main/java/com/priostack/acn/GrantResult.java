package com.priostack.acn;

import com.fasterxml.jackson.databind.JsonNode;
import java.util.List;

/** Result of {@link ACNClient#grantAccess} / {@link ACNClient#approveRequest}. */
public final class GrantResult {

    private final String capabilityRef;
    private final String subject;
    private final String resource;
    private final List<String> effectiveRights;
    private final JsonNode raw;

    public GrantResult(
            String capabilityRef,
            String subject,
            String resource,
            List<String> effectiveRights,
            JsonNode raw) {
        this.capabilityRef = capabilityRef;
        this.subject = subject;
        this.resource = resource;
        this.effectiveRights = effectiveRights;
        this.raw = raw;
    }

    /** The capability reference; pass it to {@link ACNClient#revokeAccess} to revoke. */
    public String capabilityRef() {
        return capabilityRef;
    }

    public String subject() {
        return subject;
    }

    public String resource() {
        return resource;
    }

    public List<String> effectiveRights() {
        return effectiveRights;
    }

    public JsonNode raw() {
        return raw;
    }

    @Override
    public String toString() {
        return "GrantResult{capabilityRef="
                + capabilityRef
                + ", subject="
                + subject
                + ", resource="
                + resource
                + ", effectiveRights="
                + effectiveRights
                + '}';
    }
}
