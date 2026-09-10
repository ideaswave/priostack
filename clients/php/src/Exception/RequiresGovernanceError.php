<?php

declare(strict_types=1);

namespace Priostack\Acn\Exception;

/** {@code requires-governance} — the change needs an explicit confirm step. */
class RequiresGovernanceError extends AcnToolError
{
    public const OUTCOME = 'requires-governance';
}
