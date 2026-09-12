/// The Priostack ACN JSON-RPC client.
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'exceptions.dart';
import 'internal.dart';
import 'results.dart';

/// Canonical MCP endpoint (Streamable HTTP). `/acn/rpc` is a working alias.
const String defaultEndpoint = 'https://priostack.com/mcp';

/// Object `type` values the `store` tool accepts.
///
/// Anything else is rejected server-side with `invalid-query` (proposals /
/// inferences go through the propose/commit path, not `store`).
const List<String> storeKinds = ['declaration', 'observation', 'measurement'];

/// The client library version, reported in the `User-Agent` header.
const String clientVersion = '0.3.0';

/// A sturdy JSON-RPC client for the Priostack Agent Context Network (ACN).
///
/// The ACN is a Model Context Protocol (MCP) server reached over JSON-RPC 2.0.
/// An agent self-registers, opens a session with the returned bearer token,
/// creates isolated context spaces, stores typed facts, reads them back, and
/// shares them with other agents through scoped capability grants.
///
/// This client speaks the exact wire contract of the live server: it unwraps
/// the MCP `result.content[0].text` envelope, throws typed exceptions on
/// tool-level denials, reuses one pooled HTTP client, and captures the session
/// id automatically on [connect].
///
/// ```dart
/// final acn = AcnClient();
/// try {
///   await acn.register(displayName: 'my-agent'); // token captured internally
///   await acn.connect();                          // session id captured
///   final space = await acn.createSpace('prod-memory');
///   await acn.store(space.spaceId, [
///     {'content': 'Refunds over \$500 need manager approval.', 'type': 'declaration'},
///   ]);
///   final hits = await acn.fetch(space.spaceId, query: 'refund');
///   hits.contents().forEach(print);
/// } finally {
///   await acn.close();
/// }
/// ```
class AcnClient {
  /// Creates a client.
  ///
  /// [endpoint] defaults to the canonical Streamable-HTTP MCP endpoint. Pass an
  /// existing [token] to reconnect an agent without registering again. Inject
  /// [httpClient] to supply custom TLS/proxy settings; otherwise one is created
  /// and owned by this client. [timeout] is applied to every request.
  AcnClient({
    this.endpoint = defaultEndpoint,
    this.token,
    Duration timeout = const Duration(seconds: 30),
    http.Client? httpClient,
  })  : _timeout = timeout,
        _ownsClient = httpClient == null,
        _http = httpClient ?? http.Client();

  /// The RPC endpoint this client posts to.
  final String endpoint;

  /// The current bearer token, set by [register] / [connect] or the constructor.
  String? token;

  /// The current session id, captured by [connect]. `null` until connected.
  String? sessionId;

  final Duration _timeout;
  final bool _ownsClient;
  final http.Client _http;
  int _id = 0;

  /// Whether a session id has been captured.
  bool get connected => sessionId != null;

