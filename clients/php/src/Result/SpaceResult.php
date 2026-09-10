<?php

declare(strict_types=1);

namespace Priostack\Acn\Result;

/**
 * Result of {@see \Priostack\Acn\Client::createSpace()}.
 *
 * Use the returned {@see $spaceId} for subsequent {@code store}/{@code fetch}
 * calls — it is the server-resolved id, not necessarily the display name.
 */
final class SpaceResult
{
    /**
     * @param array<string, mixed> $raw
     */
    public function __construct(
        public readonly string $spaceId,
        public readonly string $accountId,
        public readonly string $persistenceMode,
        public readonly string $protectionLevel,
        public readonly array $raw = [],
    ) {
    }

    /**
     * @param array<string, mixed> $data
     */
    public static function fromData(array $data): self
    {
        return new self(
            spaceId: (string) ($data['spaceId'] ?? ''),
            accountId: (string) ($data['accountId'] ?? ''),
            persistenceMode: (string) ($data['persistenceMode'] ?? ''),
            protectionLevel: (string) ($data['protectionLevel'] ?? ''),
            raw: $data,
        );
    }
}
