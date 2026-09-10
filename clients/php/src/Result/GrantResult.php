<?php

declare(strict_types=1);

namespace Priostack\Acn\Result;

/**
 * Result of {@see \Priostack\Acn\Client::grantAccess()} and
 * {@see \Priostack\Acn\Client::approveRequest()}.
 *
 * Keep the {@see $capabilityRef} to later revoke the grant.
 */
final class GrantResult
{
    /**
     * @param list<string>         $effectiveRights
     * @param array<string, mixed> $raw
     */
    public function __construct(
        public readonly string $capabilityRef,
        public readonly string $subject,
        public readonly string $resource,
        public readonly array $effectiveRights,
        public readonly array $raw = [],
    ) {
    }

    /**
     * @param array<string, mixed> $data
     */
    public static function fromData(array $data): self
    {
        return new self(
            capabilityRef: (string) ($data['capabilityRef'] ?? ''),
            subject: (string) ($data['subject'] ?? ''),
            resource: (string) ($data['resource'] ?? ''),
            effectiveRights: array_values((array) ($data['effectiveRights'] ?? [])),
            raw: $data,
        );
    }
}
