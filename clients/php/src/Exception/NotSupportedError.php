<?php

declare(strict_types=1);

namespace Priostack\Acn\Exception;

/**
 * {@code not-implemented} — the tool is unavailable on this ACN deployment.
 *
 * Most commonly: calling {@see \Priostack\Acn\Client::register()} against a
 * single-tenant/offline ACN that does not offer self-registration.
 */
class NotSupportedError extends AcnToolError
{
    public const OUTCOME = 'not-implemented';
}
