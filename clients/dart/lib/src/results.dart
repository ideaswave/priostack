/// Typed result objects returned by the high-level [AcnClient] methods.
///
/// The server returns plain JSON. These lightweight immutable classes give
/// ergonomic, type-checked access to the common calls while still exposing the
/// full raw `data` map via [raw] for anything not surfaced as a field.
library;

import 'internal.dart';

/// Result of `AcnClient.register`.
class RegisterResult {
  /// Creates a register result.
  const RegisterResult({
    required this.token,
    required this.agentId,
    required this.accountId,
    required this.tier,
    this.raw = const {},
  });

  /// Builds a [RegisterResult] from a decoded `data` map.
  factory RegisterResult.fromData(Map<String, dynamic> data) => RegisterResult(
        token: asString(data['token']),
        agentId: asString(data['agentId']),
        accountId: asString(data['accountId']),
        tier: asString(data['tier']),
        raw: data,
      );

  /// The bearer token issued for this agent (shown once; persist it).
  final String token;

  /// The agent's stable principal id.
  final String agentId;

  /// The account the agent belongs to.
  final String accountId;

  /// The service tier the agent was registered on.
  final String tier;

  /// The full raw `data` map from the server.
  final Map<String, dynamic> raw;

  @override
  String toString() => 'RegisterResult(agentId: $agentId, accountId: $accountId, tier: $tier)';
}

/// Result of `AcnClient.connect`.
///
/// The connect envelope's `data` uses PascalCase Go field names; this class
/// reads them (`SessionID`, `ResolvedAccount`, ...) and exposes idiomatic Dart
/// getters.
class ConnectResult {
  /// Creates a connect result.
  const ConnectResult({
    required this.sessionId,
    required this.resolvedAccount,
    required this.grantedCapabilities,
    required this.grantedContextRights,
    required this.boundSpace,
    required this.resolvedMaxTokens,
    this.raw = const {},
  });

  /// Builds a [ConnectResult] from a decoded `data` map (PascalCase keys).
  factory ConnectResult.fromData(Map<String, dynamic> data) => ConnectResult(
        sessionId: asString(data['SessionID']),
        resolvedAccount: asString(data['ResolvedAccount']),
        grantedCapabilities: asStringList(data['GrantedCapabilities']),
        grantedContextRights: asStringList(data['GrantedContextRights']),
        boundSpace: asString(data['BoundSpace']),
        resolvedMaxTokens: asInt(data['ResolvedMaxTokens']),
        raw: data,
      );

  /// The session id captured for subsequent calls (from `SessionID`).
  final String sessionId;

  /// The account resolved from the token (from `ResolvedAccount`).
  final String resolvedAccount;

  /// Capabilities granted to this session (from `GrantedCapabilities`).
  final List<String> grantedCapabilities;

  /// Context rights granted to this session (from `GrantedContextRights`).
  final List<String> grantedContextRights;

  /// The space this session is bound to, if any (from `BoundSpace`).
  final String boundSpace;

  /// The negotiated max response tokens (from `ResolvedMaxTokens`).
  final int resolvedMaxTokens;

  /// The full raw `data` map from the server.
  final Map<String, dynamic> raw;

  @override
  String toString() =>
      'ConnectResult(sessionId: $sessionId, resolvedAccount: $resolvedAccount, boundSpace: $boundSpace)';
}

/// Result of `AcnClient.createSpace`.
class SpaceResult {
  /// Creates a space result.
  const SpaceResult({
    required this.spaceId,
    required this.accountId,
    required this.persistenceMode,
    required this.protectionLevel,
    this.raw = const {},
  });

  /// Builds a [SpaceResult] from a decoded `data` map.
  factory SpaceResult.fromData(Map<String, dynamic> data) => SpaceResult(
        spaceId: asString(data['spaceId']),
        accountId: asString(data['accountId']),
        persistenceMode: asString(data['persistenceMode']),
        protectionLevel: asString(data['protectionLevel']),
        raw: data,
      );

  /// The resolved space id — use this for subsequent store/fetch calls.
  final String spaceId;

  /// The account that owns the space.
  final String accountId;

  /// The space's persistence mode.
  final String persistenceMode;

  /// The space's protection level.
  final String protectionLevel;

  /// The full raw `data` map from the server.
  final Map<String, dynamic> raw;

  @override
  String toString() => 'SpaceResult(spaceId: $spaceId, accountId: $accountId)';
}

/// Result of `AcnClient.store`.
class StoreResult {
  /// Creates a store result.
  const StoreResult({required this.objectRefs, this.raw = const {}});

  /// Builds a [StoreResult] from a decoded `data` map.
  factory StoreResult.fromData(Map<String, dynamic> data) =>
      StoreResult(objectRefs: asMapList(data['objectRefs']), raw: data);

  /// References to the objects that were ingested.
  final List<Map<String, dynamic>> objectRefs;

  /// The full raw `data` map from the server.
  final Map<String, dynamic> raw;

  /// How many objects were ingested.
  int get count => objectRefs.length;

  @override
  String toString() => 'StoreResult(count: $count)';
}

/// Result of `AcnClient.fetch`.
class FetchResult {
  /// Creates a fetch result.
  const FetchResult({
    required this.space,
    required this.objects,
    required this.matched,
    required this.total,
    required this.returnedTokens,
    this.raw = const {},
  });

  /// Builds a [FetchResult] from a decoded `data` map, falling back to
  /// [fallbackSpace] when the server omits the `space` field.
  factory FetchResult.fromData(Map<String, dynamic> data, String fallbackSpace) => FetchResult(
        space: data['space'] is String ? data['space'] as String : fallbackSpace,
        objects: asMapList(data['objects']),
        matched: asInt(data['matched']),
        total: asInt(data['total']),
        returnedTokens: asInt(data['returnedTokens']),
        raw: data,
      );

  /// The space that was read.
  final String space;

  /// The returned objects, each `{objectRef, kind, content, tokens}`.
  final List<Map<String, dynamic>> objects;

  /// How many objects matched the query.
  final int matched;

  /// How many objects exist in the space in total.
  final int total;

  /// How many tokens the returned objects account for.
  final int returnedTokens;

  /// The full raw `data` map from the server.
  final Map<String, dynamic> raw;

  /// Just the `content` strings of the returned objects.
  List<String> contents() =>
      objects.map((o) => asString(o['content'])).toList(growable: false);

  @override
  String toString() =>
      'FetchResult(space: $space, matched: $matched, total: $total, returned: ${objects.length})';
}

/// Result of `AcnClient.grantAccess` / `AcnClient.approveRequest`.
class GrantResult {
  /// Creates a grant result.
  const GrantResult({
    required this.capabilityRef,
    required this.subject,
    required this.resource,
    required this.effectiveRights,
    this.raw = const {},
  });

  /// Builds a [GrantResult] from a decoded `data` map.
  factory GrantResult.fromData(Map<String, dynamic> data) => GrantResult(
        capabilityRef: asString(data['capabilityRef']),
        subject: asString(data['subject']),
        resource: asString(data['resource']),
        effectiveRights: asStringList(data['effectiveRights']),
        raw: data,
      );

  /// The reference identifying the minted capability (used to revoke it).
  final String capabilityRef;

  /// The grantee principal.
  final String subject;

  /// The space (resource) the capability applies to.
  final String resource;

  /// The rights that ended up effective on the capability.
  final List<String> effectiveRights;

  /// The full raw `data` map from the server.
  final Map<String, dynamic> raw;

  @override
  String toString() =>
      'GrantResult(capabilityRef: $capabilityRef, subject: $subject, resource: $resource, rights: $effectiveRights)';
}
