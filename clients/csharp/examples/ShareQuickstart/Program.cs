using Priostack.Acn;

// Sharing quickstart: two agents, one space, an explicit grant.
//
// The Quickstart example shows one agent keeping its own memory. This is the other half, and the
// reason the network exists: an owner agent stores knowledge, a second agent registers separately,
// and the owner grants it scoped read + quote on that one space. Nothing is shared until the grant
// exists, the grant names the grantee's agent id, and it can be revoked in one call.
//
// Usage:
//   dotnet run --project examples/ShareQuickstart
// Or against a self-hosted or local node:
//   PRIOSTACK_ENDPOINT=http://127.0.0.1:8091/rpc dotnet run --project examples/ShareQuickstart

string endpoint = args.Length > 0
    ? args[0]
    : Environment.GetEnvironmentVariable("PRIOSTACK_ENDPOINT") ?? AcnClient.DefaultEndpoint;

await using var owner = new AcnClient(endpoint);
await using var worker = new AcnClient(endpoint);

try
{
    Console.WriteLine("1. onboarding two agents");
    await OnboardAsync(owner, "csharp-owner");
    string workerId = await OnboardAsync(worker, "csharp-worker");

    // defaultRights is the ceiling of what this space may ever offer. It grants nothing by itself:
    // until there is a grant, only the owner can read it.
    SpaceResult space = await owner.CreateSpaceAsync(
        "shift-handover", new[] { "read", "quote" });
    Console.WriteLine($"2. owner created space {space.SpaceId}");

    StoreResult stored = await owner.StoreAsync(space.SpaceId, new[]
    {
        new StoreObject("Night shift found a stuck consumer on queue orders-v2.", "observation"),
        new StoreObject("Restarting the consumer requires a change ticket after 22:00.", "declaration"),
    });
    Console.WriteLine($"3. owner stored {stored.Count} object(s)");

    Console.WriteLine(await CanReadAsync(worker, space.SpaceId)
        ? "4. worker could read the space BEFORE a grant — that would be a bug"
        : "4. worker cannot see the space yet (as expected)");

    // The subject of a grant is the grantee's AGENT ID, not its display name or its account.
    GrantResult grant = await owner.GrantAccessAsync(
        space.SpaceId, workerId, new[] { "read", "quote" });
    Console.WriteLine(
        $"5. granted {string.Join(", ", grant.EffectiveRights)} ({grant.CapabilityRef})");

    // The grantee reconnects so its session picks up the widened scope.
    await worker.ConnectAsync();
    FetchResult hits = await worker.FetchAsync(space.SpaceId, "consumer");
    Console.WriteLine($"6. worker reads {hits.Matched} of {hits.Total} object(s):");
    foreach (string content in hits.Contents())
    {
        Console.WriteLine($"     - {content}");
    }

    // Revoking is immediate and forward-only: the worker keeps nothing it has already read, and
    // loses the space on its next session.
    await owner.RevokeAccessAsync(grant.CapabilityRef);
    await worker.ConnectAsync();
    Console.WriteLine(await CanReadAsync(worker, space.SpaceId)
        ? "7. worker still reads the space after revoke — that would be a bug"
        : "7. grant revoked — the worker cannot read the space any more");
}
catch (AcnToolException ex)
{
    Console.Error.WriteLine($"tool error [{ex.Outcome}] on {ex.Method}: {ex.Message}");
    return 1;
}
catch (AcnTransportException ex)
{
    Console.Error.WriteLine($"transport error on {ex.Method}: {ex.Message}");
    return 1;
}

return 0;

// Register one agent and open its session, returning its agent id.
static async Task<string> OnboardAsync(AcnClient acn, string displayName)
{
    RegisterResult registration = await acn.RegisterAsync(displayName);
    await acn.ConnectAsync();
    Console.WriteLine($"  {displayName}: agent {registration.AgentId}");
    return registration.AgentId;
}

// Whether this client can reach the space at all. A space it holds no capability on answers
// not-found — the same answer a space that does not exist gives: the network does not confirm the
// existence of context you were never granted.
static async Task<bool> CanReadAsync(AcnClient acn, string spaceId)
{
    try
    {
        await acn.FetchAsync(spaceId);
        return true;
    }
    catch (AcnNotFoundException)
    {
        return false;
    }
}
