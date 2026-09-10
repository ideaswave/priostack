package com.priostack.acn;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;

/**
 * One typed fact to persist with {@link ACNClient#store}.
 *
 * <p>A fact is a {@code content} string plus an {@link ObjectType}, and an
 * optional {@code provenance} list. Instances are immutable; {@link
 * #withProvenance} returns a copy.
 */
public final class StoreObject {

    private final String content;
    private final ObjectType type;
    private final List<String> provenance;

    public StoreObject(String content, ObjectType type) {
        this(content, type, null);
    }

    public StoreObject(String content, ObjectType type, List<String> provenance) {
        this.content = Objects.requireNonNull(content, "content");
        this.type = Objects.requireNonNull(type, "type");
        this.provenance =
                (provenance == null || provenance.isEmpty())
                        ? List.of()
                        : List.copyOf(provenance);
    }

    /** A {@link ObjectType#DECLARATION} fact. */
    public static StoreObject declaration(String content) {
        return new StoreObject(content, ObjectType.DECLARATION);
    }

    /** An {@link ObjectType#OBSERVATION} fact. */
    public static StoreObject observation(String content) {
        return new StoreObject(content, ObjectType.OBSERVATION);
    }

    /** A {@link ObjectType#MEASUREMENT} fact. */
    public static StoreObject measurement(String content) {
        return new StoreObject(content, ObjectType.MEASUREMENT);
    }

    /** A copy of this object with the given provenance attached. */
    public StoreObject withProvenance(List<String> provenance) {
        return new StoreObject(content, type, provenance);
    }

    public String content() {
        return content;
    }

    public ObjectType type() {
        return type;
    }

    public List<String> provenance() {
        return provenance;
    }

    /** The wire form the {@code store} tool expects: {@code {content, type, provenance?}}. */
    Map<String, Object> toWire() {
        Map<String, Object> out = new LinkedHashMap<>();
        out.put("content", content);
        out.put("type", type.wire());
        if (!provenance.isEmpty()) {
            out.put("provenance", new ArrayList<>(provenance));
        }
        return out;
    }
}
