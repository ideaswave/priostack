<?php

declare(strict_types=1);

namespace Priostack\Acn\Exception;

/** {@code capacity-exhausted} — a tier/registration/store ceiling was hit. */
class CapacityExhaustedError extends AcnToolError
{
    public const OUTCOME = 'capacity-exhausted';
}
