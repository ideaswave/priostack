<?php

declare(strict_types=1);

namespace Priostack\Acn\Result;

/**
 * Result of {@see \Priostack\Acn\Client::register()}.
 *
 * The {@see $token} is shown once by the server; persist it to reconnect the
 * same agent later without registering again.
 */
final class RegisterResult
{
    /**
     * @param array<string, mixed> $raw The full, unwrapped {@code data} payload.
     */
    public function __construct(
        public readonly string $token,
        public readonly string $agentId,
        public readonly string $accountId,
        public readonly string $tier,
        public readonly array $raw = [],
    ) {
    }

    /**
     * @param array<string, mixed> $data
     */
    public static function fromData(array $data): self
    {
        return new self(
            token: (string) ($data['token'] ?? ''),
            agentId: (string) ($data['agentId'] ?? ''),
            accountId: (string) ($data['accountId'] ?? ''),
            tier: (string) ($data['tier'] ?? ''),
            raw: $data,
        );
    }
}
