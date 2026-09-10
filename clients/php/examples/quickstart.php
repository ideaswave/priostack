<?php

/**
 * Priostack ACN — PHP quickstart.
 *
 * register -> connect -> createSpace -> store -> fetch, printing results.
 *
 * Run it:
 *     composer install                       # generates vendor/autoload.php (no 3rd-party deps)
 *     php examples/quickstart.php "my-agent"
 *
 * The endpoint can be overridden with the PRIOSTACK_ENDPOINT environment
 * variable; the display name is the first CLI argument (default "php-sdk-smoke").
 *
 * All network calls live inside main(), so requiring this file (or the library)
 * never fires a request on its own.
 */

declare(strict_types=1);

namespace Priostack\Acn\Examples;

use Priostack\Acn\Client;
use Priostack\Acn\Exception\AcnError;

// Prefer the Composer autoloader; fall back to a minimal PSR-4 loader so the
// example also runs from a bare clone (the library has no third-party deps).
$autoload = __DIR__ . '/../vendor/autoload.php';
if (is_file($autoload)) {
    require $autoload;
} else {
    spl_autoload_register(static function (string $class): void {
        $prefix = 'Priostack\\Acn\\';
        if (!str_starts_with($class, $prefix)) {
            return;
        }
        $relative = str_replace('\\', '/', substr($class, strlen($prefix)));
        $file = __DIR__ . '/../src/' . $relative . '.php';
        if (is_file($file)) {
            require $file;
        }
    });
}

/**
 * @param list<string> $argv
 */
function main(array $argv): int
{
    $displayName = $argv[1] ?? 'php-sdk-smoke';
    $endpoint = getenv('PRIOSTACK_ENDPOINT') ?: Client::DEFAULT_ENDPOINT;

    $acn = new Client($endpoint);

    try {
        $reg = $acn->register($displayName);
        printf("registered   agentId=%s  tier=%s\n", $reg->agentId, $reg->tier);

        $conn = $acn->connect();
        printf("connected    session=%s  maxTokens=%d\n", $conn->sessionId, $conn->resolvedMaxTokens);

        $space = $acn->createSpace('php-quickstart-memory');
        printf("created      space=%s\n", $space->spaceId);

        $stored = $acn->store($space->spaceId, [
            ['content' => 'Refunds over $500 need manager approval.', 'type' => 'declaration'],
            ['content' => 'Checkout p99 latency was 812ms on 2026-09-09.', 'type' => 'measurement'],
        ]);
        printf("stored       %d object(s)\n", $stored->count());

        $hits = $acn->fetch($space->spaceId, 'refund');
        printf("fetched      matched=%d of total=%d  (returnedTokens=%d)\n", $hits->matched, $hits->total, $hits->returnedTokens);
        foreach ($hits->objects as $obj) {
            printf("  - [%s] %s\n", (string) ($obj['kind'] ?? '?'), (string) ($obj['content'] ?? ''));
        }

        return 0;
    } catch (AcnError $e) {
        fwrite(STDERR, sprintf("ACN error (%s): %s\n", $e->method ?? '?', $e->getMessage()));

        return 1;
    } finally {
        $acn->close();
    }
}

exit(main($argv));
