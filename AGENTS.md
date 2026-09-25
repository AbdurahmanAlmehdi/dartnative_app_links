# app_links_kit — agent guide

`app_links`' API for DartNative: incoming Universal Links / App Links and
custom schemes. A pure-FFI plugin with iOS (Swift + ObjC) and Android
(Kotlin + C++ JNI) sources. Published on dartpub.dev. The design, with
every decision, is `doc/design.md`.

## Toolchain

Use `dn`, never `flutter` or `dart` directly:

```sh
dn pub get --no-example
dn analyze --no-pub
dn test --no-pub
(cd example && dn pub get && dn run -d <device>)
dn plugin build        # packs dist/ without publishing
```

Publish with `COPYFILE_DISABLE=1 dn publish`. Without it, macOS `tar` adds
`._*` metadata files to the archives dartpub keeps permanently. Bump
`version` in `pubspec.yaml` and `ios/app_links_kit.podspec`, and add the
matching `CHANGELOG.md` section first.

A plain `dn pub get` at the root also resolves `example/` with plain pub,
which can't find the DartNative platform packages. Resolve the two
separately, as above.

## Layout

- `lib/src/app_links.dart`: `AppLinks` (singleton, one broadcast controller
  feeding both streams).
- `lib/src/backend.dart`: `AppLinksBackend` seam + the no-op backend.
- `lib/src/app_links_ffi_bindings.dart`: `loadSymbols`, the dispatcher, the
  FFI backend.
- `lib/src/codec.dart`: decodes the JSON backlog from `StartListening`.
- `ios/Classes/ALKSceneHook.m`: `+load` hook on `DartNativeSceneDelegate`.
- `ios/Classes/AppLinksKit.swift`: state, `@_cdecl DNAppLinks*`, the manual
  `AppLinksKit.handle(...)` API.
- `android/src/main/kotlin/.../AppLinksKit.kt`: `DNActivityEvents` listener,
  intent filtering, state. `DartNativeAppLinksPlugin.kt` loads the `.so`.
- `android/src/main/cpp/dn_app_links_bridge.cpp`: `DNAppLinks*` exports over
  JNI, the isolate-generation check, delivery.
- `test/`: pure Dart tests with a fake backend. No device needed.
- `example/`: a `dn create` app using the package by path; scheme
  `applinkskit`.

## Invariants — don't break these

- **Names and behaviour match `app_links` 7.** Adding API is fine; renaming
  or changing semantics isn't.
- **Native buffers until Dart listens.** `StartListening` returns the backlog
  and flips `listening`; `SetDispatcher` (a new Dart session) resets it.
- **The dispatcher slot rules** (`plugin_async_callbacks.md`): one slot, never
  copied, re-checked (slot ≠ 0 on iOS, `DN_IsolateGen` on Android) before
  every fire, fired on the main thread. A fire that fails the check re-queues
  the link instead of dropping it.
- **iOS captures before the original `willConnectTo` runs**: the original
  starts Dart.
- **Android installs one intent listener per process**: `DNActivityEvents`
  has no remove call.
- **Strings cross JNI as UTF-8 byte arrays**, never `GetStringUTFChars`.
- Files with logic derived from `app_links` keep the Apache-2.0 header.

## Conventions

- Comments explain *why*, not what. Keep inline comments to 3 lines at most.
  Public API gets short dartdoc.
- Every change to behaviour gets a test in `test/`, and a `CHANGELOG.md`
  entry under the next version. `dn publish` reads that section.
