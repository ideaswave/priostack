using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;

namespace Priostack.Acn;

/// <summary>
/// A sturdy JSON-RPC 2.0 client for the Priostack Agent Context Network (ACN).
/// </summary>
/// <remarks>
/// <para>
/// The ACN is a Model Context Protocol (MCP) server. An agent self-registers,
/// opens a session with the returned bearer token, creates isolated context
/// spaces, stores typed facts, reads them back, and shares them with other
/// agents through scoped capability grants.
/// </para>
/// <para>
/// This client speaks the exact wire contract of the live server: it unwraps
/// the MCP <c>result.content[0].text</c> envelope, throws typed exceptions on
/// tool-level denials, reuses one pooled <see cref="HttpClient"/>, and captures
/// the session id automatically on <see cref="ConnectAsync"/>.
/// </para>
/// <para>
/// Instances are safe to share across concurrent calls: the JSON-RPC id is
/// assigned atomically and no per-call state is mutated on the shared client
/// beyond <see cref="Token"/> and <see cref="SessionId"/>, which the identity
/// methods set.
/// </para>
/// <example>
/// <code>
/// await using var acn = new AcnClient();
/// await acn.RegisterAsync("my-agent");        // token captured internally
/// var conn = await acn.ConnectAsync();        // session id captured internally
/// var space = await acn.CreateSpaceAsync("prod-memory");
/// await acn.StoreAsync(space.SpaceId, new[]
/// {
///     new StoreObject("Refunds over $500 need manager approval.", "declaration"),
/// });
/// var hits = await acn.FetchAsync(space.SpaceId, query: "refund");
/// foreach (var content in hits.Contents()) Console.WriteLine(content);
/// </code>
/// </example>
/// </remarks>
public sealed class AcnClient : IDisposable, IAsyncDisposable
{
    /// <summary>Canonical MCP endpoint (Streamable HTTP). <c>/acn/rpc</c> is a working alias.</summary>
    public const string DefaultEndpoint = "https://priostack.com/mcp";

    /// <summary>
    /// Object <c>type</c> values the <see cref="StoreAsync"/> tool accepts.
    /// Anything else is rejected client-side before the request is sent.
    /// </summary>
    public static readonly IReadOnlyList<string> StoreKinds =
        new[] { "declaration", "observation", "measurement" };

    private const string ClientUserAgent = "priostack-dotnet/0.3.0";

    // General defaults, but keep content/non-ASCII literal on the wire rather
    // than escaping it (the server decodes standard JSON either way).
    private static readonly JsonSerializerOptions RequestJson =
        new(JsonSerializerDefaults.General)
        {
            Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
        };

    private readonly HttpClient _http;
    private readonly bool _ownsHttp;
    private readonly TimeSpan _timeout;
    private readonly int _maxBackpressureRetries;
    private readonly TimeSpan _backoffBase;
    private long _idCounter;

    /// <summary>The RPC endpoint this client posts to.</summary>
    public string Endpoint { get; }

    /// <summary>The bearer token captured by <see cref="RegisterAsync"/> / passed to the constructor.</summary>
    public string? Token { get; private set; }

    /// <summary>The session id captured by <see cref="ConnectAsync"/>, or <c>null</c> if not connected.</summary>
    public string? SessionId { get; private set; }

    /// <summary>Whether a session id has been captured.</summary>
    public bool Connected => !string.IsNullOrEmpty(SessionId);

