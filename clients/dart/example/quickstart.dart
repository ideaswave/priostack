// Quickstart for the Priostack ACN Dart client:
// register -> connect -> createSpace -> store -> fetch, printing each step.
//
// Run it against the live endpoint with:
//
//   dart run example/quickstart.dart [display-name]
//
// Network calls fire only from main(), so importing the library never touches
// the network.

import 'dart:async';

import 'package:priostack/priostack.dart';

Future<void> main(List<String> args) async {
  final displayName = args.isNotEmpty ? args.first : 'dart-sdk-smoke';

  final acn = AcnClient();
  try {
    final registered = await acn.register(displayName: displayName);
    print('registered  agentId=${registered.agentId} tier=${registered.tier}');

    final session = await acn.connect();
    print('connected   sessionId=${session.sessionId} account=${session.resolvedAccount}');

    final space = await acn.createSpace('quickstart-memory');
    print('space       spaceId=${space.spaceId}');

    final stored = await acn.store(space.spaceId, [
      {
        'content': 'Refunds over \$500 require manager approval.',
        'type': 'declaration',
      },
      {
        'content': 'Customer #402 triggered the export pipeline at 14:03 UTC.',
        'type': 'observation',
      },
    ]);
    print('stored      ${stored.count} object(s)');

    final hits = await acn.fetch(space.spaceId, query: 'refund');
    print('fetched     matched=${hits.matched} total=${hits.total}');
    for (final content in hits.contents()) {
      print('  - $content');
    }
  } on AcnToolError catch (e) {
    // The tool reached the server but declined the call.
    print('tool error [${e.outcome}] on ${e.method}: ${e.detail}');
  } on AcnTransportError catch (e) {
    // Network / HTTP / protocol failure — never got a valid tool envelope.
    print('transport error on ${e.method}: ${e.message}');
  } finally {
    await acn.close();
  }
}
