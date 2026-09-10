package com.priostack.acn;

/**
 * The {@code type} values the {@code store} tool accepts.
 *
 * <p>Anything else is rejected server-side with {@code invalid-query}
 * (proposals and inferences go through the propose/commit path, not
 * {@code store}). The enum guards this common mistake at compile time.
 */
public enum ObjectType {
    DECLARATION("declaration"),
    OBSERVATION("observation"),
    MEASUREMENT("measurement");

    private final String wire;

    ObjectType(String wire) {
        this.wire = wire;
    }

    /** The lowercase wire value the server expects. */
    public String wire() {
        return wire;
    }

    /** Parse a wire value ({@code declaration}/{@code observation}/{@code measurement}). */
    public static ObjectType fromWire(String value) {
        for (ObjectType t : values()) {
            if (t.wire.equals(value)) {
                return t;
            }
        }
        throw new IllegalArgumentException(
                "invalid object type " + value + "; must be one of declaration, observation, measurement");
    }
}
