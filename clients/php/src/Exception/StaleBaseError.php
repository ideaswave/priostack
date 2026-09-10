<?php

declare(strict_types=1);

namespace Priostack\Acn\Exception;

/** {@code stale-base} — the operation raced a newer state; re-read and retry. */
class StaleBaseError extends AcnToolError
{
    public const OUTCOME = 'stale-base';
}
