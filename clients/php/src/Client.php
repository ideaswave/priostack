<?php

declare(strict_types=1);

namespace Priostack\Acn;

use Priostack\Acn\Exception\AcnToolError;
use Priostack\Acn\Exception\AcnTransportError;
use Priostack\Acn\Result\ConnectResult;
use Priostack\Acn\Result\FetchResult;
use Priostack\Acn\Result\GrantResult;
use Priostack\Acn\Result\RegisterResult;
use Priostack\Acn\Result\SpaceResult;
use Priostack\Acn\Result\StoreResult;

/**
 * Official PHP client for the Priostack Agent Context Network (ACN).
 *
 * The ACN is a Model Context Protocol (MCP) server reached over JSON-RPC 2.0.
 * An agent self-registers, opens a session with the returned bearer token,
 * creates isolated context spaces, stores typed facts, reads them back, and
 * shares them with other agents through scoped capability grants.
 *
 * This client speaks the exact wire contract of the live server: it unwraps the
 * MCP {@code result.content[0].text} envelope, throws typed exceptions on
 * tool-level denials, reuses one pooled cURL connection, retries transient
 * connection faults with backoff, and captures the session id automatically on
 * {@see connect()}.
 *
 * Quickstart:
 * <code>
 * $acn = new Client();
 * try {
 *     $acn->register('my-agent');            // token captured internally
 *     $acn->connect();                       // session id captured internally
 *     $space = $acn->createSpace('prod-memory');
 *     $acn->store($space->spaceId, [
 *         ['content' => 'Refunds over $500 need manager approval.', 'type' => 'declaration'],
 *     ]);
 *     foreach ($acn->fetch($space->spaceId, 'refund')->objects as $obj) {
 *         echo $obj['content'], PHP_EOL;
 *     }
 * } finally {
 *     $acn->close();
 * }
 * </code>
 *
 * The client is not safe for concurrent use from multiple threads; give each
 * worker its own instance.
 */
final class Client
{
    /** Canonical MCP endpoint (Streamable HTTP). {@code /acn/rpc} is a working alias. */
    public const DEFAULT_ENDPOINT = 'https://priostack.com/mcp';

    /**
     * Object {@code type} values the {@code store} tool accepts. Anything else
     * is rejected server-side with {@code invalid-query}.
     *
     * @var list<string>
     */
    public const STORE_KINDS = ['declaration', 'observation', 'measurement'];

    /** Client version, surfaced in the User-Agent header. */
    public const VERSION = '0.1.0';

    private string $endpoint;
    private float $timeout;
    private int $maxRetries;
    private float $backoffFactor;

    private ?string $token;
    private ?string $sessionId = null;

    private int $nextId = 1;

    private ?\CurlHandle $curl = null;

    /** @var array<string, string> Lower-cased response headers of the last request. */
    private array $responseHeaders = [];

    /**
     * @param string      $endpoint      Base RPC URL. Defaults to the canonical MCP endpoint.
     * @param string|null $token         A previously issued bearer token, to reconnect an existing
     *                                   agent without registering again. {@see register()} sets it.
     * @param float       $timeout       Per-request timeout in seconds, applied to every call.
     * @param int         $maxRetries    How many times to retry *connection* faults and back-pressure
     *                                   statuses (429, 503). Read timeouts are never retried, so a
     *                                   non-idempotent call such as {@code store} is never duplicated.
     * @param float       $backoffFactor Exponential backoff base (seconds) between retries.
     */
    public function __construct(
        string $endpoint = self::DEFAULT_ENDPOINT,
        ?string $token = null,
        float $timeout = 30.0,
        int $maxRetries = 3,
        float $backoffFactor = 0.5,
    ) {
        if (!\extension_loaded('curl')) {
            throw new \RuntimeException('the priostack/acn-client requires the PHP cURL extension (ext-curl)');
        }
        if (!\extension_loaded('json')) {
            throw new \RuntimeException('the priostack/acn-client requires the PHP JSON extension (ext-json)');
        }

        $this->endpoint = $endpoint;
        $this->timeout = $timeout;
        $this->maxRetries = max(0, $maxRetries);
        $this->backoffFactor = max(0.0, $backoffFactor);
        $this->token = $token;

        $this->curl = $this->makeHandle();
    }

    public function __destruct()
    {
        // Free the connection only; never do network I/O (a disconnect) from a
        // destructor. Callers use close() for a graceful disconnect.
        if ($this->curl !== null) {
            curl_close($this->curl);
            $this->curl = null;
        }
    }

