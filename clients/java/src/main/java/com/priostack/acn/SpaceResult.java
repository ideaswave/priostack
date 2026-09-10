package com.priostack.acn;

import com.fasterxml.jackson.databind.JsonNode;

/** Result of {@link ACNClient#createSpace}. Use {@link #spaceId} for writes. */
public final class SpaceResult {

    private final String spaceId;
    private final String accountId;
    private final String persistenceMode;
    private final String protectionLevel;
    private final JsonNode raw;

    public SpaceResult(
            String spaceId,
            String accountId,
            String persistenceMode,
            String protectionLevel,
            JsonNode raw) {
        this.spaceId = spaceId;
        this.accountId = accountId;
        this.persistenceMode = persistenceMode;
        this.protectionLevel = protectionLevel;
        this.raw = raw;
    }

    /** The resolved space id; pass this to {@code store}/{@code fetch}/{@code grant}. */
    public String spaceId() {
        return spaceId;
    }

    public String accountId() {
        return accountId;
    }

    public String persistenceMode() {
        return persistenceMode;
    }

    public String protectionLevel() {
        return protectionLevel;
    }

    public JsonNode raw() {
        return raw;
    }

    @Override
    public String toString() {
        return "SpaceResult{spaceId=" + spaceId + ", persistenceMode=" + persistenceMode + '}';
    }
}
