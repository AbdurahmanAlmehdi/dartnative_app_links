import 'package:app_links_kit/src/codec.dart';
import 'package:test/test.dart';

void main() {
  test('decodes a JSON string array in order', () {
    expect(
      decodeLinkList(r'["applinkskit:\/\/a","https://example.com/b?x=1"]'),
      ['applinkskit://a', 'https://example.com/b?x=1'],
    );
  });

  test('keeps non-ASCII links intact', () {
    expect(decodeLinkList('["https://example.com/مرحبا/😀"]'), [
      'https://example.com/مرحبا/😀',
    ]);
  });

  test('an empty array, null or empty input decode to []', () {
    expect(decodeLinkList('[]'), isEmpty);
    expect(decodeLinkList(null), isEmpty);
    expect(decodeLinkList(''), isEmpty);
  });

  test('malformed payloads decode to []', () {
    expect(decodeLinkList('not json'), isEmpty);
    expect(decodeLinkList('{"a":1}'), isEmpty);
    expect(decodeLinkList('"applinkskit://a"'), isEmpty);
  });

  test('skips non-string and empty entries', () {
    expect(decodeLinkList('["applinkskit://a", 1, null, ""]'), [
      'applinkskit://a',
    ]);
  });
}