    /// <summary>Creates a client.</summary>
    /// <param name="endpoint">Base RPC URL; defaults to <see cref="DefaultEndpoint"/>.</param>
    /// <param name="token">A previously issued bearer token, to reconnect an existing agent without registering again.</param>
    /// <param name="timeout">Per-request timeout applied to every call (default 30s).</param>
    /// <param name="httpClient">
    /// Inject a pre-built <see cref="HttpClient"/> (custom handler, proxy, TLS).
    /// When supplied it is neither reconfigured nor disposed by this client.
    /// When omitted, one is created, pooled, and disposed on <see cref="Dispose"/>.
    /// </param>
    /// <param name="maxBackpressureRetries">
    /// How many times to retry a <c>429</c>/<c>503</c> back-pressure response.
    /// These are emitted before the server acts, so retrying is safe. Read
    /// timeouts and network faults are never retried, so a non-idempotent call
    /// such as <see cref="StoreAsync"/> is never silently duplicated.
    /// </param>
    /// <param name="backoffBase">Exponential backoff base between back-pressure retries (default 0.5s).</param>
    public AcnClient(
        string endpoint = DefaultEndpoint,
        string? token = null,
        TimeSpan? timeout = null,
        HttpClient? httpClient = null,
        int maxBackpressureRetries = 3,
        TimeSpan? backoffBase = null)
    {
        if (string.IsNullOrWhiteSpace(endpoint))
            throw new ArgumentException("endpoint must be a non-empty URL", nameof(endpoint));

        Endpoint = endpoint;
        Token = token;
        _timeout = timeout ?? TimeSpan.FromSeconds(30);
        _maxBackpressureRetries = Math.Max(0, maxBackpressureRetries);
        _backoffBase = backoffBase ?? TimeSpan.FromMilliseconds(500);

        _ownsHttp = httpClient is null;
        _http = httpClient ?? new HttpClient();
        if (_ownsHttp)
        {
            // The real per-call deadline is enforced via a linked CTS below, so
            // disable the client-wide timeout to avoid a second, conflicting one.
            _http.Timeout = Timeout.InfiniteTimeSpan;
        }
    }

    // ---------------------------------------------------------------- transport

    /// <summary>
    /// Invokes any <c>noetic.*</c> tool and returns its unwrapped <c>data</c>
    /// element (always a JSON object; a non-object payload is wrapped as
    /// <c>{"data": ...}</c>, and an absent payload becomes <c>{}</c>).
    /// </summary>
    /// <remarks>
    /// This is the low-level escape hatch behind every typed method — use it to
    /// reach tools this client does not wrap explicitly. It performs the full
    /// round trip: builds the JSON-RPC <c>tools/call</c> envelope, unwraps
    /// <c>result.content[0].text</c>, and throws <see cref="AcnToolException"/>
    /// (or a subclass) when the tool returns <c>ok: false</c>, or
    /// <see cref="AcnTransportException"/> on any protocol/transport failure.
    /// </remarks>
    /// <returns>The tool's <c>data</c> object, detached from the response document.</returns>
    public async Task<JsonElement> CallAsync(
        string method,
        IReadOnlyDictionary<string, object?> arguments,
        CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrEmpty(method))
            throw new ArgumentException("method must be a non-empty tool name", nameof(method));
        ArgumentNullException.ThrowIfNull(arguments);

        long id = Interlocked.Increment(ref _idCounter);
        var payload = new Dictionary<string, object?>
        {
            ["jsonrpc"] = "2.0",
            ["id"] = id,
            ["method"] = "tools/call",
            ["params"] = new Dictionary<string, object?>
            {
                ["name"] = method,
                ["arguments"] = arguments,
            },
        };
        string requestBody = JsonSerializer.Serialize(payload, RequestJson);

        (int status, string responseBody) = await ExchangeAsync(requestBody, method, cancellationToken)
            .ConfigureAwait(false);

        if (status >= 400)
        {
            throw new AcnTransportException(
                $"HTTP {status} calling {method}: {Truncate(responseBody, 500)}",
                method,
                httpStatus: status);
        }