    // -- lifecycle --------------------------------------------------------- //

    /**
     * Best-effort disconnect (if connected) and release the cURL connection.
     * Safe to call more than once; never throws.
     */
    public function close(): void
    {
        try {
            if ($this->sessionId !== null) {
                $this->disconnect();
            }
        } catch (\Throwable) {
            // closing must never raise
        } finally {
            if ($this->curl !== null) {
                curl_close($this->curl);
                $this->curl = null;
            }
        }
    }

    /** Whether a session id has been captured. */
    public function isConnected(): bool
    {
        return $this->sessionId !== null;
    }

    /** The bearer token captured by {@see register()}/{@see connect()}, if any. */
    public function getToken(): ?string
    {
        return $this->token;
    }

    /** The active session id captured by {@see connect()}, if any. */
    public function getSessionId(): ?string
    {
        return $this->sessionId;
    }

    // -- identity ---------------------------------------------------------- //

    /**
     * Self-register a new agent and capture its bearer token.
     *
     * Only available on the online multi-agent ACN. The token is shown once; it
     * is stored on this client and returned so you can persist it for future
     * sessions.
     *
     * @throws \Priostack\Acn\Exception\NotSupportedError on a single-tenant ACN.
     * @throws AcnTransportError|AcnToolError
     */
    public function register(string $displayName = 'agent'): RegisterResult
    {
        $data = $this->call('noetic.register', ['displayName' => $displayName]);
        $token = $data['token'] ?? null;
        if (!is_string($token) || $token === '') {
            throw new AcnTransportError(
                'register returned no token: ' . $this->describe($data),
                'noetic.register',
            );
        }
        $this->token = $token;

        return RegisterResult::fromData($data);
    }

    /**
     * Open a session with a bearer token and capture the session id.
     *
     * Pass {@code $token} explicitly, or rely on the token captured by
     * {@see register()} / passed to the constructor. Re-call {@code connect}
     * after being granted access to a space so the widened scope is applied.
     *
     * @throws AcnTransportError|AcnToolError
     */
    public function connect(?string $token = null, int $maxTokens = 4096): ConnectResult
    {
        $tok = $token ?? $this->token;
        if ($tok === null || $tok === '') {
            throw new AcnTransportError('connect() needs a token: register() first or pass a token');
        }

        $data = $this->call('noetic.connect', ['token' => $tok, 'maxResponseTokens' => $maxTokens]);

        // The connect envelope is the one place the server serializes with Go
        // field names (PascalCase): the session id is `SessionID`, not `sessionId`.
        $sid = $data['SessionID'] ?? null;
        if (!is_string($sid) || $sid === '') {
            throw new AcnTransportError(
                'connect returned no SessionID: ' . $this->describe($data),
                'noetic.connect',
            );
        }

        $this->sessionId = $sid;
        $this->token = $tok;

        return ConnectResult::fromData($data);
    }

    /**
     * End the current session. Durable facts are *not* revoked.
     *
     * @return array<string, mixed>
     * @throws AcnTransportError|AcnToolError
     */
    public function disconnect(): array
    {
        $sid = $this->requireSession();
        $data = $this->call('noetic.disconnect', ['sessionId' => $sid]);
        $this->sessionId = null;

        return $data;
    }

    /**
     * Mint a fresh bearer token for this agent and retire the old one.
     *
     * Existing sessions keep working; use the new token for future
     * {@see connect()} calls. The new token is stored on this client.
     *
     * @throws AcnTransportError|AcnToolError
     */
    public function rotateToken(): string
    {
        $sid = $this->requireSession();
        $data = $this->call('noetic.rotate_token', ['sessionId' => $sid]);
        $token = $data['token'] ?? null;
        if (!is_string($token) || $token === '') {
            throw new AcnTransportError('rotate_token returned no token', 'noetic.rotate_token');
        }
        $this->token = $token;

        return $token;
    }

    /**
     * Discover the grantable rights + world-mutation vocabulary in scope.
     *
     * @return array<string, mixed>
     * @throws AcnTransportError|AcnToolError
     */
    public function capabilities(): array
    {
        return $this->call('noetic.capabilities', ['sessionId' => $this->requireSession()]);
    }

    // -- spaces + facts ---------------------------------------------------- //

