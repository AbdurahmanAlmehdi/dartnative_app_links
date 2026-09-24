// Portions derived from app_links (https://github.com/llfbandit/app_links),
// Apache License 2.0. Modified: re-implemented over dart:ffi for DartNative.

import 'dart:async';

import 'package:meta/meta.dart';

import 'app_links_ffi_bindings.dart';
import 'backend.dart';

/// App links handler.
///
/// This class is a singleton and should be accessed using `AppLinks()`.
///
/// Subscribe to [uriLinkStream] alone to get both the link that cold-started
/// the app and every later one. Also calling [getInitialLink] handles the
/// cold-start link twice.
class AppLinks {
  /// The process-wide handler, backed by the native plugin.
  factory AppLinks() => _instance ??= AppLinks._(appLinksNativeBackend());

  /// A standalone handler over [backend], for tests. Not the singleton.
  @visibleForTesting
  factory AppLinks.withBackend(AppLinksBackend backend) => AppLinks._(backend);

  AppLinks._(this._backend);

  static AppLinks? _instance;

  final AppLinksBackend _backend;

  // One source for both streams, so a link is drained from native once no
  // matter which stream the app listens to (upstream has the same sharing).
  late final StreamController<String> _links = StreamController.broadcast(
    onListen: _startListening,
    onCancel: _backend.stopListening,
  );

  /// Gets the initial/first link received.
  ///
  /// returns [Uri] or `null`
  Future<Uri?> getInitialLink() async =>
      _parse(_nonEmpty(_backend.initialLink()));

  /// Gets the initial/first link received.
  ///
  /// returns URI as String or `null`
  Future<String?> getInitialLinkString() async =>
      _nonEmpty(_backend.initialLink());

  /// Gets the latest link received.
  ///
  /// returns [Uri] or `null`
  Future<Uri?> getLatestLink() async =>
      _parse(_nonEmpty(_backend.latestLink()));

  /// Gets the latest link received.
  ///
  /// returns URI as String or `null`
  Future<String?> getLatestLinkString() async =>
      _nonEmpty(_backend.latestLink());

  /// Stream for receiving all incoming URI events as [String].
  ///
  /// The first listener also receives the links that arrived before anyone
  /// listened, including the one that launched the app.
  Stream<String> get stringLinkStream => _links.stream;

  /// Stream for receiving all incoming URI events as [Uri].
  ///
  /// Same events as [stringLinkStream]; links [Uri.tryParse] rejects are
  /// dropped.
  Stream<Uri> get uriLinkStream => _links.stream.transform(
    StreamTransformer<String, Uri>.fromHandlers(
      handleData: (link, sink) {
        final uri = Uri.tryParse(link);
        if (uri != null) sink.add(uri);
      },
    ),
  );

  void _startListening() {
    // Native routes live links to _emit before returning the backlog, but it
    // fires them on a later main-loop turn, so the backlog stays first.
    final backlog = _backend.startListening(_emit);
    backlog.forEach(_emit);
  }

  void _emit(String link) {
    if (link.isNotEmpty) _links.add(link);
  }

  static String? _nonEmpty(String? link) =>
      link == null || link.isEmpty ? null : link;

  static Uri? _parse(String? link) => link == null ? null : Uri.tryParse(link);
}
