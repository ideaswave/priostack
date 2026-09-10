<?php

declare(strict_types=1);

namespace Priostack\Acn\Exception;

/** {@code not-found} — no such session, space, or entity. */
class NotFoundError extends AcnToolError
{
    public const OUTCOME = 'not-found';
}
