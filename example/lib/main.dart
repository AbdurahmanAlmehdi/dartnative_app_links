import 'dart:async';

import 'package:app_links_kit/app_links_kit.dart';
import 'package:dartnative/dartnative.dart';

import 'dartnative_plugin_registrant.dart';

// Try it:
//   iOS:     xcrun simctl openurl <udid> "applinkskit://claim?code=WARM2"
//   Android: adb shell am start -a android.intent.action.VIEW \
//              -d "applinkskit://claim?code=WARM2"
void main() {
  DartNativePluginRegistrant.registerAll();
  SystemChrome.defaultStyle = const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarBrightness: Brightness.light,
    statusBarIconBrightness: Brightness.dark,
    systemNavigationBarColor: Colors.transparent,
    systemNavigationBarIconBrightness: Brightness.dark,
  );
  runApp(const LinksScreen());
}

const _ink = Color(0xFF111111);
const _muted = Color(0xFF6B6B70);

/// Shows the initial link and every link the stream delivers.
class LinksScreen extends StatefulWidget {
  const LinksScreen({super.key});

  @override
  State<LinksScreen> createState() => _LinksScreenState();
}

class _LinksScreenState extends State<LinksScreen> {
  final _appLinks = AppLinks();
  final _streamed = <String>[];
  StreamSubscription<Uri>? _sub;
  String? _initial;

  @override
  void initState() {
    super.initState();
    // A real app listens to uriLinkStream only (it replays the cold-start
    // link); the demo also reads getInitialLink to show both on screen.
    _sub = _appLinks.uriLinkStream.listen((uri) {
      dnLog('[app_links_kit_example] stream: $uri');
      setState(() => _streamed.add(uri.toString()));
    });
    _appLinks.getInitialLinkString().then((link) {
      dnLog('[app_links_kit_example] initial: $link');
      setState(() => _initial = link);
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      brightness: Brightness.light,
      backgroundColor: const Color(0xFFFFFFFF),
      appBar: AppBar(
        title: const Text(
          'app_links_kit',
          style: TextStyle(
            color: _ink,
            fontSize: 17,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
      // No scroll view: on the iOS 26.0 simulator runtime DartNative's
      // bar scroll-edge effect calls a selector that runtime lacks and aborts.
      body: Container(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _Label('Initial link'),
            _Value(_initial ?? 'none'),
            const SizedBox(height: 24),
            _Label('Stream (${_streamed.length})'),
            if (_streamed.isEmpty) const _Value('nothing yet'),
            for (final (i, link) in _streamed.indexed)
              _Value('${i + 1}. $link'),
          ],
        ),
      ),
    );
  }
}

class _Label extends StatelessWidget {
  const _Label(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: const TextStyle(
      color: _muted,
      fontSize: 14,
      fontWeight: FontWeight.w600,
    ),
  );
}

class _Value extends StatelessWidget {
  const _Value(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 6),
    child: Text(text, style: const TextStyle(color: _ink, fontSize: 17)),
  );
}
