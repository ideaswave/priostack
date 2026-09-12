// Sharing quickstart for the Priostack ACN Dart client: two agents, one space, an explicit grant.
//
// quickstart.dart shows one agent keeping its own memory. This is the other half, and the reason
// the network exists: an owner agent stores knowledge, a second agent registers separately, and the
// owner grants it scoped `read` + `quote` on that one space. Nothing is shared until the grant
// exists, the grant names the grantee's agent id, and it can be revoked in one call.
//
//   dart run example/share_quickstart.dart
//
// Against a self-hosted or local node:
//
//   PRIOSTACK_ENDPOINT=http://127.0.0.1:8091/rpc dart run example/share_quickstart.dart
//
// Network calls fire only from main(), so importing the library never touches the network.

import 'dart:async';
import 'dart:io' show Platform;

import 'package:priostack/priostack.dart';

/// Registers one agent and opens its session, returning the client and its agent id.
Future<(AcnClient, String)> onboard(String endpoint, String displayName) async {
  final acn = AcnClient(endpoint: endpoint);
  final registered = await acn.register(displayName: displayName);
  await acn.connect();
  print('  $displayName: agent ${registered.agentId}');
  return (acn, registered.agentId);
}

/// Whether this client can reach the space at all. A space it holds no capability on answers
/// not-found — the same answer a space that does not exist gives: the network does not confirm the
/// existence of context you were never granted.
Future<bool> canRead(AcnClient acn, String spaceId) async {
  try {
    await acn.fetch(spaceId);
    return true;
  } on NotFoundError {
    return false;
  }
}

Future<void> main(List<String> args) async {
  final endpoint = args.isNotEmpty
      ? args.first
      : (Platform.environment['PRIOSTACK_ENDPOINT'] ?? defaultEndpoint);

  print('1. onboarding two agents');
  final (owner, _) = await onboard(endpoint, 'dart-owner');
  final (worker, workerId) = await onboard(endpoint, 'dart-worker');

  try {
    // defaultRights is the ceiling of what this space may ever offer. It grants nothing by itself:
    // until there is a grant, only the owner can read it.
    final space = await owner.createSpace(
      'shift-handover',
      defaultRights: ['read', 'quote'],
    );
    print('2. owner created space ${space.spaceId}');

    final stored = await owner.store(space.spaceId, [
      {
        'content': 'Night shift found a stuck consumer on queue orders-v2.',
        'type': 'observation',
      },
      {
        'content': 'Restarting the consumer requires a change ticket after 22:00.',
        'type': 'declaration',
      },
    ]);
    print('3. owner stored ${stored.count} object(s)');

    print(await canRead(worker, space.spaceId)
        ? '4. worker could read the space BEFORE a grant — that would be a bug'
        : '4. worker cannot see the space yet (as expected)');

    // The subject of a grant is the grantee's AGENT ID, not its display name or its account.
    final grant = await owner.grantAccess(
      space.spaceId,
      workerId,
      rights: ['read', 'quote'],
    );
    print('5. granted ${grant.effectiveRights.join(', ')} (${grant.capabilityRef})');

    // The grantee reconnects so its session picks up the widened scope.
    await worker.connect();
    final hits = await worker.fetch(space.spaceId, query: 'consumer');
    print('6. worker reads ${hits.matched} of ${hits.total} object(s):');
    for (final content in hits.contents()) {
      print('     - $content');
    }

    // Revoking is immediate and forward-only: the worker keeps nothing it has already read, and
    // loses the space on its next session.
    await owner.revokeAccess(grant.capabilityRef);
    await worker.connect();
    print(await canRead(worker, space.spaceId)
        ? '7. worker still reads the space after revoke — that would be a bug'
        : '7. grant revoked — the worker cannot read the space any more');
  } on AcnToolError catch (e) {
    // The tool reached the server but declined the call.
    print('tool error [${e.outcome}] on ${e.method}: ${e.detail}');
  } on AcnTransportError catch (e) {
    // Network / HTTP / protocol failure — never got a valid tool envelope.
    print('transport error on ${e.method}: ${e.message}');
  } finally {
    await worker.close();
    await owner.close();
  }
}