    /**
     * Create an isolated context space and return its resolved id.
     *
     * {@code $defaultRights} is the ceiling of rights the space may offer to
     * others; it does not grant anything by itself.
     *
     * @param list<string>|null $defaultRights
     * @throws AcnTransportError|AcnToolError
     */
    public function createSpace(
        string $displayName,
        ?array $defaultRights = null,
        ?string $visibility = null,
        ?string $persistenceMode = null,
        ?string $protectionLevel = null,
    ): SpaceResult {
        $args = [
            'sessionId' => $this->requireSession(),
            'displayName' => $displayName,
        ];
        if ($defaultRights !== null) {
            $args['defaultRights'] = array_values($defaultRights);
        }
        if ($visibility !== null) {
            $args['visibility'] = $visibility;
        }
        if ($persistenceMode !== null) {
            $args['persistenceMode'] = $persistenceMode;
        }
        if ($protectionLevel !== null) {
            $args['protectionLevel'] = $protectionLevel;
        }

        $data = $this->call('noetic.create_space', $args);
        $spaceId = $data['spaceId'] ?? null;
        if (!is_string($spaceId) || $spaceId === '') {
            throw new AcnTransportError(
                'create_space returned no spaceId: ' . $this->describe($data),
                'noetic.create_space',
            );
        }

        return SpaceResult::fromData($data);
    }

    /**
     * Persist typed facts into a space.
     *
     * Each object is {@code ['content' => string, 'type' => <kind>, 'provenance'? => [...]]}
     * where {@code type} is one of {@see STORE_KINDS}. Writing needs the write
     * right and the {@code mutate} capability; the space owner has both.
     *
     * @param string                     $spaceId The space id (the arg key on the wire is {@code space}).
     * @param list<array<string, mixed>> $objects
     * @throws \InvalidArgumentException on a malformed object.
     * @throws AcnTransportError|AcnToolError
     */
    public function store(string $spaceId, array $objects): StoreResult
    {
        $sid = $this->requireSession();
        $normalized = array_map($this->normalizeObject(...), array_values($objects));

        $data = $this->call('noetic.store', [
            'sessionId' => $sid,
            'space' => $spaceId,
            'objects' => $normalized,
        ]);

        return StoreResult::fromData($data);
    }

    /**
     * @param array<string, mixed> $obj
     * @return array<string, mixed>
     */
    private function normalizeObject(array $obj): array
    {
        if (!array_key_exists('content', $obj)) {
            throw new \InvalidArgumentException("each stored object needs a 'content' field");
        }
        $kind = $obj['type'] ?? 'declaration';
        if (!in_array($kind, self::STORE_KINDS, true)) {
            throw new \InvalidArgumentException(sprintf(
                "invalid object type '%s'; must be one of %s",
                is_scalar($kind) ? (string) $kind : gettype($kind),
                implode(', ', self::STORE_KINDS),
            ));
        }

        $out = ['content' => $obj['content'], 'type' => $kind];
        if (!empty($obj['provenance'])) {
            $out['provenance'] = array_values((array) $obj['provenance']);
        }

        return $out;
    }

    /**
     * Read stored objects back from a space (this is the content reader).
     *
     * {@code $query} is a case-insensitive *substring* filter over content (not
     * semantic search); {@code $limit} caps the count (0 = server default). This
     * is distinct from {@code noetic.query}, a geometric divergence probe.
     *
     * @throws AcnTransportError|AcnToolError
     */
    public function fetch(string $spaceId, string $query = '', int $limit = 0): FetchResult
    {
        $args = [
            'sessionId' => $this->requireSession(),
            'space' => $spaceId,
        ];
        if ($query !== '') {
            $args['query'] = $query;
        }
        if ($limit !== 0) {
            $args['limit'] = $limit;
        }

        return FetchResult::fromData($this->call('noetic.fetch', $args), $spaceId);
    }

    // -- sharing ----------------------------------------------------------- //

    /**
     * Grant another agent scoped access to a space you own.
     *
     * {@code $rights} are content rights ({@code read}/{@code write}/{@code quote}/
     * {@code share}/{@code export}/...). {@code $worldMutation} is the separate
     * mutation ladder ({@code read}/{@code propose}/{@code mutate}); leave it
     * {@code null} and the server derives it from the rights (granting
     * {@code write} confers {@code mutate}).
     *
     * @param string       $subjectPrincipal The grantee's agentId.
     * @param list<string> $rights
     * @throws AcnTransportError|AcnToolError
     */
    public function grantAccess(
        string $spaceId,
        string $subjectPrincipal,
        array $rights = ['read', 'quote'],
        ?string $worldMutation = null,
        ?string $persistenceMode = null,
    ): GrantResult {
        // The server names the space argument `resource` (not `space`). `space`
        // is sent too as a harmless alias for older builds; unknown fields are
        // ignored server-side.
        $args = [
            'sessionId' => $this->requireSession(),
            'subjectPrincipal' => $subjectPrincipal,
            'resource' => $spaceId,
            'space' => $spaceId,
            'rights' => array_values($rights),
        ];
        if ($worldMutation !== null) {
            $args['worldMutation'] = $worldMutation;
        }
        if ($persistenceMode !== null) {
            $args['persistenceMode'] = $persistenceMode;
        }

        return GrantResult::fromData($this->call('noetic.grant', $args));
    }

