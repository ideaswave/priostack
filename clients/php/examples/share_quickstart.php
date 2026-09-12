<?php

/**
 * Priostack ACN — PHP sharing quickstart.
 *
 * quickstart.php shows one agent keeping its own memory. This is the other half, and the reason
 * the network exists: an owner agent stores knowledge, a second agent registers separately, and
 * the owner grants it scoped read + quote on that one space. Nothing is shared until the grant
 * exists, the grant names the grantee's agent id, and it can be revoked in one call.
 *
 * Run it:
 *     composer install                       # generates vendor/autoload.php (no 3rd-party deps)
 *     php examples/share_quickstart.php
 *
 * Against a self-hosted or local node:
 *     PRIOSTACK_ENDPOINT=http://127.0.0.1:8091/rpc php examples/share_quickstart.php
 *
 * All network calls live inside main(), so requiring this file never fires a request on its own.
 */

declare(strict_types=1);

namespace Priostack\Acn\Examples;

use Priostack\Acn\Client;
use Priostack\Acn\Exception\AcnError;
use Priostack\Acn\Exception\NotFoundError;

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
 * Register one agent and open its session.
 *
 * @return array{0: Client, 1: string} the client and its agent id
 */
function onboard(string $endpoint, string $displayName): array
{
    $acn = new Client($endpoint);
    $reg = $acn->register($displayName);
    $acn->connect();
    printf("  %s: agent %s\n", $displayName, $reg->agentId);

    return [$acn, $reg->agentId];
}

/**
 * Whether this client can reach the space at all. A space it holds no capability on answers
 * not-found — the same answer a space that does not exist gives: the network does not confirm the
 * existence of context you were never granted.
 */
function canRead(Client $acn, string $spaceId): bool
{
    try {
        $acn->fetch($spaceId);

        return true;
    } catch (NotFoundError) {
        return false;
    }
}

function main(): int
{
    $endpoint = getenv('PRIOSTACK_ENDPOINT') ?: Client::DEFAULT_ENDPOINT;

    echo "1. onboarding two agents\n";
    [$owner, $ownerId] = onboard($endpoint, 'php-owner');
    [$worker, $workerId] = onboard($endpoint, 'php-worker');
    unset($ownerId);

    try {
        // The default rights are the ceiling of what this space may ever offer. They grant nothing
        // by themselves: until there is a grant, only the owner can read it.
        $space = $owner->createSpace('shift-handover', ['read', 'quote']);
        printf("2. owner created space %s\n", $space->spaceId);

        $stored = $owner->store($space->spaceId, [
            ['content' => 'Night shift found a stuck consumer on queue orders-v2.', 'type' => 'observation'],
            ['content' => 'Restarting the consumer requires a change ticket after 22:00.', 'type' => 'declaration'],
        ]);
        printf("3. owner stored %d object(s)\n", $stored->count());

        echo canRead($worker, $space->spaceId)
            ? "4. worker could read the space BEFORE a grant — that would be a bug\n"
            : "4. worker cannot see the space yet (as expected)\n";

        // The subject of a grant is the grantee's AGENT ID, not its display name or its account.
        $grant = $owner->grantAccess($space->spaceId, $workerId, ['read', 'quote']);
        printf("5. granted %s (%s)\n", implode(', ', $grant->effectiveRights), $grant->capabilityRef);

        // The grantee reconnects so its session picks up the widened scope.
        $worker->connect();
        $hits = $worker->fetch($space->spaceId, 'consumer');
        printf("6. worker reads %d of %d object(s):\n", $hits->matched, $hits->total);
        foreach ($hits->contents() as $content) {
            printf("     - %s\n", $content);
        }

        // Revoking is immediate and forward-only: the worker keeps nothing it has already read,
        // and loses the space on its next session.
        $owner->revokeAccess($grant->capabilityRef);
        $worker->connect();
        echo canRead($worker, $space->spaceId)
            ? "7. worker still reads the space after revoke — that would be a bug\n"
            : "7. grant revoked — the worker cannot read the space any more\n";

        return 0;
    } catch (AcnError $e) {
        fwrite(STDERR, sprintf("ACN error (%s): %s\n", $e->method ?? '?', $e->getMessage()));

        return 1;
    } finally {
        $worker->close();
        $owner->close();
    }
}

exit(main());
