import Foundation
import PriostackACN

/// Sharing quickstart: two agents, one space, an explicit grant.
///
/// `quickstart` shows one agent keeping its own memory. This is the other half, and the reason the
/// network exists: an owner agent stores knowledge, a second agent registers separately, and the
/// owner grants it scoped `read` + `quote` on that one space. Nothing is shared until the grant
/// exists, the grant names the grantee's agent id, and it can be revoked in one call.
///
/// All network calls live inside `main()`, so importing `PriostackACN` never fires a request.
/// Override the endpoint with `PRIOSTACK_ENDPOINT` (or `ACN_ENDPOINT`).
///
///     swift run share-quickstart
///     PRIOSTACK_ENDPOINT=http://127.0.0.1:8091/rpc swift run share-quickstart
@main
struct ShareQuickstart {
    static func main() async {
        let env = ProcessInfo.processInfo.environment
        let endpoint = (env["PRIOSTACK_ENDPOINT"] ?? env["ACN_ENDPOINT"])
            .flatMap { URL(string: $0) } ?? ACNClient.defaultEndpoint

        let owner = ACNClient(endpoint: endpoint)
        let worker = ACNClient(endpoint: endpoint)

        do {
            print("1. onboarding two agents")
            _ = try await onboard(owner, displayName: "swift-owner")
            let workerId = try await onboard(worker, displayName: "swift-worker")

            // defaultRights is the ceiling of what this space may ever offer. It grants nothing by
            // itself: until there is a grant, only the owner can read it.
            let space = try await owner.createSpace(
                displayName: "shift-handover",
                defaultRights: ["read", "quote"]
            )
            print("2. owner created space \(space.spaceId)")

            let stored = try await owner.store(space: space.spaceId, objects: [
                ContextObject(
                    content: "Night shift found a stuck consumer on queue orders-v2.",
                    type: .observation
                ),
                ContextObject(
                    content: "Restarting the consumer requires a change ticket after 22:00.",
                    type: .declaration
                ),
            ])
            print("3. owner stored \(stored.count) object(s)")

            let readableBefore = try await canRead(worker, space: space.spaceId)
            print(readableBefore
                ? "4. worker could read the space BEFORE a grant — that would be a bug"
                : "4. worker cannot see the space yet (as expected)")

            // The subject of a grant is the grantee's AGENT ID, not its display name or account.
            let grant = try await owner.grantAccess(
                space: space.spaceId,
                subjectPrincipal: workerId,
                rights: ["read", "quote"]
            )
            print("5. granted \(grant.effectiveRights.joined(separator: ", ")) (\(grant.capabilityRef))")

            // The grantee reconnects so its session picks up the widened scope.
            _ = try await worker.connect()
            let hits = try await worker.fetch(space: space.spaceId, query: "consumer")
            print("6. worker reads \(hits.matched) of \(hits.total) object(s):")
            for content in hits.contents {
                print("     - \(content)")
            }

            // Revoking is immediate and forward-only: the worker keeps nothing it has already
            // read, and loses the space on its next session.
            _ = try await owner.revokeAccess(capabilityRef: grant.capabilityRef)
            _ = try await worker.connect()
            let readableAfter = try await canRead(worker, space: space.spaceId)
            print(readableAfter
                ? "7. worker still reads the space after revoke — that would be a bug"
                : "7. grant revoked — the worker cannot read the space any more")

            _ = try? await worker.disconnect()
            _ = try? await owner.disconnect()
        } catch let error as ACNToolError {
            fail("tool error [\(error.outcome.rawValue)]: \(error.message)")
        } catch let error as ACNTransportError {
            fail("transport error: \(error.message)")
        } catch {
            fail("unexpected error: \(error)")
        }
    }

    /// Register one agent and open its session, returning its agent id.
    private static func onboard(_ acn: ACNClient, displayName: String) async throws -> String {
        let registration = try await acn.register(displayName: displayName)
        _ = try await acn.connect()
        print("  \(displayName): agent \(registration.agentId)")
        return registration.agentId
    }

    /// Whether this client can reach the space at all. A space it holds no capability on answers
    /// not-found — the same answer a space that does not exist gives: the network does not confirm
    /// the existence of context you were never granted.
    private static func canRead(_ acn: ACNClient, space spaceId: String) async throws -> Bool {
        do {
            _ = try await acn.fetch(space: spaceId)
            return true
        } catch let error as ACNToolError where error.outcome == .notFound {
            return false
        }
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(1)
    }
}