    /**
     * Revoke a previously granted capability (immediate, forward-only).
     *
     * @return array<string, mixed>
     * @throws AcnTransportError|AcnToolError
     */
    public function revokeAccess(string $capabilityRef): array
    {
        return $this->call('noetic.revoke', [
            'sessionId' => $this->requireSession(),
            'capabilityRef' => $capabilityRef,
        ]);
    }

    /**
     * Ask the owner of a remote space for scoped access (consumer side).
     *
     * @param list<string> $rights The requested rights (the arg key is {@code rights}, not {@code requestedRights}).
     * @return array<string, mixed>
     * @throws AcnTransportError|AcnToolError
     */
    public function requestAccess(
        string $spaceId,
        array $rights,
        ?string $persistenceMode = null,
        string $reason = '',
    ): array {
        $args = [
            'sessionId' => $this->requireSession(),
            'space' => $spaceId,
            'rights' => array_values($rights),
        ];
        if ($persistenceMode !== null) {
            $args['persistenceMode'] = $persistenceMode;
        }
        if ($reason !== '') {
            $args['reason'] = $reason;
        }

        return $this->call('noetic.request_access', $args);
    }

    /**
     * List pending access requests on spaces you own (owner side).
     *
     * @return list<array<string, mixed>>
     * @throws AcnTransportError|AcnToolError
     */
    public function listRequests(): array
    {
        $data = $this->call('noetic.list_requests', ['sessionId' => $this->requireSession()]);

        return array_values((array) ($data['requests'] ?? []));
    }

    /**
     * Approve a pending access request, minting the grant (owner side).
     *
     * @param list<string>|null $rights
     * @throws AcnTransportError|AcnToolError
     */
    public function approveRequest(
        string $requestId,
        ?array $rights = null,
        ?string $worldMutation = null,
        ?string $persistenceMode = null,
    ): GrantResult {
        $args = [
            'sessionId' => $this->requireSession(),
            'requestId' => $requestId,
        ];
        if ($rights !== null) {
            $args['rights'] = array_values($rights);
        }
        if ($worldMutation !== null) {
            $args['worldMutation'] = $worldMutation;
        }
        if ($persistenceMode !== null) {
            $args['persistenceMode'] = $persistenceMode;
        }

        return GrantResult::fromData($this->call('noetic.approve_request', $args));
    }

    /**
     * Deny a pending access request (owner side).
     *
     * @return array<string, mixed>
     * @throws AcnTransportError|AcnToolError
     */
    public function denyRequest(string $requestId): array
    {
        return $this->call('noetic.deny_request', [
            'sessionId' => $this->requireSession(),
            'requestId' => $requestId,
        ]);
    }

    // -- discovery + introspection ---------------------------------------- //

    /**
     * List publicly discoverable spaces (no session required).
     *
     * @return list<array<string, mixed>>
     * @throws AcnTransportError|AcnToolError
     */
    public function discover(string $query = '', int $limit = 0): array
    {
        $args = [];
        if ($query !== '') {
            $args['query'] = $query;
        }
        if ($limit !== 0) {
            $args['limit'] = $limit;
        }

        $data = $this->call('noetic.discover', $args);

        return array_values((array) ($data['spaces'] ?? []));
    }

    /**
     * Set a space's discovery visibility.
     *
     * @return array<string, mixed>
     * @throws AcnTransportError|AcnToolError
     */
    public function publish(string $spaceId, string $visibility = 'public'): array
    {
        return $this->call('noetic.publish', [
            'sessionId' => $this->requireSession(),
            'space' => $spaceId,
            'visibility' => $visibility,
        ]);
    }

    /**
     * Return scope/account/space usage metrics for the session.
     *
     * @return array<string, mixed>
     * @throws AcnTransportError|AcnToolError
     */
    public function metrics(): array
    {
        return $this->call('noetic.metrics', ['sessionId' => $this->requireSession()]);
    }

