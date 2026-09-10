/*
 * Small internal helpers for reading typed values out of a [JsonObject] and
 * building JSON-RPC argument objects. The ACN envelope `data` is polymorphic
 * (its shape differs per tool, and `connect` even uses PascalCase Go keys), so
 * the client navigates the JSON DOM directly rather than binding fixed
 * `@Serializable` schemas.
 */
package com.priostack.acn

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonObjectBuilder
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.add
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.putJsonArray

/** Read a string field, falling back to [default] when absent or the wrong type. */
internal fun JsonObject.stringOr(key: String, default: String = ""): String =
    (this[key] as? JsonPrimitive)?.contentOrNull ?: default

/** Read an integer field, falling back to [default] when absent or the wrong type. */
internal fun JsonObject.intOr(key: String, default: Int = 0): Int =
    (this[key] as? JsonPrimitive)?.intOrNull ?: default

/** Read an array of strings, skipping any non-string elements. */
internal fun JsonObject.stringList(key: String): List<String> =
    (this[key] as? JsonArray)?.mapNotNull { (it as? JsonPrimitive)?.contentOrNull } ?: emptyList()

/** Read an array of objects, skipping any non-object elements. */
internal fun JsonObject.objectList(key: String): List<JsonObject> =
    (this[key] as? JsonArray)?.mapNotNull { it as? JsonObject } ?: emptyList()

/** Put a string array under [key] while building a JSON object. */
internal fun JsonObjectBuilder.putStrings(key: String, values: List<String>) {
    putJsonArray(key) { values.forEach { add(it) } }
}