        return ProcessResponse(responseBody, method);
    }

    private async Task<(int Status, string Body)> ExchangeAsync(
        string requestBody, string method, CancellationToken cancellationToken)
    {
        for (int attempt = 0; ; attempt++)
        {
            using var timeoutCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            timeoutCts.CancelAfter(_timeout);

            HttpResponseMessage response;
            try
            {
                using var request = new HttpRequestMessage(HttpMethod.Post, Endpoint)
                {
                    Content = new StringContent(requestBody, Encoding.UTF8, "application/json"),
                };
                // Ask for a plain JSON reply; the Streamable-HTTP endpoint would
                // otherwise be free to answer a POST as a one-shot SSE frame.
                request.Headers.Accept.ParseAdd("application/json");
                request.Headers.UserAgent.ParseAdd(ClientUserAgent);

                response = await _http.SendAsync(request, timeoutCts.Token).ConfigureAwait(false);
            }
            catch (OperationCanceledException ex) when (!cancellationToken.IsCancellationRequested)
            {
                throw new AcnTransportException(
                    $"timed out after {_timeout.TotalSeconds:0.#}s calling {method}",
                    method, innerException: ex);
            }
            catch (HttpRequestException ex)
            {
                throw new AcnTransportException(
                    $"network error calling {method}: {ex.Message}", method, innerException: ex);
            }

            using (response)
            {
                int status = (int)response.StatusCode;

                // 429/503 are back-pressure signals the server emits before doing
                // any work, so they are safe to retry.
                if ((status == 429 || status == 503) && attempt < _maxBackpressureRetries)
                {
                    TimeSpan delay = RetryDelay(response, attempt);
                    await Task.Delay(delay, cancellationToken).ConfigureAwait(false);
                    continue;
                }

                try
                {
                    string body = await response.Content
                        .ReadAsStringAsync(timeoutCts.Token).ConfigureAwait(false);
                    return (status, body);
                }
                catch (OperationCanceledException ex) when (!cancellationToken.IsCancellationRequested)
                {
                    throw new AcnTransportException(
                        $"timed out reading response for {method}", method, innerException: ex);
                }
                catch (HttpRequestException ex)
                {
                    throw new AcnTransportException(
                        $"network error reading response for {method}: {ex.Message}",
                        method, innerException: ex);
                }
            }
        }
    }

    private TimeSpan RetryDelay(HttpResponseMessage response, int attempt)
    {
        var retryAfter = response.Headers.RetryAfter;
        if (retryAfter is not null)
        {
            if (retryAfter.Delta is TimeSpan delta && delta > TimeSpan.Zero)
                return delta;
            if (retryAfter.Date is DateTimeOffset when)
            {
                var diff = when - DateTimeOffset.UtcNow;
                if (diff > TimeSpan.Zero)
                    return diff;
            }
        }
        double seconds = _backoffBase.TotalSeconds * Math.Pow(2, attempt);
        return TimeSpan.FromSeconds(seconds);
    }

    private static JsonElement ProcessResponse(string responseBody, string method)
    {
        JsonDocument doc;
        try
        {
            doc = JsonDocument.Parse(responseBody);
        }
        catch (JsonException ex)
        {
            throw new AcnTransportException(
                $"non-JSON response calling {method}: {Truncate(responseBody, 500)}",
                method, innerException: ex);
        }

        using (doc)
        {
            JsonElement root = doc.RootElement;
            if (root.ValueKind != JsonValueKind.Object)
            {
                throw new AcnTransportException(
                    $"malformed response calling {method}: {Truncate(responseBody, 500)}", method);
            }

            // JSON-RPC protocol error (unknown method, bad params) — no result.
            if (root.TryGetProperty("error", out var errorElement) &&
                errorElement.ValueKind == JsonValueKind.Object)
            {
                string message =
                    errorElement.TryGetProperty("message", out var m) && m.ValueKind == JsonValueKind.String
                        ? m.GetString()!
                        : errorElement.ToString();
                int? code =
                    errorElement.TryGetProperty("code", out var c) &&
                    c.ValueKind == JsonValueKind.Number && c.TryGetInt32(out int ci)
                        ? ci
                        : null;
                throw new AcnTransportException(
                    $"JSON-RPC error calling {method}: {message}", method, code: code);
            }

            if (!root.TryGetProperty("result", out var result) ||
                result.ValueKind != JsonValueKind.Object)
            {
                throw new AcnTransportException(
                    $"malformed response calling {method}: {Truncate(responseBody, 500)}", method);
            }

            using JsonDocument envelopeDoc = UnwrapEnvelope(result, method);
            JsonElement envelope = envelopeDoc.RootElement;
            if (envelope.ValueKind != JsonValueKind.Object)
            {
                throw new AcnTransportException(
                    $"envelope for {method} was not an object", method);
            }

            bool ok = envelope.TryGetProperty("ok", out var okElement) &&
                      okElement.ValueKind == JsonValueKind.True;
            if (!ok)
            {
                string outcome = GetString(envelope, "outcome");
                string detail = GetString(envelope, "detail");
                JsonElement? failureData =
                    envelope.TryGetProperty("data", out var d) ? d.Clone() : null;
                throw AcnToolException.ForOutcome(outcome, detail, method, failureData);
            }

            return NormalizeData(envelope);
        }
    }

    /// <summary>Parses the MCP <c>content[0].text</c> JSON envelope out of a result.</summary>
    private static JsonDocument UnwrapEnvelope(JsonElement result, string method)
    {
        if (!result.TryGetProperty("content", out var content) ||
            content.ValueKind != JsonValueKind.Array ||
            content.GetArrayLength() == 0)
        {
            throw new AcnTransportException($"response for {method} had no content block", method);
        }

        JsonElement first = content[0];
        if (first.ValueKind != JsonValueKind.Object ||
            !first.TryGetProperty("text", out var textElement) ||
            textElement.ValueKind != JsonValueKind.String)
        {
            throw new AcnTransportException($"response for {method} had no text payload", method);
        }

        string text = textElement.GetString()!;
        try
        {
            return JsonDocument.Parse(text);
        }
        catch (JsonException ex)
        {
            throw new AcnTransportException(
                $"could not decode envelope for {method}: {Truncate(text, 300)}",
                method, innerException: ex);
        }
    }

    /// <summary>
    /// Returns the envelope's <c>data</c> as a detached object element. A
    /// non-object payload is wrapped as <c>{"data": ...}</c> (mirroring the
    /// reference client); an absent payload becomes an empty object.
    /// </summary>
    private static JsonElement NormalizeData(JsonElement envelope)
    {
        if (envelope.TryGetProperty("data", out var data) && data.ValueKind != JsonValueKind.Null)
        {
            if (data.ValueKind == JsonValueKind.Object)
                return data.Clone();

            return JsonSerializer.SerializeToElement(
                new Dictionary<string, JsonElement> { ["data"] = data });
        }
        return JsonSerializer.SerializeToElement(new Dictionary<string, object?>());
    }

    private string RequireSession()
    {
        if (string.IsNullOrEmpty(SessionId))
            throw new AcnTransportException("no active session: call ConnectAsync() first");
        return SessionId;
    }

    // ------------------------------------------------------------------ identity

    /// <summary>
    /// Self-registers a new agent and captures its bearer token. Only available
    /// on the online multi-agent ACN; a single-tenant deployment throws
    /// <see cref="AcnNotSupportedException"/>. The token is shown once, stored on
    /// this client (<see cref="Token"/>), and returned so you can persist it.
    /// </summary>
    public async Task<RegisterResult> RegisterAsync(
        string displayName = "agent", CancellationToken cancellationToken = default)
    {
        var data = await CallAsync(
            "noetic.register",
            new Dictionary<string, object?> { ["displayName"] = displayName },
            cancellationToken).ConfigureAwait(false);

        string token = GetString(data, "token");
        if (string.IsNullOrEmpty(token))
            throw new AcnTransportException("register returned no token", "noetic.register");

        Token = token;
        return new RegisterResult(
            token,
            GetString(data, "agentId"),
            GetString(data, "accountId"),
            GetString(data, "tier"),
            data);
    }

    /// <summary>
    /// Opens a session with a bearer token and captures the session id.
    /// Re-call after being granted access to a space so the widened scope
    /// applies.
    /// </summary>
    /// <param name="token">Explicit token; otherwise the captured/constructor token is used.</param>
    /// <param name="maxTokens">Ceiling on server response size for this session.</param>
    /// <param name="cancellationToken">Token to cancel the request.</param>
    public async Task<ConnectResult> ConnectAsync(
        string? token = null, int maxTokens = 4096, CancellationToken cancellationToken = default)
    {
        string? tok = token ?? Token;
        if (string.IsNullOrEmpty(tok))
        {
            throw new AcnTransportException(
                "connect needs a token: call RegisterAsync() first or pass a token");
        }

        var data = await CallAsync(
            "noetic.connect",
            new Dictionary<string, object?> { ["token"] = tok, ["maxResponseTokens"] = maxTokens },
            cancellationToken).ConfigureAwait(false);

        // The server serializes ConnectResult with Go field names (PascalCase);
        // read them exactly. Every OTHER tool uses lowercase keys.
        string sessionId = GetString(data, "SessionID");
        if (string.IsNullOrEmpty(sessionId))
        {
            throw new AcnTransportException(
                $"connect returned no SessionID: {data}", "noetic.connect");
        }

        SessionId = sessionId;
        Token = tok;
        return new ConnectResult(
            sessionId,
            GetString(data, "ResolvedAccount"),
            GetStringList(data, "GrantedCapabilities"),
            GetStringList(data, "GrantedContextRights"),
            GetString(data, "BoundSpace"),
            GetInt64(data, "ResolvedMaxTokens"),
            data);
    }

    /// <summary>Ends the current session. Durable facts are <b>not</b> revoked.</summary>
    public async Task<JsonElement> DisconnectAsync(CancellationToken cancellationToken = default)
    {
        string sid = RequireSession();
        var data = await CallAsync(
            "noetic.disconnect",
            new Dictionary<string, object?> { ["sessionId"] = sid },
            cancellationToken).ConfigureAwait(false);
        SessionId = null;
        return data;
    }

    /// <summary>
    /// Mints a fresh bearer token for this agent and retires the old one.
    /// Existing sessions keep working; use the new token for future connects.
    /// The new token is stored on this client and returned.
    /// </summary>
    public async Task<string> RotateTokenAsync(CancellationToken cancellationToken = default)
    {
        string sid = RequireSession();
        var data = await CallAsync(
            "noetic.rotate_token",
            new Dictionary<string, object?> { ["sessionId"] = sid },
            cancellationToken).ConfigureAwait(false);

        string token = GetString(data, "token");
        if (string.IsNullOrEmpty(token))
            throw new AcnTransportException("rotate_token returned no token", "noetic.rotate_token");

        Token = token;
        return token;
    }

    /// <summary>Discovers the grantable rights and world-mutation vocabulary in scope.</summary>
    public async Task<JsonElement> CapabilitiesAsync(CancellationToken cancellationToken = default)
    {
        string sid = RequireSession();
        return await CallAsync(
            "noetic.capabilities",
            new Dictionary<string, object?> { ["sessionId"] = sid },
            cancellationToken).ConfigureAwait(false);
    }

    // -------------------------------------------------------------- spaces + facts

    /// <summary>
    /// Creates an isolated context space and returns its resolved id (use that
    /// id for writes). <paramref name="defaultRights"/> is the ceiling of rights
    /// the space may offer to others; it does not grant anything by itself.
    /// </summary>
    public async Task<SpaceResult> CreateSpaceAsync(
        string displayName,
        IEnumerable<string>? defaultRights = null,
        string? visibility = null,
        string? persistenceMode = null,
        string? protectionLevel = null,
        CancellationToken cancellationToken = default)
    {
        string sid = RequireSession();
        var args = new Dictionary<string, object?>
        {
            ["sessionId"] = sid,
            ["displayName"] = displayName,
        };
        if (defaultRights is not null) args["defaultRights"] = defaultRights.ToList();
        if (visibility is not null) args["visibility"] = visibility;
        if (persistenceMode is not null) args["persistenceMode"] = persistenceMode;
        if (protectionLevel is not null) args["protectionLevel"] = protectionLevel;

        var data = await CallAsync("noetic.create_space", args, cancellationToken).ConfigureAwait(false);

        string spaceId = GetString(data, "spaceId");
        if (string.IsNullOrEmpty(spaceId))
            throw new AcnTransportException("create_space returned no spaceId", "noetic.create_space");

        return new SpaceResult(
            spaceId,
            GetString(data, "accountId"),
            GetString(data, "persistenceMode"),
            GetString(data, "protectionLevel"),
            data);
    }

    /// <summary>
    /// Persists typed facts into a space. Each object's <see cref="StoreObject.Type"/>
    /// must be one of <see cref="StoreKinds"/>. Writing needs the write right and
    /// the <c>mutate</c> capability; the space owner has both.
    /// </summary>
    public async Task<StoreResult> StoreAsync(
        string spaceId,
        IEnumerable<StoreObject> objects,
        CancellationToken cancellationToken = default)
    {
        string sid = RequireSession();
        ArgumentNullException.ThrowIfNull(objects);

        var normalized = new List<Dictionary<string, object?>>();
        foreach (var obj in objects)
            normalized.Add(NormalizeObject(obj));
        if (normalized.Count == 0)
            throw new ArgumentException("store needs at least one object", nameof(objects));

        var data = await CallAsync(
            "noetic.store",
            new Dictionary<string, object?>
            {
                ["sessionId"] = sid,
                ["space"] = spaceId,       // the store tool names the space arg "space"
                ["objects"] = normalized,
            },
            cancellationToken).ConfigureAwait(false);

        return new StoreResult(GetElementList(data, "objectRefs"), data);
    }

    private static Dictionary<string, object?> NormalizeObject(StoreObject obj)
    {
        ArgumentNullException.ThrowIfNull(obj);
        if (string.IsNullOrEmpty(obj.Content))
            throw new ArgumentException("each stored object needs a non-empty Content");

        string kind = string.IsNullOrEmpty(obj.Type) ? "declaration" : obj.Type;
        if (!StoreKinds.Contains(kind))
        {
            throw new ArgumentException(
                $"invalid object type '{kind}'; must be one of {string.Join(", ", StoreKinds)}");
        }

        var result = new Dictionary<string, object?> { ["content"] = obj.Content, ["type"] = kind };
        if (obj.Provenance is { Count: > 0 })
            result["provenance"] = obj.Provenance.ToList();
        return result;
    }

    /// <summary>
    /// Reads stored objects back from a space (the content reader).
    /// <paramref name="query"/> is a case-insensitive <b>substring</b> filter
    /// over content (not semantic search); <paramref name="limit"/> caps the
    /// count (0 = server default). Distinct from <c>noetic.query</c>, which is a
    /// geometric divergence probe.
    /// </summary>
    public async Task<FetchResult> FetchAsync(
        string spaceId,
        string query = "",
        int limit = 0,
        CancellationToken cancellationToken = default)
    {
        string sid = RequireSession();
        var args = new Dictionary<string, object?>
        {
            ["sessionId"] = sid,
            ["space"] = spaceId,
        };
        if (!string.IsNullOrEmpty(query)) args["query"] = query;
        if (limit != 0) args["limit"] = limit;

        var data = await CallAsync("noetic.fetch", args, cancellationToken).ConfigureAwait(false);

        var objects = new List<FetchedObject>();
        if (data.TryGetProperty("objects", out var arr) && arr.ValueKind == JsonValueKind.Array)
        {
            foreach (var item in arr.EnumerateArray())
            {
                objects.Add(new FetchedObject(
                    GetString(item, "objectRef"),
                    GetString(item, "kind"),
                    GetString(item, "content"),
                    GetInt64(item, "tokens"),
                    item.Clone()));
            }
        }

        return new FetchResult(
            GetString(data, "space", spaceId),
            objects,
            GetInt64(data, "matched"),
            GetInt64(data, "total"),
            GetInt64(data, "returnedTokens"),
            data);
    }

    // --------------------------------------------------------------------- sharing

    /// <summary>
    /// Grants another agent scoped access to a space you own.
    /// <paramref name="subjectPrincipal"/> is the grantee's agent id.
    /// <paramref name="rights"/> are content rights (read/write/quote/share/...);
    /// <paramref name="worldMutation"/> is the separate mutation ladder
    /// (read/propose/mutate) — leave it <c>null</c> and the server derives it
    /// from the rights (granting <c>write</c> confers <c>mutate</c>).
    /// </summary>
    public async Task<GrantResult> GrantAccessAsync(
        string spaceId,
        string subjectPrincipal,
        IEnumerable<string>? rights = null,
        string? worldMutation = null,
        string? persistenceMode = null,
        CancellationToken cancellationToken = default)
    {
        string sid = RequireSession();
        var rightsList = (rights ?? new[] { "read", "quote" }).ToList();

        var args = new Dictionary<string, object?>
        {
            ["sessionId"] = sid,
            ["subjectPrincipal"] = subjectPrincipal,
            // The grant tool names the space argument "resource". "space" is sent
            // too as a harmless alias for older builds; unknown fields are ignored.
            ["resource"] = spaceId,
            ["space"] = spaceId,
            ["rights"] = rightsList,
        };
        if (worldMutation is not null) args["worldMutation"] = worldMutation;
        if (persistenceMode is not null) args["persistenceMode"] = persistenceMode;

        var data = await CallAsync("noetic.grant", args, cancellationToken).ConfigureAwait(false);
        return GrantResultFrom(data);
    }

    /// <summary>Revokes a previously granted capability (immediate, forward-only).</summary>
    public async Task<JsonElement> RevokeAccessAsync(
        string capabilityRef, CancellationToken cancellationToken = default)
    {
        string sid = RequireSession();
        return await CallAsync(
            "noetic.revoke",
            new Dictionary<string, object?> { ["sessionId"] = sid, ["capabilityRef"] = capabilityRef },
            cancellationToken).ConfigureAwait(false);
    }

    /// <summary>Asks the owner of a remote space for scoped access (consumer side).</summary>
    public async Task<JsonElement> RequestAccessAsync(
        string spaceId,
        IEnumerable<string> rights,
        string? persistenceMode = null,
        string reason = "",
        CancellationToken cancellationToken = default)
    {
        string sid = RequireSession();
        ArgumentNullException.ThrowIfNull(rights);

        var args = new Dictionary<string, object?>
        {
            ["sessionId"] = sid,
            ["space"] = spaceId,
            // The server names this argument "rights" (not "requestedRights").
            ["rights"] = rights.ToList(),
        };
        if (persistenceMode is not null) args["persistenceMode"] = persistenceMode;
        if (!string.IsNullOrEmpty(reason)) args["reason"] = reason;

        return await CallAsync("noetic.request_access", args, cancellationToken).ConfigureAwait(false);
    }

    /// <summary>Lists pending access requests on spaces you own (owner side).</summary>
    public async Task<IReadOnlyList<JsonElement>> ListRequestsAsync(
        CancellationToken cancellationToken = default)
    {
        string sid = RequireSession();
        var data = await CallAsync(
            "noetic.list_requests",
            new Dictionary<string, object?> { ["sessionId"] = sid },
            cancellationToken).ConfigureAwait(false);
        return GetElementList(data, "requests");
    }

    /// <summary>Approves a pending access request, minting the grant (owner side).</summary>
    public async Task<GrantResult> ApproveRequestAsync(
        string requestId,
        IEnumerable<string>? rights = null,
        string? worldMutation = null,
        string? persistenceMode = null,
        CancellationToken cancellationToken = default)
    {
        string sid = RequireSession();
        var args = new Dictionary<string, object?>
        {
            ["sessionId"] = sid,
            ["requestId"] = requestId,
        };
        if (rights is not null) args["rights"] = rights.ToList();
        if (worldMutation is not null) args["worldMutation"] = worldMutation;
        if (persistenceMode is not null) args["persistenceMode"] = persistenceMode;

        var data = await CallAsync("noetic.approve_request", args, cancellationToken).ConfigureAwait(false);
        return GrantResultFrom(data);
    }

    /// <summary>Denies a pending access request (owner side).</summary>
    public async Task<JsonElement> DenyRequestAsync(
        string requestId, CancellationToken cancellationToken = default)
    {
        string sid = RequireSession();
        return await CallAsync(
            "noetic.deny_request",
            new Dictionary<string, object?> { ["sessionId"] = sid, ["requestId"] = requestId },
            cancellationToken).ConfigureAwait(false);
    }

    private static GrantResult GrantResultFrom(JsonElement data)
        => new(
            GetString(data, "capabilityRef"),
            GetString(data, "subject"),
            GetString(data, "resource"),
            GetStringList(data, "effectiveRights"),
            data);

    // ------------------------------------------------------ discovery + introspection

    /// <summary>Lists publicly discoverable spaces (no session required).</summary>
    public async Task<IReadOnlyList<JsonElement>> DiscoverAsync(
        string query = "", int limit = 0, CancellationToken cancellationToken = default)
    {
        var args = new Dictionary<string, object?>();
        if (!string.IsNullOrEmpty(query)) args["query"] = query;
        if (limit != 0) args["limit"] = limit;

        var data = await CallAsync("noetic.discover", args, cancellationToken).ConfigureAwait(false);
        return GetElementList(data, "spaces");
    }

    /// <summary>Sets a space's discovery visibility.</summary>
    public async Task<JsonElement> PublishAsync(
        string spaceId, string visibility = "public", CancellationToken cancellationToken = default)
    {
        string sid = RequireSession();
        return await CallAsync(
            "noetic.publish",
            new Dictionary<string, object?>
            {
                ["sessionId"] = sid,
                ["space"] = spaceId,
                ["visibility"] = visibility,
            },
            cancellationToken).ConfigureAwait(false);
    }

    /// <summary>Returns scope/account/space usage metrics for the session.</summary>
    public async Task<JsonElement> MetricsAsync(CancellationToken cancellationToken = default)
    {
        string sid = RequireSession();
        return await CallAsync(
            "noetic.metrics",
            new Dictionary<string, object?> { ["sessionId"] = sid },
            cancellationToken).ConfigureAwait(false);
    }

    // ------------------------------------------------------------------- lifecycle

    /// <summary>
    /// Best-effort disconnect (if connected) followed by release of the pooled
    /// HTTP client. Preferred over <see cref="Dispose"/> because it can end the
    /// session gracefully; teardown never throws.
    /// </summary>
    public async ValueTask DisposeAsync()
    {
        try
        {
            if (Connected)
                await DisconnectAsync().ConfigureAwait(false);
        }
        catch
        {
            // Closing must never raise.
        }
        finally
        {
            if (_ownsHttp)
                _http.Dispose();
        }
    }

    /// <summary>
    /// Releases the pooled HTTP client. Does not perform network I/O; prefer
    /// <see cref="DisposeAsync"/> to also end the session gracefully.
    /// </summary>
    public void Dispose()
    {
        if (_ownsHttp)
            _http.Dispose();
    }

    // ----------------------------------------------------------------- JSON helpers

    private static string GetString(JsonElement element, string name, string fallback = "")
        => element.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.String
            ? (v.GetString() ?? fallback)
            : fallback;

    private static long GetInt64(JsonElement element, string name, long fallback = 0)
        => element.TryGetProperty(name, out var v) &&
           v.ValueKind == JsonValueKind.Number && v.TryGetInt64(out long n)
            ? n
            : fallback;

    private static IReadOnlyList<string> GetStringList(JsonElement element, string name)
    {
        var list = new List<string>();
        if (element.TryGetProperty(name, out var arr) && arr.ValueKind == JsonValueKind.Array)
        {
            foreach (var item in arr.EnumerateArray())
            {
                if (item.ValueKind == JsonValueKind.String)
                    list.Add(item.GetString()!);
            }
        }
        return list;
    }

    private static IReadOnlyList<JsonElement> GetElementList(JsonElement element, string name)
    {
        var list = new List<JsonElement>();
        if (element.TryGetProperty(name, out var arr) && arr.ValueKind == JsonValueKind.Array)
        {
            foreach (var item in arr.EnumerateArray())
                list.Add(item.Clone());
        }
        return list;
    }

    private static string Truncate(string value, int max)
        => value.Length <= max ? value : value[..max];
}
