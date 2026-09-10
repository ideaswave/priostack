<?php

declare(strict_types=1);

namespace Priostack\Acn\Result;

/**
 * Result of {@see \Priostack\Acn\Client::fetch()} (the content reader).
 *
 * Each entry in {@see $objects} is an associative array shaped like
 * {@code {objectRef, kind, content, tokens}}.
 */
final class FetchResult
{
    /**
     * @param list<array<string, mixed>> $objects
     * @param array<string, mixed>       $raw
     */
    public function __construct(
        public readonly string $space,
        public readonly array $objects,
        public readonly int $matched,
        public readonly int $total,
        public readonly int $returnedTokens,
        public readonly array $raw = [],
    ) {
    }

    /**
     * @param array<string, mixed> $data
     */
    public static function fromData(array $data, string $fallbackSpace = ''): self
    {
        return new self(
            space: (string) ($data['space'] ?? $fallbackSpace),
            objects: array_values((array) ($data['objects'] ?? [])),
            matched: (int) ($data['matched'] ?? 0),
            total: (int) ($data['total'] ?? 0),
            returnedTokens: (int) ($data['returnedTokens'] ?? 0),
            raw: $data,
        );
    }

    /**
     * Just the {@code content} strings of the returned objects.
     *
     * @return list<string>
     */
    public function contents(): array
    {
        return array_map(
            static fn (array $o): string => (string) ($o['content'] ?? ''),
            $this->objects,
        );
    }
}
