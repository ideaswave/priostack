<?php

declare(strict_types=1);

namespace Priostack\Acn\Exception;

/** {@code conflict} — the write conflicts with existing state. */
class ConflictError extends AcnToolError
{
    public const OUTCOME = 'conflict';
}
