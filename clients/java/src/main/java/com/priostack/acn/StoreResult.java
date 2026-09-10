package com.priostack.acn;

import com.fasterxml.jackson.databind.JsonNode;
import java.util.List;

/** Result of {@link ACNClient#store}. */
public final class StoreResult {

    private final List<JsonNode> objectRefs;
    private final JsonNode raw;

    public StoreResult(List<JsonNode> objectRefs, JsonNode raw) {
        this.objectRefs = objectRefs;
        this.raw = raw;
    }

    /** One reference per ingested object. */
    public List<JsonNode> objectRefs() {
        return objectRefs;
    }

    /** How many objects were ingested. */
    public int count() {
        return objectRefs.size();
    }

    public JsonNode raw() {
        return raw;
    }

    @Override
    public String toString() {
        return "StoreResult{count=" + count() + '}';
    }
}
