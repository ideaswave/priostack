import Foundation
import PriostackACN

/// End-to-end smoke run against the live ACN:
/// register -> connect -> createSpace -> store -> fetch, printing each step.
///
/// All network calls live inside `main()`, so importing `PriostackACN` never
/// fires a request. Override the endpoint with `ACN_ENDPOINT`, and pass a
/// display name as the first argument (defaults to `swift-sdk-smoke`).
///
///     swift run quickstart               # uses "swift-sdk-smoke"
///     swift run quickstart my-agent-name
@main
struct Quickstart {
    static func main() async {
        let endpoint = ProcessInfo.processInfo.environment["ACN_ENDPOINT"]
            .flatMap { URL(string: $0) } ?? ACNClient.defaultEndpoint
        let displayName = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "swift-sdk-smoke"

        let acn = ACNClient(endpoint: endpoint)

        do {
            let registration = try await acn.register(displayName: displayName)
            print("registered agent \(registration.agentId) (tier: \(registration.tier))")

            let session = try await acn.connect()
            print("connected session \(session.sessionId) on account \(session.resolvedAccount)")

            let space = try await acn.createSpace(displayName: "swift-quickstart-memory")
            print("created space \(space.spaceId)")

            let stored = try await acn.store(space: space.spaceId, objects: [
                ContextObject(content: "Refunds over $500 need manager approval.", type: .declaration),
                ContextObject(content: "Checkout p95 latency was 412ms on 2026-09-01.", type: .measurement),
            ])
            print("stored \(stored.count) object(s)")

            let hits = try await acn.fetch(space: space.spaceId, query: "refund")
            print("fetched \(hits.objects.count) of \(hits.total) object(s) "
                + "(matched \(hits.matched), \(hits.returnedTokens) tokens):")
            for object in hits.objects {
                print("  - [\(object.kind)] \(object.content)")
            }

            _ = try await acn.disconnect()
            print("disconnected")
        } catch let error as ACNToolError {
            fail("tool error [\(error.outcome.rawValue)]: \(error.message)")
        } catch let error as ACNTransportError {
            fail("transport error: \(error.message)")
        } catch {
            fail("unexpected error: \(error)")
        }
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(1)
    }
}
