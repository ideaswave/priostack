<?php

declare(strict_types=1);

namespace Priostack\Acn\Exception;

/**
 * Base class for every error raised by {@see \Priostack\Acn\Client}.
 *
 * Catch this to handle anything the client can throw. Its two direct
 * subclasses split the two very different kinds of failure the ACN reports:
 * {@see AcnTransportError} (the request never produced a valid tool envelope)
 * and {@see AcnToolError} (the tool reached, but declined the call).
 */
class AcnError extends \RuntimeException
{
    /**
     * @param string      $message Human-readable description.
     * @param string|null $method  The {@code noetic.*} tool the failing call targeted, if known.
     */
    public function __construct(
        string $message,
        public readonly ?string $method = null,
        ?\Throwable $previous = null,
    ) {
        parent::__construct($message, 0, $previous);
    }
}
