/*
 * Typed result objects returned by the high-level [AcnClient] methods.
 *
 * The server returns plain JSON. These lightweight data classes give ergonomic,
 * type-checked access to the common calls while still exposing the full raw
 * `data` object via `raw` for anything not surfaced as a property.
 */
package com.priostack.acn

import kotlinx.serialization.json.JsonObject

/** Result of [AcnClient.register]. */
data class RegisterResult(
    val token: String,
    val agentId: String,
    val accountId: String,
    val tier: String,
    val raw: JsonObject,
)

/**
 * Result of [AcnClient.connect].
 *
 * Note the server serialises this with PascalCase Go field names; the client
 * maps them to idiomatic Kotlin properties (`SessionID` -> [sessionId], etc.).
 */
data class ConnectResult(
    val sessionId: String,
    val resolvedAccount: String,
    val grantedCapabilities: List<String>,
    val grantedContextRights: List<String>,
    val boundSpace: String,
    val resolvedMaxTokens: Int,
    val raw: JsonObject,
)

/** Result of [AcnClient.createSpace]. */
data class SpaceResult(
    val spaceId: String,
    val accountId: String,
    val persistenceMode: String,
    val protectionLevel: String,
    val raw: JsonObject,
)

/** Result of [AcnClient.store]. */
data class StoreResult(
    val objectRefs: List<JsonObject>,
    val raw: JsonObject,
) {
    /** How many objects were ingested. */
    val count: Int get() = objectRefs.size
}

/** Result of [AcnClient.fetch]. */
data class FetchResult(
    val space: String,
    val objects: List<JsonObject>,
    val matched: Int,
    val total: Int,
    val returnedTokens: Int,
    val raw: JsonObject,
) {
    /** Just the `content` strings of the returned objects. */
    fun contents(): List<String> = objects.map { it.stringOr("content") }
}

/** Result of [AcnClient.grantAccess] / [AcnClient.approveRequest]. */
data class GrantResult(
    val capabilityRef: String,
    val subject: String,
    val resource: String,
    val effectiveRights: List<String>,
    val raw: JsonObject,
)

/**
 * The `type` of a stored object. The ACN accepts exactly these three kinds;
 * anything else is rejected server-side (proposals/inferences go through the
 * propose/commit path, not `store`).
 */
enum class ObjectType(val wire: String) {
    DECLARATION("declaration"),
    OBSERVATION("observation"),
    MEASUREMENT("measurement"),
}

/**
 * A typed fact to persist with [AcnClient.store].
 *
 * @property content the fact text.
 * @property type one of [ObjectType] (defaults to [ObjectType.DECLARATION]).
 * @property provenance optional source references for the fact.
 */
data class StoreObject(
    val content: String,
    val type: ObjectType = ObjectType.DECLARATION,
    val provenance: List<String> = emptyList(),
)
