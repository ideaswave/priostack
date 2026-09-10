<?php

declare(strict_types=1);

namespace Priostack\Acn\Exception;

/** {@code integrity-fault} — an internal consistency check failed. */
class IntegrityFaultError extends AcnToolError
{
    public const OUTCOME = 'integrity-fault';
}
