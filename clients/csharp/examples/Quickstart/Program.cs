using Priostack.Acn;

// Quickstart: register -> connect -> createSpace -> store -> fetch.
//
// Live network calls only run when this program is executed. Referencing the
// Priostack.Acn library from your own code fires nothing on its own.
//
// Usage:
//   dotnet run --project examples/Quickstart -- [displayName] [endpoint]
// Or via environment:
//   PRIOSTACK_ENDPOINT=https://priostack.com/mcp dotnet run --project examples/Quickstart

string displayName = args.Length > 0 ? args[0] : "csharp-sdk-smoke";
string endpoint = args.Length > 1
    ? args[1]
    : Environment.GetEnvironmentVariable("PRIOSTACK_ENDPOINT") ?? AcnClient.DefaultEndpoint;

Console.WriteLine($"Priostack ACN .NET quickstart against {endpoint}");

await using var acn = new AcnClient(endpoint);

try
{
    RegisterResult registration = await acn.RegisterAsync(displayName);
    Console.WriteLine($"registered agent {registration.AgentId} (tier: {registration.Tier})");

    ConnectResult connection = await acn.ConnectAsync();
    Console.WriteLine(
        $"connected session {connection.SessionId} on account {connection.ResolvedAccount}");

    SpaceResult space = await acn.CreateSpaceAsync("prod-memory");
    Console.WriteLine($"created space {space.SpaceId}");

    StoreResult stored = await acn.StoreAsync(space.SpaceId, new[]
    {
        new StoreObject("Refunds over $500 need manager approval.", "declaration"),
        new StoreObject("Checkout p99 latency was 820ms on 2026-09-08.", "measurement"),
    });
    Console.WriteLine($"stored {stored.Count} object(s)");

    FetchResult hits = await acn.FetchAsync(space.SpaceId, query: "refund");
    Console.WriteLine(
        $"fetched {hits.Objects.Count} of {hits.Total} object(s) matching 'refund':");
    foreach (FetchedObject obj in hits.Objects)
        Console.WriteLine($"  - [{obj.Kind}] {obj.Content}");

    return 0;
}
catch (AcnToolException ex)
{
    Console.Error.WriteLine($"tool error [{ex.Outcome}]: {ex.Detail}");
    return 1;
}
catch (AcnTransportException ex)
{
    Console.Error.WriteLine($"transport error calling {ex.Method ?? "?"}: {ex.Message}");
    return 2;
}
