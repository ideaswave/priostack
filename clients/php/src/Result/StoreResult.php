<?php

declare(strict_types=1);

namespace Priostack\Acn\Result;

/**
 * Result of {@see \Priostack\Acn\Client::store()}.
 */
final class StoreResult
{
    /**
     * @param list<array<string, mixed>> $objectRefs One ref per ingested object.
     * @param array<string, mixed>       $raw
     */
    public function __construct(
        public readonly array $objectRefs,
        public readonly array $raw = [],
    ) {
    }

    /**
     * @param array<string, mixed> $data
     */
    public static function fromData(array $data): self
    {
        return new self(
            objectRefs: array_values((array) ($data['objectRefs'] ?? [])),
            raw: $data,
        );
    }

    /** How many objects were ingested. */
    public function count(): int
    {
        return count($this->objectRefs);
    }
}
