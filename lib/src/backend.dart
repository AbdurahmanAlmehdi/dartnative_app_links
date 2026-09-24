/// Native-facing surface behind `AppLinks`.
///
/// Production talks to the FFI bindings; tests inject a fake through
/// `AppLinks.withBackend`.
abstract class AppLinksBackend {
  /// The first link the app received in this process, or null.
  String? initialLink();

  /// The most recent link the app received, or null.
  String? latestLink();

  /// Marks Dart as listening, routes later links to [onLink], and returns
  /// (and clears) the links native buffered while nobody listened, oldest
  /// first.
  List<String> startListening(void Function(String link) onLink);

  /// Stops delivery; native buffers links again until the next
  /// [startListening].
  void stopListening();
}

/// Backend for platforms without native support (desktop, web, `dn test`).
class NoopAppLinksBackend implements AppLinksBackend {
  const NoopAppLinksBackend();

  @override
  String? initialLink() => null;

  @override
  String? latestLink() => null;

  @override
  List<String> startListening(void Function(String link) onLink) => const [];

  @override
  void stopListening() {}
}
