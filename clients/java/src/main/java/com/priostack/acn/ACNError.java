package com.priostack.acn;

/**
 * Base class for every error raised by {@link ACNClient}.
 *
 * <p>Catch {@code ACNError} to handle anything the client can throw. To
 * distinguish the two broad failure modes, catch {@link ACNTransportError}
 * (the request never produced a valid tool envelope) or {@link ACNToolError}
 * (a tool reached but declined the call) instead.
 *
 * <p>Errors are unchecked so the fluent API stays readable, mirroring the
 * exception model of the reference Python client.
 */
public class ACNError extends RuntimeException {

    private static final long serialVersionUID = 1L;

    /** The tool name ({@code noetic.*}) the failing call targeted, if known. */
    private final String method;

    public ACNError(String message, String method) {
        super(message);
        this.method = method;
    }

    public ACNError(String message, String method, Throwable cause) {
        super(message, cause);
        this.method = method;
    }

    /** The {@code noetic.*} tool the failing call targeted, or {@code null}. */
    public String method() {
        return method;
    }
}
