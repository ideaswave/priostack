package com.priostack.acn;

/**
 * A network, HTTP, decoding, or JSON-RPC protocol failure.
 *
 * <p>Raised before a valid tool envelope could be obtained: connection errors,
 * timeouts, non-2xx HTTP responses, non-JSON bodies, envelopes missing the
 * {@code content[0].text} payload, or a top-level JSON-RPC {@code error}
 * object. Contrast with {@link ACNToolError}, which means the tool ran and
 * declined the call.
 */
public class ACNTransportError extends ACNError {

    private static final long serialVersionUID = 1L;

    private final Integer code;
    private final Integer httpStatus;

    public ACNTransportError(String message, String method) {
        this(message, method, null, null, null);
    }

    public ACNTransportError(String message, String method, Integer code, Integer httpStatus) {
        this(message, method, code, httpStatus, null);
    }

    public ACNTransportError(
            String message, String method, Integer code, Integer httpStatus, Throwable cause) {
        super(message, method, cause);
        this.code = code;
        this.httpStatus = httpStatus;
    }

    /** JSON-RPC error code, when the failure was a JSON-RPC {@code error}; else {@code null}. */
    public Integer code() {
        return code;
    }

    /** HTTP status code, when the failure was an HTTP error; else {@code null}. */
    public Integer httpStatus() {
        return httpStatus;
    }
}