  Uri get _uri => Uri.parse(endpoint);

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        // Ask for a plain JSON reply; the Streamable-HTTP endpoint would
        // otherwise be free to answer a POST as a one-shot SSE frame.
        'Accept': 'application/json',
        'User-Agent': 'priostack-dart/$clientVersion',
      };

  int _nextId() => ++_id;

  /// Best-effort disconnect (if connected) and release of the HTTP pool.
  ///
  /// Never throws. Call it when you are done with the client (e.g. in a
  /// `finally` block).
  Future<void> close() async {
    try {
      if (sessionId != null) await disconnect();
    } catch (_) {
      // closing must never throw
    } finally {
      if (_ownsClient) _http.close();
    }
  }

  // -- transport ---------------------------------------------------------- //

  /// Invokes any `noetic.*` tool and returns its unwrapped `data` map.
  ///
  /// This is the low-level escape hatch behind every typed method — use it to
  /// reach tools this client does not wrap explicitly. It performs the full
  /// round trip: builds the JSON-RPC `tools/call` envelope, unwraps
  /// `result.content[0].text`, and throws [AcnToolError] (or a subclass) when
  /// the tool returns `ok: false`, or [AcnTransportError] on any protocol /
  /// network failure.
  Future<Map<String, dynamic>> call(String method, Map<String, dynamic> arguments) async {
    final payload = <String, dynamic>{
      'jsonrpc': '2.0',
      'id': _nextId(),
      'method': 'tools/call',
      'params': {'name': method, 'arguments': arguments},
    };

    http.Response resp;
    try {
      resp = await _http
          .post(_uri, headers: _headers, body: jsonEncode(payload))
          .timeout(_timeout);
    } on TimeoutException {
      throw AcnTransportError(
        'request timed out calling $method after ${_timeout.inSeconds}s',
        method: method,
      );
    } catch (exc) {
      throw AcnTransportError('network error calling $method: $exc', method: method);
    }

    if (resp.statusCode >= 400) {
      throw AcnTransportError(
        'HTTP ${resp.statusCode} calling $method: ${truncate(resp.body, 500)}',
        method: method,
        httpStatus: resp.statusCode,
      );
    }

    Object? body;
    try {
      body = jsonDecode(resp.body);
    } on FormatException {
      throw AcnTransportError(
        'non-JSON response calling $method: ${truncate(resp.body, 500)}',
        method: method,
      );
    }

    // JSON-RPC protocol error (unknown method, bad params) — no result.
    if (body is Map && body['error'] != null) {
      final err = body['error'];
      final message = err is Map ? (err['message'] ?? err) : err;
      final code = err is Map && err['code'] is int ? err['code'] as int : null;
      throw AcnTransportError(
        'JSON-RPC error calling $method: $message',
        method: method,
        code: code,
      );
    }

    final result = body is Map ? body['result'] : null;
    if (result is! Map) {
      throw AcnTransportError(
        'malformed response calling $method: ${truncate('$body', 500)}',
        method: method,
      );
    }

    final envelope = _unwrap(result, method);

    if (envelope['ok'] != true) {
      throw toolErrorFor(
        asString(envelope['outcome']),
        asString(envelope['detail']),
        method: method,
        data: envelope['data'],
      );
    }

    // `data` is optional (some tools return ok with no payload).
    final data = envelope['data'];
    if (data is Map) return Map<String, dynamic>.from(data);
    return {'data': data};
  }

  /// Parses the MCP `content[0].text` JSON envelope out of a `result`.
  Map<String, dynamic> _unwrap(Map<dynamic, dynamic> result, String method) {
    final content = result['content'];
    if (content is! List || content.isEmpty) {
      throw AcnTransportError('response for $method had no content block', method: method);
    }
    final first = content.first;
    final text = first is Map ? first['text'] : null;
    if (text is! String) {
      throw AcnTransportError('response for $method had no text payload', method: method);
    }
    Object? envelope;
    try {
      envelope = jsonDecode(text);
    } on FormatException {
      throw AcnTransportError(
        'could not decode envelope for $method: ${truncate(text, 300)}',
        method: method,
      );
    }
    if (envelope is! Map) {
      throw AcnTransportError('envelope for $method was not an object', method: method);
    }
    return Map<String, dynamic>.from(envelope);
  }

  String _requireSession() {
    final sid = sessionId;
    if (sid == null) {
      throw AcnTransportError('no active session: call connect() first');
    }
    return sid;
  }

  // -- identity ----------------------------------------------------------- //

  /// Self-registers a new agent and captures its bearer token.
  ///
  /// Only available on the online multi-agent ACN. The token is shown once; it
  /// is stored on this client ([token]) and returned so you can persist it.
  /// Throws [NotSupportedError] on a single-tenant ACN.
  Future<RegisterResult> register({String displayName = 'agent'}) async {
    final data = await call('noetic.register', {'displayName': displayName});
    final result = RegisterResult.fromData(data);
    token = result.token;
    return result;
  }

  /// Opens a session with a bearer token and captures the session id.
  ///
  /// Pass [token] explicitly, or rely on the token captured by [register] /
  /// passed to the constructor. Re-call [connect] after being granted access to
  /// a space so the widened scope is applied.
  Future<ConnectResult> connect({String? token, int maxTokens = 4096}) async {
    final tok = token ?? this.token;
    if (tok == null || tok.isEmpty) {
      throw AcnTransportError('connect() needs a token: register() first or pass token');
    }
    final data = await call('noetic.connect', {'token': tok, 'maxResponseTokens': maxTokens});
    // The server serializes ConnectResult with Go field names (PascalCase).
    final sid = asString(data['SessionID']);
    this.token = tok;
    if (sid.isEmpty) {
      throw AcnTransportError('connect returned no SessionID: $data', method: 'noetic.connect');
    }
    sessionId = sid;
    return ConnectResult.fromData(data);
  }

  /// Ends the current session. Durable facts are **not** revoked.
  Future<Map<String, dynamic>> disconnect() async {
    final sid = _requireSession();
    final data = await call('noetic.disconnect', {'sessionId': sid});
    sessionId = null;
    return data;
  }

  /// Mints a fresh bearer token for this agent and retires the old one.
  ///
  /// Existing sessions keep working; use the new token for future [connect]
  /// calls. The new token is stored on this client and returned.
  Future<String> rotateToken() async {
    final sid = _requireSession();
    final data = await call('noetic.rotate_token', {'sessionId': sid});
    final fresh = asString(data['token']);
    if (fresh.isNotEmpty) token = fresh;
    return fresh;
  }

  /// Discovers the grantable rights + world-mutation vocabulary in scope.
  Future<Map<String, dynamic>> capabilities() async {
    final sid = _requireSession();
    return call('noetic.capabilities', {'sessionId': sid});
  }

  // -- spaces + facts ----------------------------------------------------- //

  /// Creates an isolated context space and returns its resolved id.
  ///
  /// [defaultRights] is the ceiling of rights the space may offer to others; it
  /// does not grant anything by itself.
  Future<SpaceResult> createSpace(
    String displayName, {
    List<String>? defaultRights,
    String? visibility,
    String? persistenceMode,
    String? protectionLevel,
  }) async {
    final sid = _requireSession();
    final args = <String, dynamic>{'sessionId': sid, 'displayName': displayName};
    if (defaultRights != null) args['defaultRights'] = defaultRights;
    if (visibility != null) args['visibility'] = visibility;
    if (persistenceMode != null) args['persistenceMode'] = persistenceMode;
    if (protectionLevel != null) args['protectionLevel'] = protectionLevel;
    final data = await call('noetic.create_space', args);
    return SpaceResult.fromData(data);
  }

  /// Persists typed facts into a space.
  ///
  /// Each object is `{'content': String, 'type': <kind>, 'provenance'?: [...]}`
  /// where `type` is one of [storeKinds] (`declaration`/`observation`/
  /// `measurement`). Writing needs the write right and the `mutate` capability;
  /// the space owner has both. Throws [ArgumentError] if an object lacks
  /// `content` or carries an unknown `type`.
  Future<StoreResult> store(String spaceId, List<Map<String, dynamic>> objects) async {
    final sid = _requireSession();
    final objs = objects.map(_normalizeObject).toList(growable: false);
    // The `store` tool names the space argument `space`.
    final data = await call('noetic.store', {'sessionId': sid, 'space': spaceId, 'objects': objs});
    return StoreResult.fromData(data);
  }

  static Map<String, dynamic> _normalizeObject(Map<String, dynamic> obj) {
    final content = obj['content'];
    if (content == null) {
      throw ArgumentError("each stored object needs a 'content' field");
    }
    final kind = asString(obj['type'], 'declaration');
    if (!storeKinds.contains(kind)) {
      throw ArgumentError('invalid object type "$kind"; must be one of $storeKinds');
    }
    final out = <String, dynamic>{'content': content, 'type': kind};
    final provenance = obj['provenance'];
    if (provenance is List && provenance.isNotEmpty) {
      out['provenance'] = List<dynamic>.from(provenance);
    }
    return out;
  }

  /// Reads stored objects back from a space (this is the content reader).
  ///
  /// [query] is a case-insensitive **substring** filter over content (not
  /// semantic search); [limit] caps the count (0 = server default). This is
  /// distinct from `noetic.query`, which is a geometric divergence probe.
  Future<FetchResult> fetch(String spaceId, {String query = '', int limit = 0}) async {
    final sid = _requireSession();
    // The `fetch` tool names the space argument `space`.
    final args = <String, dynamic>{'sessionId': sid, 'space': spaceId};
    if (query.isNotEmpty) args['query'] = query;
    if (limit != 0) args['limit'] = limit;
    final data = await call('noetic.fetch', args);
    return FetchResult.fromData(data, spaceId);
  }

  // -- sharing ------------------------------------------------------------ //

  /// Grants another agent scoped access to a space you own.
  ///
  /// [subjectPrincipal] is the grantee's agent id. [rights] are content rights
  /// (`read`/`write`/`quote`/`share`/`export`/...). [worldMutation] is the
  /// separate mutation ladder (`read`/`propose`/`mutate`); leave it `null` and
  /// the server derives it from the rights (granting `write` confers `mutate`).
  Future<GrantResult> grantAccess(
    String spaceId,
    String subjectPrincipal, {
    List<String> rights = const ['read', 'quote'],
    String? worldMutation,
    String? persistenceMode,
  }) async {
    final sid = _requireSession();
    // The server names the space argument `resource`. `space` is sent too as a
    // harmless alias for older builds; unknown fields are ignored.
    final args = <String, dynamic>{
      'sessionId': sid,
      'subjectPrincipal': subjectPrincipal,
      'resource': spaceId,
      'space': spaceId,
      'rights': rights,
    };
    if (worldMutation != null) args['worldMutation'] = worldMutation;
    if (persistenceMode != null) args['persistenceMode'] = persistenceMode;
    final data = await call('noetic.grant', args);
    return GrantResult.fromData(data);
  }

  /// Revokes a previously granted capability (immediate, forward-only).
  Future<Map<String, dynamic>> revokeAccess(String capabilityRef) async {
    final sid = _requireSession();
    return call('noetic.revoke', {'sessionId': sid, 'capabilityRef': capabilityRef});
  }

  /// Asks the owner of a remote space for scoped access (consumer side).
  Future<Map<String, dynamic>> requestAccess(
    String spaceId,
    List<String> rights, {
    String? persistenceMode,
    String reason = '',
  }) async {
    final sid = _requireSession();
    final args = <String, dynamic>{
      'sessionId': sid,
      'space': spaceId,
      // The server names this argument `rights` (not `requestedRights`).
      'rights': rights,
    };
    if (persistenceMode != null) args['persistenceMode'] = persistenceMode;
    if (reason.isNotEmpty) args['reason'] = reason;
    return call('noetic.request_access', args);
  }

  /// Lists pending access requests on spaces you own (owner side).
  Future<List<Map<String, dynamic>>> listRequests() async {
    final sid = _requireSession();
    final data = await call('noetic.list_requests', {'sessionId': sid});
    return asMapList(data['requests']);
  }

  /// Approves a pending access request, minting the grant (owner side).
  Future<GrantResult> approveRequest(
    String requestId, {
    List<String>? rights,
    String? worldMutation,
    String? persistenceMode,
  }) async {
    final sid = _requireSession();
    final args = <String, dynamic>{'sessionId': sid, 'requestId': requestId};
    if (rights != null) args['rights'] = rights;
    if (worldMutation != null) args['worldMutation'] = worldMutation;
    if (persistenceMode != null) args['persistenceMode'] = persistenceMode;
    final data = await call('noetic.approve_request', args);
    return GrantResult.fromData(data);
  }

  /// Denies a pending access request (owner side).
  Future<Map<String, dynamic>> denyRequest(String requestId) async {
    final sid = _requireSession();
    return call('noetic.deny_request', {'sessionId': sid, 'requestId': requestId});
  }

  // -- discovery + introspection ------------------------------------------ //

  /// Lists publicly discoverable spaces (no session required).
  Future<List<Map<String, dynamic>>> discover({String query = '', int limit = 0}) async {
    final args = <String, dynamic>{};
    if (query.isNotEmpty) args['query'] = query;
    if (limit != 0) args['limit'] = limit;
    final data = await call('noetic.discover', args);
    return asMapList(data['spaces']);
  }

  /// Sets a space's discovery visibility.
  Future<Map<String, dynamic>> publish(String spaceId, {String visibility = 'public'}) async {
    final sid = _requireSession();
    return call('noetic.publish', {'sessionId': sid, 'space': spaceId, 'visibility': visibility});
  }

  /// Returns scope/account/space usage metrics for the session.
  Future<Map<String, dynamic>> metrics() async {
    final sid = _requireSession();
    return call('noetic.metrics', {'sessionId': sid});
  }
}
