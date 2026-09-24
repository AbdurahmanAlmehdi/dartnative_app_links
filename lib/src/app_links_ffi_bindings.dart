import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import 'backend.dart';
import 'codec.dart';

typedef _SetDispatcherC = Void Function(Int64);
typedef _SetDispatcherD = void Function(int);
typedef _StringC = Pointer<Utf8> Function();
typedef _VoidC = Void Function();
typedef _VoidD = void Function();

/// (token, type, payload): token is always 0 (one global stream).
typedef _DispatchC = Void Function(Int64, Int32, Pointer<Utf8>);

const int _typeLink = 1;

// The one dispatcher native calls. Native invokes it synchronously, so the
// payload is only valid during this call: copy it before returning.
void _dispatch(int token, int type, Pointer<Utf8> payload) {
  if (type != _typeLink || payload == nullptr) return;
  AppLinksFFIBindings._onLink?.call(payload.toDartString());
}

final Pointer<NativeFunction<_DispatchC>> _dispatchPtr =
    Pointer.fromFunction<_DispatchC>(_dispatch);

/// Resolves the native symbols. The app's generated registrant calls
/// [loadSymbols]; apps use `AppLinks` instead.
abstract final class AppLinksFFIBindings {
  static bool _loaded = false;
  static bool _attempted = false;

  static late final Pointer<Utf8> Function() _getInitialLink;
  static late final Pointer<Utf8> Function() _getLatestLink;
  static late final Pointer<Utf8> Function() _startListening;
  static late final _VoidD _stopListening;

  static void Function(String link)? _onLink;

  /// Loads the native symbols and hands native the dispatcher. Idempotent;
  /// a no-op off iOS/Android or when the native library is missing.
  static void loadSymbols() {
    if (_attempted) return;
    _attempted = true;
    if (!Platform.isIOS && !Platform.isAndroid) return;
    try {
      final lib = Platform.isAndroid
          ? DynamicLibrary.open('libapp_links_kit.so')
          : DynamicLibrary.process();
      _getInitialLink = lib.lookupFunction<_StringC, _StringC>(
        'DNAppLinksGetInitialLink',
      );
      _getLatestLink = lib.lookupFunction<_StringC, _StringC>(
        'DNAppLinksGetLatestLink',
      );
      _startListening = lib.lookupFunction<_StringC, _StringC>(
        'DNAppLinksStartListening',
      );
      _stopListening = lib.lookupFunction<_VoidC, _VoidD>(
        'DNAppLinksStopListening',
      );
      lib.lookupFunction<_SetDispatcherC, _SetDispatcherD>(
        'DNAppLinksSetDispatcher',
      )(_dispatchPtr.address);
      _loaded = true;
    } on Object catch (e) {
      // Missing .so or symbols: stay silent-but-safe, as the no-op matrix
      // promises (getters return null, the stream never emits).
      stderr.writeln('[app_links_kit] native symbols unavailable: $e');
    }
  }

  static String? _takeString(Pointer<Utf8> Function() fn) {
    final ptr = fn();
    if (ptr == nullptr) return null;
    try {
      return ptr.toDartString();
    } finally {
      // Native strdup'd it; calloc.free is libc free on POSIX.
      calloc.free(ptr);
    }
  }
}

class _FfiAppLinksBackend implements AppLinksBackend {
  const _FfiAppLinksBackend();

  // Lazily, so an AppLinks() created before registerAll() still works.
  bool get _ready {
    AppLinksFFIBindings.loadSymbols();
    return AppLinksFFIBindings._loaded;
  }

  @override
  String? initialLink() => _ready
      ? AppLinksFFIBindings._takeString(AppLinksFFIBindings._getInitialLink)
      : null;

  @override
  String? latestLink() => _ready
      ? AppLinksFFIBindings._takeString(AppLinksFFIBindings._getLatestLink)
      : null;

  @override
  List<String> startListening(void Function(String link) onLink) {
    if (!_ready) return const [];
    AppLinksFFIBindings._onLink = onLink;
    return decodeLinkList(
      AppLinksFFIBindings._takeString(AppLinksFFIBindings._startListening),
    );
  }

  @override
  void stopListening() {
    if (!_ready) return;
    AppLinksFFIBindings._stopListening();
    AppLinksFFIBindings._onLink = null;
  }
}

/// The backend `AppLinks()` uses: native on iOS/Android, a no-op elsewhere.
AppLinksBackend appLinksNativeBackend() => Platform.isIOS || Platform.isAndroid
    ? const _FfiAppLinksBackend()
    : const NoopAppLinksBackend();
