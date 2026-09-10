/// Official Dart client for the Priostack Agent Context Network (ACN).
///
/// Model-agnostic, zero-setup long-term memory and multi-agent context sharing
/// for AI agents, over the Model Context Protocol (MCP) on JSON-RPC 2.0.
///
/// ```dart
/// import 'package:priostack/priostack.dart';
///
/// Future<void> main() async {
///   final acn = AcnClient();
///   try {
///     await acn.register(displayName: 'my-agent');
///     await acn.connect();
///     final space = await acn.createSpace('prod-memory');
///     await acn.store(space.spaceId, [
///       {'content': 'Refunds over \$500 need manager approval.', 'type': 'declaration'},
///     ]);
///     final hits = await acn.fetch(space.spaceId, query: 'refund');
///     hits.contents().forEach(print);
///   } finally {
///     await acn.close();
///   }
/// }
/// ```
library;

export 'src/client.dart'
    show AcnClient, defaultEndpoint, storeKinds, clientVersion;
export 'src/exceptions.dart'
    show
        AcnError,
        AcnTransportError,
        AcnToolError,
        NotFoundError,
        InvalidQueryError,
        CapabilityDeniedError,
        PolicyDeniedError,
        RequiresGovernanceError,
        StaleBaseError,
        IntegrityFaultError,
        ConflictError,
        CapacityExhaustedError,
        NotSupportedError,
        toolErrorFor;
export 'src/results.dart'
    show
        RegisterResult,
        ConnectResult,
        SpaceResult,
        StoreResult,
        FetchResult,
        GrantResult;
