<?php

declare(strict_types=1);

namespace Priostack\Acn\Exception;

/** {@code invalid-query} — malformed arguments or an unknown enum value. */
class InvalidQueryError extends AcnToolError
{
    public const OUTCOME = 'invalid-query';
}
