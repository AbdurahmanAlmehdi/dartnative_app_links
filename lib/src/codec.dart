import 'dart:convert';

/// Decodes the JSON string array native returns from
/// `DNAppLinksStartListening`. Anything malformed decodes to an empty list,
/// so a native bug can drop links but never throw into the listener.
List<String> decodeLinkList(String? json) {
  if (json == null || json.isEmpty) return const [];
  try {
    final decoded = jsonDecode(json);
    if (decoded is! List) return const [];
    return [
      for (final item in decoded)
        if (item is String && item.isNotEmpty) item,
    ];
  } on FormatException {
    return const [];
  }
}
