package com.priostack.acn;

import com.fasterxml.jackson.databind.JsonNode;
import java.util.List;

/**
 * Result of {@link ACNClient#connect}.
 *
 * <p>The connect envelope's {@code data} uses PascalCase Go field names
 * ({@code SessionID}, {@code ResolvedAccount}, ...); this client maps them to
 * idiomatic Java accessors. All other tools use lowercase keys.
 */
public final class ConnectResult {

    private final String sessionId;
    private final String resolvedAccount;
    private final List<String> grantedCapabilities;
    private final List<String> grantedContextRights;
    private final String boundSpace;
    private final int resolvedMaxTokens;
    private final JsonNode raw;

    public ConnectResult(
            String sessionId,
            String resolvedAccount,
            List<String> grantedCapabilities,
            List<String> grantedContextRights,
            String boundSpace,
            int resolvedMaxTokens,
            JsonNode raw) {
        this.sessionId = sessionId;
        this.resolvedAccount = resolvedAccount;
        this.grantedCapabilities = grantedCapabilities;
        this.grantedContextRights = grantedContextRights;
        this.boundSpace = boundSpace;
        this.resolvedMaxTokens = resolvedMaxTokens;
        this.raw = raw;
    }

    /** The session id (from PascalCase {@code SessionID}), captured on the client. */
    public String sessionId() {
        return sessionId;
    }

    public String resolvedAccount() {
        return resolvedAccount;
    }

    public List<String> grantedCapabilities() {
        return grantedCapabilities;
    }

    public List<String> grantedContextRights() {
        return grantedContextRights;
    }

    public String boundSpace() {
        return boundSpace;
    }

    public int resolvedMaxTokens() {
        return resolvedMaxTokens;
    }

    public JsonNode raw() {
        return raw;
    }

    @Override
    public String toString() {
        return "ConnectResult{sessionId="
                + sessionId
                + ", resolvedAccount="
                + resolvedAccount
                + ", resolvedMaxTokens="
                + resolvedMaxTokens
                + '}';
    }
}