    // -- transport --------------------------------------------------------- //

    /**
     * Invoke any {@code noetic.*} tool and return its unwrapped {@code data}.
     *
     * This is the low-level escape hatch behind every typed method — use it to
     * reach tools this client does not wrap explicitly. It performs the full
     * round trip: builds the JSON-RPC {@code tools/call} envelope, unwraps
     * {@code result.content[0].text}, and throws {@see AcnToolError} (or a
     * subclass) when the tool returns {@code ok: false}.
     *
     * @param array<string, mixed> $arguments
     * @return array<string, mixed> The unwrapped envelope {@code data} object
     *                              (a payload-less {@code ok} is returned as
     *                              {@code ['data' => null]}).
     * @throws AcnTransportError|AcnToolError
     */
    public function call(string $method, array $arguments): array
    {
        // An empty argument map must serialize as a JSON object `{}`, not `[]`.
        $payload = [
            'jsonrpc' => '2.0',
            'id' => $this->nextId(),
            'method' => 'tools/call',
            'params' => [
                'name' => $method,
                'arguments' => $arguments === [] ? new \stdClass() : $arguments,
            ],
        ];

        $json = json_encode($payload, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE);
        if ($json === false) {
            throw new AcnTransportError(
                'could not encode request for ' . $method . ': ' . json_last_error_msg(),
                $method,
            );
        }

        [$status, $raw] = $this->transport($method, $json);

        if ($status >= 400) {
            throw new AcnTransportError(
                sprintf('HTTP %d calling %s: %s', $status, $method, $this->truncate($raw, 500)),
                $method,
                null,
                $status,
            );
        }

        $body = json_decode($raw, true);
        if (json_last_error() !== JSON_ERROR_NONE) {
            throw new AcnTransportError(
                sprintf('non-JSON response calling %s: %s', $method, $this->truncate($raw, 500)),
                $method,
            );
        }

        // JSON-RPC protocol error (unknown method, bad params) — no result.
        if (is_array($body) && !empty($body['error'])) {
            $err = $body['error'];
            $message = is_array($err)
                ? (string) ($err['message'] ?? json_encode($err))
                : (string) $err;
            $code = (is_array($err) && isset($err['code'])) ? (int) $err['code'] : null;
            throw new AcnTransportError(
                sprintf('JSON-RPC error calling %s: %s', $method, $message),
                $method,
                $code,
            );
        }

        $result = (is_array($body) && isset($body['result']) && is_array($body['result']))
            ? $body['result']
            : null;
        if ($result === null) {
            throw new AcnTransportError(
                sprintf('malformed response calling %s: %s', $method, $this->truncate($raw, 500)),
                $method,
            );
        }

        $envelope = $this->unwrap($result, $method);

        if (empty($envelope['ok'])) {
            throw AcnToolError::forOutcome(
                (string) ($envelope['outcome'] ?? ''),
                (string) ($envelope['detail'] ?? ''),
                $method,
                $envelope['data'] ?? null,
            );
        }

        // `data` is optional (some tools return ok with no payload).
        $data = $envelope['data'] ?? null;

        return is_array($data) ? $data : ['data' => $data];
    }

    /**
     * Perform the HTTP round trip with retries, returning {@code [status, body]}.
     *
     * Retries are deliberately narrow: only connection-level faults (the request
     * never reached the server) and explicit back-pressure statuses (429, 503,
     * emitted before the server does work) are retried. A read timeout is *not*
     * retried, so a non-idempotent call such as {@code store} is never silently
     * duplicated.
     *
     * @return array{0: int, 1: string}
     * @throws AcnTransportError
     */
    private function transport(string $method, string $json): array
    {
        if ($this->curl === null) {
            throw new AcnTransportError('client is closed', $method);
        }

        $attempt = 0;
        while (true) {
            $this->responseHeaders = [];
            curl_setopt($this->curl, CURLOPT_POSTFIELDS, $json);

            $raw = curl_exec($this->curl);
            $errno = curl_errno($this->curl);

            if ($errno !== 0) {
                if ($attempt < $this->maxRetries && $this->isRetryableConnError($errno)) {
                    $this->sleepBackoff($attempt, null);
                    ++$attempt;
                    continue;
                }
                throw new AcnTransportError(
                    sprintf('network error calling %s: %s', $method, curl_error($this->curl)),
                    $method,
                );
            }

            $status = (int) curl_getinfo($this->curl, CURLINFO_RESPONSE_CODE);
            if (($status === 429 || $status === 503) && $attempt < $this->maxRetries) {
                $this->sleepBackoff($attempt, $this->retryAfterSeconds());
                ++$attempt;
                continue;
            }

            return [$status, is_string($raw) ? $raw : ''];
        }
    }

