<?php

declare(strict_types=1);

namespace Priostack\Acn\Exception;

/** {@code capability-denied} — missing capability, or an invalid/revoked token. */
class CapabilityDeniedError extends AcnToolError
{
    public const OUTCOME = 'capability-denied';
}
