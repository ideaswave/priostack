<?php

declare(strict_types=1);

namespace Priostack\Acn\Exception;

/**
 * A network, HTTP, decoding, or JSON-RPC protocol failure.
 *
 * Raised before a valid tool envelope could be obtained: connection errors,
 * timeouts, non-2xx HTTP responses, non-JSON bodies, envelopes missing the
 * {@code content[0].text} payload, or a JSON-RPC {@code error} object.
 */
class AcnTransportError extends AcnError
{
    /**
     * @param int|null $rpcCode    JSON-RPC error code, when the failure was a JSON-RPC {@code error}.
     *                             (Named {@code rpcCode}, not {@code code}, because
     *                             {@see \Exception} already reserves {@code $code}.)
     * @param int|null $httpStatus HTTP status code, when the failure was an HTTP error.
     */
    public function __construct(
        string $message,
        ?string $method = null,
        public readonly ?int $rpcCode = null,
        public readonly ?int $httpStatus = null,
        ?\Throwable $previous = null,
    ) {
        parent::__construct($message, $method, $previous);
    }
}
