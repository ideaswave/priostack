/// Internal JSON-coercion helpers shared across the client and result types.
///
/// The ACN server returns loosely typed JSON. These helpers read a field
/// defensively so a missing or wrong-typed value degrades to a sensible
/// default instead of throwing deep inside a result constructor. They are not
/// part of the public API and are intentionally not re-exported by the
/// `priostack` barrel library.
library;

/// Returns [v] when it is a [String], otherwise [fallback].
String asString(Object? v, [String fallback = '']) => v is String ? v : fallback;

/// Returns [v] as an [int] (accepting any [num]), otherwise [fallback].
int asInt(Object? v, [int fallback = 0]) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  return fallback;
}

/// Returns [v] as a list of strings, or an empty list when it is not a list.
List<String> asStringList(Object? v) =>
    v is List ? v.map((e) => e.toString()).toList(growable: false) : const <String>[];

/// Returns [v] as a list of string-keyed maps, dropping non-map entries.
List<Map<String, dynamic>> asMapList(Object? v) => v is List
    ? v.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList(growable: false)
    : const <Map<String, dynamic>>[];

/// Truncates [s] to at most [n] characters (for bounded error messages).
String truncate(String s, int n) => s.length <= n ? s : s.substring(0, n);
