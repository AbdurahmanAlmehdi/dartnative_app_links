import 'dart:async';

import 'package:app_links_kit/app_links_kit.dart';
import 'package:app_links_kit/src/backend.dart' show NoopAppLinksBackend;
import 'package:test/test.dart';

/// Mirrors the native state machine: links queue until Dart listens.
class FakeAppLinksBackend implements AppLinksBackend {
  String? initial;
  String? latest;
  final List<String> pending = [];
  void Function(String link)? _onLink;
  int startCalls = 0;
  int stopCalls = 0;

  bool get listening => _onLink != null;

  /// What native does when the OS hands the app a link.
  void receive(String link) {
    initial ??= link;
    latest = link;
    final onLink = _onLink;
    if (onLink == null) {
      pending.add(link);
    } else {
      onLink(link);
    }
  }

  @override
  String? initialLink() => initial;

  @override
  String? latestLink() => latest;

  @override
  List<String> startListening(void Function(String link) onLink) {
    startCalls++;
    _onLink = onLink;
    final drained = List<String>.of(pending);
    pending.clear();
    return drained;
  }

  @override
  void stopListening() {
    stopCalls++;
    _onLink = null;
  }
}

Future<void> _flush() => Future<void>.delayed(Duration.zero);

void main() {
  late FakeAppLinksBackend backend;
  late AppLinks links;

  setUp(() {
    backend = FakeAppLinksBackend();
    links = AppLinks.withBackend(backend);
  });

  group('getters', () {
    test('return null when no link arrived', () async {
      expect(await links.getInitialLink(), isNull);
      expect(await links.getInitialLinkString(), isNull);
      expect(await links.getLatestLink(), isNull);
      expect(await links.getLatestLinkString(), isNull);
    });

    test('map the empty string to null', () async {
      backend
        ..initial = ''
        ..latest = '';
      expect(await links.getInitialLinkString(), isNull);
      expect(await links.getLatestLink(), isNull);
    });

    test('keep the first link as initial and track the latest', () async {
      backend
        ..receive('applinkskit://claim?code=COLD1')
        ..receive('https://example.com/app/claim?code=WARM2');
      expect(
        await links.getInitialLink(),
        Uri.parse('applinkskit://claim?code=COLD1'),
      );
      expect(
        await links.getInitialLinkString(),
        'applinkskit://claim?code=COLD1',
      );
      expect(
        await links.getLatestLink(),
        Uri.parse('https://example.com/app/claim?code=WARM2'),
      );
      expect(
        await links.getLatestLinkString(),
        'https://example.com/app/claim?code=WARM2',
      );
    });

    test('return the raw string but a null Uri for an unparsable link',
        () async {
      backend.receive('http://[::1');
      expect(await links.getInitialLinkString(), 'http://[::1');
      expect(await links.getInitialLink(), isNull);
    });
  });

  group('streams', () {
    test('the first listener gets the buffered links, oldest first', () async {
      backend
        ..receive('applinkskit://a')
        ..receive('applinkskit://b');
      final got = <Uri>[];
      final sub = links.uriLinkStream.listen(got.add);
      await _flush();
      expect(got, [Uri.parse('applinkskit://a'), Uri.parse('applinkskit://b')]);
      expect(backend.pending, isEmpty);
      await sub.cancel();
    });

    test('a second listener does not re-drain the buffer', () async {
      backend.receive('applinkskit://cold');
      final first = <String>[];
      final second = <String>[];
      final a = links.stringLinkStream.listen(first.add);
      await _flush();
      final b = links.stringLinkStream.listen(second.add);
      await _flush();
      expect(first, ['applinkskit://cold']);
      expect(second, isEmpty);
      expect(backend.startCalls, 1);

      backend.receive('applinkskit://warm');
      await _flush();
      expect(first, ['applinkskit://cold', 'applinkskit://warm']);
      expect(second, ['applinkskit://warm']);
      await a.cancel();
      await b.cancel();
    });

    test('a link after listening is emitted once', () async {
      final got = <String>[];
      final sub = links.stringLinkStream.listen(got.add);
      await _flush();
      backend.receive('applinkskit://claim?code=WARM2');
      await _flush();
      expect(got, ['applinkskit://claim?code=WARM2']);
      await sub.cancel();
    });

    test('uriLinkStream drops what stringLinkStream still emits', () async {
      final uris = <Uri>[];
      final strings = <String>[];
      final u = links.uriLinkStream.listen(uris.add);
      final s = links.stringLinkStream.listen(strings.add);
      await _flush();
      backend
        ..receive('http://[::1')
        ..receive('applinkskit://ok');
      await _flush();
      expect(strings, ['http://[::1', 'applinkskit://ok']);
      expect(uris, [Uri.parse('applinkskit://ok')]);
      await u.cancel();
      await s.cancel();
    });

    test('empty links are never emitted', () async {
      backend.pending.add('');
      final got = <String>[];
      final sub = links.stringLinkStream.listen(got.add);
      await _flush();
      expect(got, isEmpty);
      await sub.cancel();
    });

    test('the last cancel stops listening; a re-listen drains the gap',
        () async {
      final first = <String>[];
      final sub = links.stringLinkStream.listen(first.add);
      await _flush();
      await sub.cancel();
      expect(backend.stopCalls, 1);
      expect(backend.listening, isFalse);

      backend.receive('applinkskit://while-away');
      expect(backend.pending, ['applinkskit://while-away']);

      final second = <String>[];
      final again = links.stringLinkStream.listen(second.add);
      await _flush();
      expect(first, isEmpty);
      expect(second, ['applinkskit://while-away']);
      expect(backend.startCalls, 2);
      await again.cancel();
    });
  });

  group('instances', () {
    test('AppLinks() is a singleton', () {
      expect(identical(AppLinks(), AppLinks()), isTrue);
    });

    test('withBackend instances are independent', () async {
      final other = FakeAppLinksBackend()..receive('applinkskit://other');
      final otherLinks = AppLinks.withBackend(other);
      expect(identical(otherLinks, links), isFalse);
      expect(identical(otherLinks, AppLinks()), isFalse);
      expect(await otherLinks.getInitialLinkString(), 'applinkskit://other');
      expect(await links.getInitialLinkString(), isNull);
    });

    test('off iOS/Android AppLinks() is a silent no-op', () async {
      final app = AppLinks();
      expect(await app.getInitialLink(), isNull);
      expect(await app.getLatestLinkString(), isNull);
      final got = <Uri>[];
      final sub = app.uriLinkStream.listen(got.add);
      await _flush();
      expect(got, isEmpty);
      await sub.cancel();
    });

    test('the no-op backend reports nothing', () {
      const noop = NoopAppLinksBackend();
      expect(noop.initialLink(), isNull);
      expect(noop.latestLink(), isNull);
      expect(noop.startListening((_) {}), isEmpty);
    });

    test('loadSymbols is safe to call off-device', () {
      AppLinksFFIBindings.loadSymbols();
      AppLinksFFIBindings.loadSymbols();
    });
  });
}