    /**
     * Parse the MCP {@code content[0].text} JSON envelope out of a result.
     *
     * @param array<string, mixed> $result
     * @return array<string, mixed>
     * @throws AcnTransportError
     */
    private function unwrap(array $result, string $method): array
    {
        $content = $result['content'] ?? null;
        if (!is_array($content) || $content === []) {
            throw new AcnTransportError("response for {$method} had no content block", $method);
        }

        $first = $content[0] ?? null;
        $text = is_array($first) ? ($first['text'] ?? null) : null;
        if (!is_string($text)) {
            throw new AcnTransportError("response for {$method} had no text payload", $method);
        }

        $envelope = json_decode($text, true);
        if (json_last_error() !== JSON_ERROR_NONE) {
            throw new AcnTransportError(
                sprintf('could not decode envelope for %s: %s', $method, $this->truncate($text, 300)),
                $method,
            );
        }
        // Must be a JSON object; a non-empty list is rejected. (An empty `{}`
        // decodes to `[]` and is allowed through — it simply lacks `ok`.)
        if (!is_array($envelope) || (array_is_list($envelope) && $envelope !== [])) {
            throw new AcnTransportError("envelope for {$method} was not an object", $method);
        }

        return $envelope;
    }

    private function requireSession(): string
    {
        if ($this->sessionId === null || $this->sessionId === '') {
            throw new AcnTransportError('no active session: call connect() first');
        }

        return $this->sessionId;
    }

    private function nextId(): int
    {
        return $this->nextId++;
    }

    private function isRetryableConnError(int $errno): bool
    {
        return in_array($errno, [
            CURLE_COULDNT_CONNECT,
            CURLE_COULDNT_RESOLVE_HOST,
            CURLE_COULDNT_RESOLVE_PROXY,
        ], true);
    }

    private function sleepBackoff(int $attempt, ?float $retryAfter): void
    {
        $delay = $retryAfter ?? ($this->backoffFactor * (2 ** $attempt));
        if ($delay > 0) {
            usleep((int) round($delay * 1_000_000));
        }
    }

    /** Seconds to wait per a {@code Retry-After} header, if present and future. */
    private function retryAfterSeconds(): ?float
    {
        $value = $this->responseHeaders['retry-after'] ?? null;
        if ($value === null) {
            return null;
        }
        if (is_numeric($value)) {
            return (float) $value;
        }
        $ts = strtotime($value);
        if ($ts === false) {
            return null;
        }
        $delta = $ts - time();

        return $delta > 0 ? (float) $delta : null;
    }

    private function makeHandle(): \CurlHandle
    {
        $curl = curl_init();
        if ($curl === false) {
            throw new \RuntimeException('failed to initialize a cURL handle');
        }

        curl_setopt_array($curl, [
            CURLOPT_URL => $this->endpoint,
            CURLOPT_POST => true,
            CURLOPT_RETURNTRANSFER => true,
            CURLOPT_HTTPHEADER => [
                'Content-Type: application/json',
                // Ask for a plain JSON reply; the Streamable-HTTP endpoint would
                // otherwise be free to answer a POST as a one-shot SSE frame.
                'Accept: application/json',
                'User-Agent: priostack-php/' . self::VERSION,
            ],
            CURLOPT_CONNECTTIMEOUT_MS => (int) round($this->timeout * 1000),
            CURLOPT_TIMEOUT_MS => (int) round($this->timeout * 1000),
            // Capture response headers (for Retry-After) without polluting the body.
            CURLOPT_HEADERFUNCTION => function ($handle, string $header): int {
                $len = strlen($header);
                $pos = strpos($header, ':');
                if ($pos !== false) {
                    $name = strtolower(trim(substr($header, 0, $pos)));
                    $this->responseHeaders[$name] = trim(substr($header, $pos + 1));
                }

                return $len;
            },
        ]);

        return $curl;
    }

    private function truncate(string $s, int $n): string
    {
        return strlen($s) > $n ? substr($s, 0, $n) : $s;
    }

    /**
     * @param mixed $value
     */
    private function describe($value): string
    {
        $json = json_encode($value, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE);

        return $this->truncate($json === false ? gettype($value) : $json, 300);
    }
}
