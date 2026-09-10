package com.priostack.acn;

import com.fasterxml.jackson.databind.JsonNode;
import java.util.ArrayList;
import java.util.List;

/** Result of {@link ACNClient#fetch} — the content reader. */
public final class FetchResult {

    private final String space;
    private final List<JsonNode> objects;
    private final int matched;
    private final int total;
    private final int returnedTokens;
    private final JsonNode raw;

    public FetchResult(
            String space,
            List<JsonNode> objects,
            int matched,
            int total,
            int returnedTokens,
            JsonNode raw) {
        this.space = space;
        this.objects = objects;
        this.matched = matched;
        this.total = total;
        this.returnedTokens = returnedTokens;
        this.raw = raw;
    }

    public String space() {
        return space;
    }

    /** The returned objects, each {@code {objectRef, kind, content, tokens}}. */
    public List<JsonNode> objects() {
        return objects;
    }

    public int matched() {
        return matched;
    }

    public int total() {
        return total;
    }

    public int returnedTokens() {
        return returnedTokens;
    }

    public JsonNode raw() {
        return raw;
    }

    /** Just the {@code content} strings of the returned objects. */
    public List<String> contents() {
        List<String> out = new ArrayList<>(objects.size());
        for (JsonNode o : objects) {
            out.add(o.path("content").asText(""));
        }
        return out;
    }

    @Override
    public String toString() {
        return "FetchResult{space="
                + space
                + ", matched="
                + matched
                + ", total="
                + total
                + ", returnedTokens="
                + returnedTokens
                + '}';
    }
}
