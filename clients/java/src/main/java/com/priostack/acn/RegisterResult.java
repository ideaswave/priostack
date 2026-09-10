package com.priostack.acn;

import com.fasterxml.jackson.databind.JsonNode;

/** Result of {@link ACNClient#register}. */
public final class RegisterResult {

    private final String token;
    private final String agentId;
    private final String accountId;
    private final String tier;
    private final JsonNode raw;

    public RegisterResult(
            String token, String agentId, String accountId, String tier, JsonNode raw) {
        this.token = token;
        this.agentId = agentId;
        this.accountId = accountId;
        this.tier = tier;
        this.raw = raw;
    }

    /** The bearer token, shown once. Persist it to reconnect this agent later. */
    public String token() {
        return token;
    }

    public String agentId() {
        return agentId;
    }

    public String accountId() {
        return accountId;
    }

    public String tier() {
        return tier;
    }

    /** The full raw {@code data} object the server returned. */
    public JsonNode raw() {
        return raw;
    }

    @Override
    public String toString() {
        return "RegisterResult{agentId=" + agentId + ", accountId=" + accountId + ", tier=" + tier + '}';
    }
}
