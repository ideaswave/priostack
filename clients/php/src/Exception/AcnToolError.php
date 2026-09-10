<?php

declare(strict_types=1);

namespace Priostack\Acn\Exception;

/**
 * A tool declined the call (envelope {@code ok: false}).
 *
 * Carries the server {@code outcome} string and a human-readable {@code detail}.
 * Prefer catching a specific subclass; catch this base only when any tool-level
 * failure should be handled the same way.
 */
class AcnToolError extends AcnError
{
    /** The {@code outcome} string this subclass corresponds to (overridden per subclass). */
    public const OUTCOME = '';

    /** The server outcome (e.g. {@code "capability-denied"}); falls back to the class default. */
    public readonly string $outcome;

    /** The server's {@code detail} message, if any. */
    public readonly string $detail;

    /** Any partial {@code data} the server attached to the failure. */
    public readonly mixed $data;

    public function __construct(
        string $detail,
        string $outcome = '',
        ?string $method = null,
        mixed $data = null,
    ) {
        $message = $detail !== ''
            ? $detail
            : ($outcome !== '' ? $outcome : 'ACN tool error');
        parent::__construct($message, $method);
        $this->outcome = $outcome !== '' ? $outcome : static::OUTCOME;
        $this->detail = $detail;
        $this->data = $data;
    }

    /**
     * Build the most specific {@see AcnToolError} for a server {@code outcome}.
     *
     * Unknown outcomes fall back to this base class so a new server outcome
     * degrades gracefully instead of being mis-mapped.
     */
    public static function forOutcome(
        string $outcome,
        string $detail,
        ?string $method = null,
        mixed $data = null,
    ): self {
        /** @var array<string, class-string<AcnToolError>>|null $map */
        static $map = null;
        if ($map === null) {
            $map = [
                NotFoundError::OUTCOME => NotFoundError::class,
                InvalidQueryError::OUTCOME => InvalidQueryError::class,
                CapabilityDeniedError::OUTCOME => CapabilityDeniedError::class,
                PolicyDeniedError::OUTCOME => PolicyDeniedError::class,
                RequiresGovernanceError::OUTCOME => RequiresGovernanceError::class,
                StaleBaseError::OUTCOME => StaleBaseError::class,
                IntegrityFaultError::OUTCOME => IntegrityFaultError::class,
                ConflictError::OUTCOME => ConflictError::class,
                CapacityExhaustedError::OUTCOME => CapacityExhaustedError::class,
                NotSupportedError::OUTCOME => NotSupportedError::class,
            ];
        }

        $cls = $map[$outcome] ?? self::class;

        return new $cls($detail, $outcome, $method, $data);
    }
}
