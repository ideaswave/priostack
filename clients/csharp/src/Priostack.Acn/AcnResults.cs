using System.Text.Json;

namespace Priostack.Acn;

// Lightweight, immutable result records. The server returns plain JSON; these
// give ergonomic, type-checked access to the common calls while still exposing
// the full raw ``data`` element via ``Raw`` for anything not surfaced here.

/// <summary>Result of <see cref="AcnClient.RegisterAsync"/>.</summary>
public sealed record RegisterResult(
    string Token,
    string AgentId,
    string AccountId,
    string Tier,
    JsonElement Raw);

/// <summary>
/// Result of <see cref="AcnClient.ConnectAsync"/>. Note the server serializes
/// this payload with Go field names (PascalCase).
/// </summary>
public sealed record ConnectResult(
    string SessionId,
    string ResolvedAccount,
    IReadOnlyList<string> GrantedCapabilities,
    IReadOnlyList<string> GrantedContextRights,
    string BoundSpace,
    long ResolvedMaxTokens,
    JsonElement Raw);

/// <summary>Result of <see cref="AcnClient.CreateSpaceAsync"/>.</summary>
public sealed record SpaceResult(
    string SpaceId,
    string AccountId,
    string PersistenceMode,
    string ProtectionLevel,
    JsonElement Raw);

/// <summary>Result of <see cref="AcnClient.StoreAsync"/>.</summary>
public sealed record StoreResult(
    IReadOnlyList<JsonElement> ObjectRefs,
    JsonElement Raw)
{
    /// <summary>How many objects were ingested.</summary>
    public int Count => ObjectRefs.Count;
}

/// <summary>A single object returned by <see cref="AcnClient.FetchAsync"/>.</summary>
public sealed record FetchedObject(
    string ObjectRef,
    string Kind,
    string Content,
    long Tokens,
    JsonElement Raw);

/// <summary>Result of <see cref="AcnClient.FetchAsync"/> (the content reader).</summary>
public sealed record FetchResult(
    string Space,
    IReadOnlyList<FetchedObject> Objects,
    long Matched,
    long Total,
    long ReturnedTokens,
    JsonElement Raw)
{
    /// <summary>Just the <c>content</c> strings of the returned objects.</summary>
    public IReadOnlyList<string> Contents() => Objects.Select(o => o.Content).ToList();
}

/// <summary>
/// Result of <see cref="AcnClient.GrantAccessAsync"/> and
/// <see cref="AcnClient.ApproveRequestAsync"/>.
/// </summary>
public sealed record GrantResult(
    string CapabilityRef,
    string Subject,
    string Resource,
    IReadOnlyList<string> EffectiveRights,
    JsonElement Raw);

/// <summary>
/// A typed fact to persist with <see cref="AcnClient.StoreAsync"/>. <paramref name="Type"/>
/// must be one of <see cref="AcnClient.StoreKinds"/>
/// (<c>declaration</c> / <c>observation</c> / <c>measurement</c>).
/// </summary>
public sealed record StoreObject(
    string Content,
    string Type = "declaration",
    IReadOnlyList<string>? Provenance = null);
