<?php

declare(strict_types=1);

namespace Priostack\Acn\Exception;

/** {@code policy-denied} — a governance policy refused the operation. */
class PolicyDeniedError extends AcnToolError
{
    public const OUTCOME = 'policy-denied';
}
