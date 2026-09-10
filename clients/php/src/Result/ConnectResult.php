<?php

declare(strict_types=1);

namespace Priostack\Acn\Result;

/**
 * Result of {@see \Priostack\Acn\Client::connect()}.
 *
 * NOTE: the {@code connect} envelope {@code data} is the only one that uses
 * PascalCase Go field names ({@code SessionID}, {@code ResolvedAccount}, ...).
 * This factory maps them onto lower-camelCase PHP properties; every other tool
 * uses lowercase keys.
 */
final class ConnectResult
{
    /**
     * @param list<string>         $grantedCapabilities
     * @param list<string>         $grantedContextRights
     * @param array<string, mixed> $raw
     */
    public function __construct(
        public readonly string $sessionId,
        public readonly string $resolvedAccount,
        public readonly array $grantedCapabilities,
        public readonly array $grantedContextRights,
        public readonly string $boundSpace,
        public readonly int $resolvedMaxTokens,
        public readonly array $raw = [],
    ) {
    }

    /**
     * @param array<string, mixed> $data
     */
    public static function fromData(array $data): self
    {
        return new self(
            sessionId: (string) ($data['SessionID'] ?? ''),
            resolvedAccount: (string) ($data['ResolvedAccount'] ?? ''),
            grantedCapabilities: array_values((array) ($data['GrantedCapabilities'] ?? [])),
            grantedContextRights: array_values((array) ($data['GrantedContextRights'] ?? [])),
            boundSpace: (string) ($data['BoundSpace'] ?? ''),
            resolvedMaxTokens: (int) ($data['ResolvedMaxTokens'] ?? 0),
            raw: $data,
        );
    }
}
