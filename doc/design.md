# app_links_kit — design

Status: implemented as 0.1.0 (2026-09-25). Researched 2026-09-25 for Daftar
port ticket P3-B2. Implementation decisions are recorded in §11.

---

## 1. Summary

| | |
|---|---|
| Package | `app_links_kit` |
| Repo (local) | `~/dev/personal/lbytech/dartnative_app_links` |
| Repo (future) | `github.com/AbdurahmanAlmehdi/dartnative_app_links` |
| Registry | dartpub.dev (`hosted: https://dartpub.dev`), same as `lucide_kit` / `riverpod_kit` |
| Scope | Incoming links for DartNative apps: iOS Universal Links and custom URL schemes, Android App Links and deep links (`Intent.data`). iOS and Android only. |
| Shape | Pure-FFI plugin (`plugin_development.md` §8): Dart API class + `@_cdecl` Swift/ObjC on iOS, Kotlin + a small C++ JNI shim on Android. No views, no method channels. |

The kit gives you `app_links`' API (`AppLinks().uriLinkStream`,
`getInitialLink()`, …), so Daftar's link handling ports without code changes.
The hard part is on the native side. iOS: DartNative's `DartNativeSceneDelegate`
implements only `scene(_:willConnectTo:options:)`, and plugins have no way to
receive scene events. Android: core dispatches intents, but only through an
undocumented listener API.

## 2. Prior art

### DartNative catalog

On dartpub.dev today, `q=app_links`, `q=deep_link` and `q=links` return only
`dartnative_url_launcher` (outgoing), `app_settings_kit`,
`dartnative_app_review`, `geolocator_kit` and `native_rich_text`. None of them
receives links. The first-party list in `skills/dart-native/SKILL.md` has no
incoming-link plugin either. The port plan says the same
(`docs/architecture/dartnative-port-plan.md` §2.2: "DartNative has no
incoming-link plugin in the catalog").

### Flutter `app_links`

| | |
|---|---|
| Version read | **7.2.1** (latest on pub.dev, `https://pub.dev/api/archives/app_links-7.2.1.tar.gz`) |
| Also read | `app_links_platform_interface` (latest), which holds the doc templates and the `Uri.tryParse` behaviour |
| License | **Apache License 2.0** (SPDX `Apache-2.0`, as the GitHub API also reports) |
| Copyright holder | **None filled in.** The shipped `LICENSE` is the bare Apache 2.0 text. Its appendix still reads `Copyright [yyyy] [name of copyright owner]`. There is no `NOTICE` file (404 on GitHub `main`) and no copyright header in any source file. The author and owner is **llfbandit** (`github.com/llfbandit/app_links`, created 2020-11-26). |
| Portable? | **Yes.** Apache-2.0 is on the allow-list. |

What upstream does, reduced to the parts that matter here:

- **iOS** (`AppLinksIosPlugin.swift`) is a `FlutterPlugin` that registers with
  `registrar.addApplicationDelegate` and `registrar.addSceneDelegate`, so it
  gets `scene(_:willConnectTo:options:)` (it reads `connectionOptions.urlContexts`
  and `.userActivities`), `scene(_:openURLContexts:)`, `scene(_:continue:)` and
  the `application(...)` equivalents. Each one funnels into `handleLink(url:)`,
  which sets `latestLink`, sets `initialLink` if it is still nil, and pushes the
  link to the `EventSink` when there is one. `onListen` replays `initialLink`
  once (`initialLinkSent`).
- **Android** (`AppLinksPlugin.java`) is `ActivityAware` +
  `NewIntentListener`. It reads `activity.getIntent()` on attach (cold start)
  and every `onNewIntent` (warm). `handleIntent` drops intents with
  `FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY` (reopened from Recents) and
  `ACTION_SEND` / `SEND_MULTIPLE` / `SENDTO`, then takes
  `intent.getDataString()`. It keeps the same initial/latest/"sent" state as
  iOS.
- **Dart** (`AppLinks`) is a singleton. It wraps the platform streams in
  broadcast controllers. `uriLinkStream` is `stringLinkStream` passed through
  `Uri.tryParse`, with unparsable links dropped.

None of this runs under DartNative: `FlutterPlugin` registrars,
`addSceneDelegate`, `ActivityAware` and method and event channels are all
unavailable (SKILL.md: "`MethodChannel` + plugins using one … crash at
launch"). We port the Dart API shape and doc text, plus the link bookkeeping
and intent-filtering rules. The native plumbing is written from scratch.

## 3. Public API

### Kept from `app_links` (same names and semantics)

```dart
/// App links handler. Singleton: `AppLinks()` always returns the same object.
class AppLinks {
  factory AppLinks();

  /// Gets the initial/first link received. Returns null if the app was not
  /// opened by a link.
  Future<Uri?> getInitialLink();
  Future<String?> getInitialLinkString();

  /// Gets the latest link received.
  Future<Uri?> getLatestLink();
  Future<String?> getLatestLinkString();

  /// All incoming links. The first listener also gets the initial link if no
  /// listener has received it yet, then every later link.
  Stream<Uri> get uriLinkStream;      // unparsable links are dropped (Uri.tryParse), as upstream
  Stream<String> get stringLinkStream;
}
```

- The getters stay `Future`s even though the native calls are synchronous.
  That keeps them source-compatible with `app_links`, so call sites port
  without edits.
- Empty strings map to `null`, as upstream does.
- The stream semantics match upstream: subscribe to `uriLinkStream` **only**
  and you get cold-start and warm links from one place. If you also call
  `getInitialLink()` you handle the cold-start link twice. That is an upstream
  gotcha, and the README repeats it.

### Dropped

| Upstream | Why |
|---|---|
| `AppLinksPlatform` / `app_links_platform_interface`, `plugin_platform_interface` dependency | There is one implementation (FFI) and no federated plugins in DartNative. The seam lives inside the package as `AppLinksBackend` (below). |
| Linux / macOS / Windows / web | DartNative targets iOS and Android only. |
| Swift `AppLinks.shared.getLink(launchOptions:)` | Deprecated upstream. The pre-scene `launchOptions` path does not apply, because DartNative apps are always scene-based (`UIApplicationSceneManifest` in the scaffold). |
| Swift `enabled`, `defaultUrlHandling`, `urlHandledCallBack`, the `Bool` "handled" return values | They exist to arbitrate between Flutter plugins sharing the delegate chain. DartNative has no such chain. Opting out of the automatic hook is an Info.plist key instead (§4.1). |

### Added

```dart
/// Test seam, used the same way as local_auth_kit's LocalAuthentication.withBackend.
@visibleForTesting
factory AppLinks.withBackend(AppLinksBackend backend); // non-singleton instance

/// Native-facing surface. Production = FFI; tests inject a fake.
abstract class AppLinksBackend {
  String? initialLink();
  String? latestLink();
  /// Marks Dart as listening and returns (and clears) the links native
  /// buffered while nobody was listening, oldest first.
  List<String> startListening(void Function(String link) onLink);
  void stopListening();
}

/// Registrant entry point (called by DartNativePluginRegistrant.registerAll()).
abstract final class AppLinksFFIBindings {
  static void loadSymbols();
}
```

Swift escape hatch, for apps that turn the automatic hook off (§4.1):

```swift
// In the app's SceneDelegate, only when AppLinksKitAutoHook = NO
AppLinksKit.handle(connectionOptions)          // in scene(_:willConnectTo:options:) BEFORE super
AppLinksKit.handle(urlContexts: URLContexts)   // in scene(_:openURLContexts:)
AppLinksKit.handle(userActivity: userActivity) // in scene(_:continue:)
```

Kotlin escape hatch, for an Activity that does not extend `DartNativeActivity`:
`AppLinksKit.handleIntent(intent)` from `onCreate` and `onNewIntent`.

## 4. Native side

### 4.1 iOS

**Where links arrive (scene-based app):**

| Situation | UIKit entry point | Payload |
|---|---|---|
| Cold start via Universal Link | `scene(_:willConnectTo:options:)` | `connectionOptions.userActivities`, where `activityType == NSUserActivityTypeBrowsingWeb`, `webpageURL` |
| Cold start via custom scheme | `scene(_:willConnectTo:options:)` | `connectionOptions.urlContexts` → `.url` |
| Warm Universal Link | `scene(_:continue:)` | `NSUserActivity.webpageURL` (same `activityType` filter) |
| Warm custom scheme | `scene(_:openURLContexts:)` | `Set<UIOpenURLContext>` → `.url` |

`application(_:open:options:)` and `application(_:continue:…)` are **not** called
for scene-based apps, and `launchOptions` carries no URL.

**What DartNative gives us.** Read from the installed
`dartnative_ios.framework` (`arm64-apple-ios.swiftinterface` and
`dartnative_ios-Swift.h`):

- `open class DartNativeAppDelegate: FlutterAppDelegate` overrides only
  `didFinishLaunchingWithOptions`, `didCreateEngine`,
  `configurationForConnecting`.
- `open class DartNativeSceneDelegate: UIResponder, UIWindowSceneDelegate`
  (ObjC name `_TtC14dartnative_ios23DartNativeSceneDelegate`) implements
  **only** `scene(_:willConnectTo:options:)`, which builds the window, installs
  the runtime and starts the engine. There is no `openURLContexts`, no
  `continue`, no plugin hook, and no notification.
- The binary has no `openURL` / `userActivity` / swizzling symbols, only the
  `UIWindowSceneDelegate` protocol metadata strings.
- iOS DartNative plugins are `ffiPlugin: true`, with no `FlutterPluginRegistrar`,
  so upstream's `addSceneDelegate` route is closed. The delegate is also not a
  `FlutterSceneDelegate`.

**Hook options considered:**

| Option | Verdict |
|---|---|
| NotificationCenter (`UIScene.willConnectNotification`, `didActivateNotification`…) | **Rejected.** No UIScene notification carries `connectionOptions`, `URLContexts` or a user activity. It cannot see a link at all. |
| App-side forwarding: the app's `SceneDelegate` overrides three methods and calls `AppLinksKit.handle(...)` | Works and is explicit. But it is three overrides, not one line, and it needs `import app_links_kit` in Runner. It also breaks the DartNative plugin contract "App developers touch nothing" and "Never ship a Swift file for app devs to drag into `Runner/`" (`plugin_development.md` §3c, §10). **Kept as the documented fallback.** |
| **Pod-side method injection on `DartNativeSceneDelegate` at `+load`** | **Chosen.** Zero app changes. Every DartNative app's `SceneDelegate` subclasses this class, so hooking the base class covers all apps. |

**Chosen mechanism.** An ObjC file in the pod, `ios/Classes/ALKSceneHook.m`, does
the hooking in `+load`. `+load` runs before `main()`, and so before
`UIApplicationMain` connects the scene.

1. Read `AppLinksKitAutoHook` from `Info.plist`. If it is `NO`, stop (the
   opt-out).
2. Get the class with
   `cls = NSClassFromString(@"_TtC14dartnative_ios23DartNativeSceneDelegate")`,
   falling back to `@"dartnative_ios.DartNativeSceneDelegate"`. If it is
   missing, log `[app_links_kit]` and stop. Never crash.
3. **Wrap** `scene:willConnectToSession:options:`, which the base class
   implements. The wrapper captures `options.URLContexts` and
   `options.userActivities`, **then** calls the original IMP. Capturing first
   matters: the original starts the Dart runtime, and the link has to be stored
   before any Dart code can ask for it.
4. **Add or wrap** `scene:openURLContexts:` and `scene:continueUserActivity:`.
   Use `class_addMethod` with `imp_implementationWithBlock` when the class does
   not implement the selector *itself* (check with `class_copyMethodList`, not
   `class_getInstanceMethod`, which also finds superclass methods). If a future
   DartNative release does implement it, swap the IMP with
   `method_setImplementation` and call the original from the block. Type
   encodings come from `protocol_getMethodDescription(@protocol(UISceneDelegate), sel, NO, YES)`.
5. Every captured URL goes to the Swift core through a C symbol,
   `DNAppLinksReceive(const char *url)`, which is `@_cdecl` in
   `AppLinksKit.swift`. The ObjC file does not import Swift headers.

There is no compile-time coupling to `dartnative_ios`: the class is looked up
by name at runtime, the same principle as the `dlsym` rule in §3b.

**Swift core (`AppLinksKit.swift`)** holds the per-process state, and touches it
only on the main thread:

- `initialLink: String?` is set once, from the first link ever received.
- `latestLink: String?`.
- `initialDelivered: Bool` means the initial link has reached a stream
  listener.
- `pending: [String]` holds links received while Dart is not listening. It is
  capped at 16, dropping the oldest.
- `listening: Bool`.
- The dispatcher slot (§5).

`DNAppLinksReceive` updates `initialLink` and `latestLink`. It then either fires
the link to Dart (slot ≠ 0 and `listening`) or appends it to `pending`. The fire
is `DispatchQueue.main.async`, so it never runs inside a UIKit callback that
happens to sit under a Dart frame.

**Cold start end to end:** `+load` hooks the class. UIKit calls
`willConnectTo`. The wrapper stores the link as `initialLink` and in `pending`,
then the original starts Dart. `main()` calls
`DartNativePluginRegistrant.registerAll()`, which reaches
`AppLinksFFIBindings.loadSymbols()` and sets the slot. The app subscribes to
`uriLinkStream`, whose first listen calls `DNAppLinksStartListening()`. That
returns `["https://daftaar.ly/app/claim?code=X"]` and the stream emits it.

**Warm start:** UIKit calls `scene(_:continue:)`, which becomes
`DNAppLinksReceive`, then a fire through the slot, then the Dart stream.

**What the consuming app adds (iOS):**

- `ios/Runner/Runner.entitlements` →
  `com.apple.developer.associated-domains` = `applinks:<host>` (+
  `webcredentials:<host>` if wanted), and `CODE_SIGN_ENTITLEMENTS =
  Runner/Runner.entitlements` on the Runner target. Enable **Associated Domains**
  on the App ID and regenerate the provisioning profile. Otherwise the device
  build fails at signing. A simulator build signs ad hoc and will not catch it.
- Custom schemes only: `CFBundleURLTypes` → `CFBundleURLSchemes` in `Info.plist`.
- The server must serve `https://<host>/.well-known/apple-app-site-association`:
  status 200, `application/json`, no redirect, no extension. Its `applinks`
  must name `<TeamID>.<bundle id>` with `components` that cover the linked
  paths. Apple's CDN caches the file, so publish it before the build ships.
  For development, `applinks:<host>?mode=developer` together with Developer Mode
  on the device skips the CDN.
- **No Swift changes.** If `AppLinksKitAutoHook = NO`, add the three
  forwarding calls from §3 instead.
- If the app's own `SceneDelegate` implements `scene(_:openURLContexts:)` or
  `scene(_:continue:)`, the pod wraps those implementations too (see §11,
  "Decided: hook the manifest delegate class"). An override of
  `willConnectTo` must still call `super`, because `super` starts the runtime.

### 4.2 Android

**Where links arrive:** cold start is `Activity.getIntent()` in `onCreate`;
warm start (with `launchMode="singleTop"`) is `onNewIntent(intent)`. The link is
`intent.dataString`.

**What DartNative gives us.** Read from the installed `dartnative_android.aar`
with `javap`:

- `DartNativeApplication.onCreate()` creates and caches the `FlutterEngine`.
  That runs every `pluginClass` `FlutterPlugin.onAttachedToEngine`, so a
  plugin attaches **before any Activity exists**.
- `DartNativeActivity.onCreate` calls
  `DNActivityEvents.dispatchIntent(getIntent())`.
  `DartNativeActivity.onNewIntent` calls `super`, then `setIntent(intent)`,
  then `DNActivityEvents.dispatchIntent(intent)`.
- `com.dartnative.runtime.DNActivityEvents` has
  `public static fun addIntentListener(l: (Intent) -> Unit)`. It keeps a
  **sticky intent**: `dispatchIntent` stores the last intent, and
  `addIntentListener` immediately replays it to the new listener. There is no
  `removeIntentListener`. `dartnative_notifications` uses the same API; its
  README says "`DartNativeActivity` dispatches activity events to plugins
  (`DNActivityEvents` in the core runtime)".

**Hook options considered:**

| Option | Verdict |
|---|---|
| **`DNActivityEvents.addIntentListener`** from `onAttachedToEngine` | **Chosen.** First-party, the same mechanism notifications uses, and the sticky replay covers every ordering. |
| `Application.ActivityLifecycleCallbacks` + `ComponentActivity.addOnNewIntentListener` (androidx `OnNewIntentProvider`) | Fallback if `DNActivityEvents` changes. It needs no DartNative dependency. |
| App-side `MainActivity.onNewIntent` override | Not needed. It is the manual escape hatch only, for a custom Activity. |

**Kotlin:**

- `DartNativeAppLinksPlugin : FlutterPlugin`. Its `onAttachedToEngine` does
  `System.loadLibrary("app_links_kit")`, then `AppLinksKit.install()`. Install
  is guarded by a process-wide `installed` flag, because listeners cannot be
  removed, so the plugin must never add a second one.
- `AppLinksKit.onIntent(intent)` applies upstream's filter rules and then
  de-duplicates:
  - Ignore `FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY` (reopened from Recents).
  - Ignore `ACTION_SEND`, `ACTION_SEND_MULTIPLE` and `ACTION_SENDTO`.
  - Ignore intents where `dataString` is null.
  - De-duplicate on the **Intent instance**. The sticky replay and a
    re-dispatch of the same `getIntent()` must not deliver the same link
    twice. Keep a weak reference to the last intent handled.
  - Then apply the same state machine as iOS (initial / latest / pending /
    listening / slot) and fire through the slot on the main `Handler`.

**Cold start end to end:** `Application.onCreate` creates the engine, whose
`onAttachedToEngine` runs `install()`; at that point the sticky intent is null.
Then `MainActivity.onCreate` dispatches the launch intent, and the plugin
stores the link. Dart `main()` calls `loadSymbols()`, and the first listen
drains `pending`.

**Warm start:** `onNewIntent` → `dispatchIntent` → `onIntent` → the slot fires,
and the Dart stream emits.

**What the consuming app adds (Android):**

- Keep `android:launchMode="singleTop"` on the activity; the DartNative
  scaffold already sets it. Without it a warm link stacks a second activity.
- An `<intent-filter android:autoVerify="true">` on the **existing**
  `<activity>` in `AndroidManifest.xml`:
  ```xml
  <intent-filter android:autoVerify="true">
      <action android:name="android.intent.action.VIEW"/>
      <category android:name="android.intent.category.DEFAULT"/>
      <category android:name="android.intent.category.BROWSABLE"/>
      <data android:scheme="https" android:host="daftaar.ly" android:pathPrefix="/app"/>
  </intent-filter>
  ```
  Custom scheme: a second filter with `<data android:scheme="myapp"/>` and no
  `autoVerify`.
- The server must serve `https://<host>/.well-known/assetlinks.json` (200, JSON,
  no redirect) with `delegate_permission/common.handle_all_urls` for the
  package, plus the SHA-256 of the **Play App Signing** certificate, not the
  upload key. Verification runs at install time, so reinstall after publishing
  the file. Debug builds verify only if their fingerprint is listed.
- No Kotlin changes if `MainActivity` extends `DartNativeActivity`.

## 5. FFI surface

Prefix `DNAppLinks…`, matching community practice (`DNLocalAuth…`). Both
platforms export the same C symbols. iOS resolves them through
`DynamicLibrary.process()`, Android through
`DynamicLibrary.open('libapp_links_kit.so')` (`plugin_development.md` §10 A3).

```c
// Dart → native
void  DNAppLinksSetDispatcher(int64_t fnPtr);  // store in the slot; register the slot once; listening = false
char* DNAppLinksGetInitialLink(void);          // strdup'd or NULL; Dart frees
char* DNAppLinksGetLatestLink(void);           // strdup'd or NULL; Dart frees
char* DNAppLinksStartListening(void);          // listening = true; returns a strdup'd JSON array of pending links (and the
                                               // initial link if not yet delivered), then clears pending; Dart frees
void  DNAppLinksStopListening(void);           // listening = false; later links queue again

// native → Dart (the dispatcher, plugin_async_callbacks.md step 1)
typedef void (*DNAppLinksDispatch)(int64_t token, int32_t type, const char* payload);
//   token = 0 (single global stream), type = 1 (link), payload = the URL string
```

**Async callback: the dispatcher slot, not `NativeCallable.listener`.** The link
stream is native calling Dart later, so it falls under
`plugin_async_callbacks.md` option 3.

- Dart has **one** top-level `_dispatch(int token, int type, Pointer<Utf8>)`.
  Its pointer comes from `Pointer.fromFunction`. `loadSymbols()` passes the
  address to native once per Dart session.
- **iOS:** the slot is a heap `UnsafeMutablePointer<Int64>`, registered once with
  `DNRegisterAsyncDispatcherSlot` (found with `dlsym(RTLD_DEFAULT, …)`). Before
  every fire, read the slot fresh and drop the fire on 0.
- **Android:** Kotlin stores `dispatcherPtr` together with
  `dispatcherGen = nativeIsolateGen()` (C++ `dlsym(RTLD_DEFAULT,
  "DN_IsolateGen")`). Before every fire, re-check the generation. The C++
  `nativeDeliver(ptr, …)` invokes the pointer. (`DNCallbackFire.fireString`
  would also be restart-safe, but the slot keeps both platforms the same.)
- The three rules hold. The raw address is never copied out of the slot. The
  slot is registered once. The check runs on every fire, on the main thread.
  Both platforms run Dart on the main (platform) thread, so every state change
  and fire happens there too.

**String lifetime (§9):**

- The dispatcher is a synchronous `Pointer.fromFunction` call, so the payload
  can be stack-scoped: `withCString` on iOS, `GetStringUTFChars`/`Release`
  around the call on Android. Dart copies it with `toDartString()` during the
  call, so there is nothing to free.
- On Android, pass the URL as a UTF-8 `jbyteArray` and NUL-terminate it in C++.
  `GetStringUTFChars` returns *modified* UTF-8, which corrupts non-BMP
  characters in IRIs.
- Values **returned** by `Get…Link` and `StartListening` are `strdup`'d.
  Dart copies them, then calls `calloc.free(ptr)` (`package:ffi` `calloc.free`
  is libc `free` on POSIX, which matches `strdup`). NULL means none.

**Links that arrive before Dart listens.** Native buffers them in `pending`
(cold start, a link during the gap before the first `listen`, a link during a
hot restart while the slot is 0). The first stream listener gets the buffer,
oldest first, from `DNAppLinksStartListening()`. The drain and every fire
happen on the main thread, so no link can land between the drain and
`listening = true`. The Dart broadcast controller calls `StopListening()` from
`onCancel`, when the last listener leaves.

**Hot restart.**

- iOS: the framework zeroes the slot. Android: it bumps `DN_IsolateGen`.
- Native state survives the restart. `initialLink` stays, and so does
  `initialDelivered`, so the new session's stream does not replay the cold
  link. `getInitialLink()` still returns it, as it does in Flutter.
- The new `loadSymbols()` → `SetDispatcher` resets `listening = false`, so
  links queue until the new session subscribes.

**pubspec.yaml.** This is the block `dn pub get` reads; the first-party and
`local_auth_kit` pubspecs nest it under `dartnative:`:

```yaml
name: app_links_kit
description: >-
  Incoming links for DartNative apps: iOS Universal Links and custom URL
  schemes, Android App Links and deep links, with the app_links API.
version: 0.1.0
homepage: https://github.com/AbdurahmanAlmehdi/dartnative_app_links
repository: https://github.com/AbdurahmanAlmehdi/dartnative_app_links
issue_tracker: https://github.com/AbdurahmanAlmehdi/dartnative_app_links/issues
topics: [dartnative, deeplink, app-links, universal-links]

environment:
  sdk: ^3.9.0

dependencies:
  ffi: ^2.1.0
  meta: ^1.15.0          # @visibleForTesting

dev_dependencies:
  lints: ^6.0.0
  test: ^1.25.0

dartnative:
  plugin:
    platforms:
      ios:
        ffiPlugin: true
      android:
        package: com.dartnative.applinks
        pluginClass: DartNativeAppLinksPlugin
  registrant:
    imports:
      - package:app_links_kit/app_links_kit.dart
    calls:
      - AppLinksFFIBindings.loadSymbols();
```

`loadSymbols()` starts with the `Platform.isIOS || Platform.isAndroid` guard,
because `registerAll()` runs on every platform.

**Podspec** (`ios/app_links_kit.podspec`):

```ruby
Pod::Spec.new do |s|
  s.name             = 'app_links_kit'
  s.version          = '0.1.0'
  s.summary          = 'Incoming Universal Links and custom URL schemes for DartNative.'
  s.homepage         = 'https://github.com/AbdurahmanAlmehdi/dartnative_app_links'
  s.license          = { :type => 'MIT', :file => '../LICENSE' }
  s.author           = 'Abdurahman Almehdi'
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*.{swift,h,m}'
  s.frameworks       = 'UIKit', 'Foundation'
  s.platform         = :ios, '15.0'
  s.swift_version    = '5.9'
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386',
  }
end
```

No `s.dependency 'dartnative_ios'`: that would be a circular dependency (§3b).
The class and `DNRegisterAsyncDispatcherSlot` are resolved at runtime.

**Gradle** (`android/build.gradle`, following the `local_auth_kit` layout):

```groovy
group 'com.dartnative.applinks'
version '1.0-SNAPSHOT'

buildscript {
    repositories { google(); mavenCentral() }
    dependencies {
        classpath 'com.android.tools.build:gradle:8.11.1'
        classpath 'org.jetbrains.kotlin:kotlin-gradle-plugin:2.1.0'
    }
}
apply plugin: 'com.android.library'
apply plugin: 'kotlin-android'

android {
    namespace 'com.dartnative.applinks'
    compileSdkVersion 35
    ndkVersion = "28.2.13676358"
    compileOptions { sourceCompatibility JavaVersion.VERSION_17; targetCompatibility JavaVersion.VERSION_17 }
    kotlinOptions { jvmTarget = '17' }
    sourceSets { main.java.srcDirs += 'src/main/kotlin' }
    defaultConfig { minSdkVersion 24 }   // see §11
    externalNativeBuild { cmake { path "CMakeLists.txt"; version "3.22.1" } }
}

dependencies {
    compileOnly project(':dartnative_android')   // DNActivityEvents; the app provides it (§4e, §10 A4)
    implementation 'androidx.core:core-ktx:1.12.0'
}
```

`CMakeLists.txt` builds `libapp_links_kit.so` from
`src/main/cpp/dn_app_links_bridge.cpp`, linking `log` via `find_library`, not
`find_package(JNI)`. `JNI_OnLoad` caches the `AppLinksKit` class and its
methods.

## 6. No-op matrix

| Environment | Behaviour |
|---|---|
| iOS device or simulator, DartNative scene app | Full support. |
| iOS, `AppLinksKitAutoHook = NO`, app forwards manually | Full support. |
| iOS, `DartNativeSceneDelegate` class not found (framework renamed it) | The hook logs once and does nothing. The getters return `null`, the stream never emits, nothing crashes. |
| iOS, the app's `SceneDelegate` overrides `openURLContexts` / `continue` without `super` | Warm links of that kind are missed. Cold links still work through `willConnectTo`. Documented. |
| Android, `MainActivity extends DartNativeActivity` | Full support. |
| Android, custom Activity | Nothing arrives until the app calls `AppLinksKit.handleIntent`. Documented. |
| Android, `libapp_links_kit.so` fails to load | Logged. `loadSymbols` catches the lookup failure; getters return `null` and the stream stays empty. |
| macOS / Linux / Windows / web / `dart test` | `loadSymbols()` returns early at the platform guard. `AppLinks()` getters return `null`, and streams are empty and never close. |
| Hot restart (debug) | The slot is invalidated and links queue. The new session re-attaches, and the initial link is not replayed to the stream. |

## 7. Third-party components and licenses

| Component | What we take | License | Notice |
|---|---|---|---|
| `app_links` 7.2.1 by llfbandit (`github.com/llfbandit/app_links`) | Public Dart API names and signatures. Doc-comment text, adapted. The link bookkeeping (initial / latest / delivered once) and Android intent filtering (history flag, `SEND*` actions, `dataString`). No native source is copied: the iOS and Android plumbing is new, because upstream's is Flutter-registrar based. | Apache-2.0 | Required |
| `app_links_platform_interface` (same author) | Doc templates (`{@template app_links.*}` text) and the `Uri.tryParse` drop rule | Apache-2.0 | Covered by the same notice |

Package code is **MIT**, `Copyright (c) 2026 Abdurahman Almehdi` (as in
`dartnative_lucide`). The files that carry derived logic
(`lib/src/app_links.dart`, `AppLinksKit.swift`, `AppLinksKit.kt`) get a header,
to satisfy Apache-2.0 §4(b):

```
// Portions derived from app_links (https://github.com/llfbandit/app_links),
// Apache License 2.0. Modified: re-implemented over dart:ffi for DartNative.
```

**Copyright line for THIRD_PARTY_NOTICES.** Upstream ships **no** copyright
line to copy verbatim: its LICENSE still has the unfilled template
`Copyright [yyyy] [name of copyright owner]`, and there is no NOTICE file. So
the attribution line is ours:

```
app_links — Copyright (c) llfbandit and the app_links contributors
https://github.com/llfbandit/app_links
Licensed under the Apache License, Version 2.0
```

Follow it with the full Apache-2.0 text, the same layout as
`dartnative_lucide/THIRD_PARTY_NOTICES` (a banner, the component and URL, then
the license text). README "Credits and licenses" section:

- **app_links** by llfbandit: API shape and link-handling rules, Apache-2.0.
- **This package's own code**: MIT, see LICENSE.
- The full notices are in THIRD_PARTY_NOTICES. They ship with the package, and
  DartNative adds them to your app's licence notices.

## 8. Repo file layout

```
dartnative_app_links/
├── .gitignore  .pubignore            # as dartnative_lucide (.dart_tool/, build/, .claude/, .cursor/, .github/, tool/, doc/)
├── AGENTS.md  CLAUDE.md (@AGENTS.md)
├── .claude/settings.json  .cursor/rules/app_links_kit.mdc  .github/copilot-instructions.md
├── CHANGELOG.md  LICENSE (MIT)  README.md  THIRD_PARTY_NOTICES
├── analysis_options.yaml  pubspec.yaml
├── doc/design.md                     # this file
├── lib/
│   ├── app_links_kit.dart            # exports AppLinks, AppLinksBackend, AppLinksFFIBindings
│   └── src/
│       ├── app_links.dart            # singleton, broadcast controllers, Uri.tryParse
│       ├── backend.dart              # AppLinksBackend + _NoopBackend
│       ├── app_links_ffi_bindings.dart  # loadSymbols, slot dispatcher, FfiBackend
│       └── codec.dart                # JSON array decode for StartListening
├── ios/
│   ├── app_links_kit.podspec
│   └── Classes/
│       ├── AppLinksKit.swift         # state, @_cdecl DNAppLinks*, slot, public handle(...) API
│       └── ALKSceneHook.m            # +load hook on DartNativeSceneDelegate
├── android/
│   ├── build.gradle  CMakeLists.txt
│   └── src/main/
│       ├── AndroidManifest.xml       # empty, no permissions
│       ├── cpp/dn_app_links_bridge.cpp   # JNI_OnLoad, DNAppLinks* exports, isolate-gen, deliver
│       └── kotlin/com/dartnative/applinks/
│           ├── DartNativeAppLinksPlugin.kt   # FlutterPlugin: loadLibrary + install
│           └── AppLinksKit.kt                # DNActivityEvents listener, filtering, state, slot
├── skills/app_links_kit/SKILL.md
├── test/
│   ├── app_links_test.dart           # fake-backend behaviour
│   └── codec_test.dart
└── example/                          # `dn create` app, path dep, scheme applinkskit:// + a demo https host
```

## 9. Test plan

**Pure Dart (`dn test`, no device)**, with a `FakeAppLinksBackend` that records
calls and lets a test push links:

- `getInitialLink` / `getLatestLink`: null, the empty string → null, a valid
  URI, an unparsable string (the `Uri` getter returns null and the `String`
  getter returns the raw value).
- The first `listen` drains the pending list in order, and a second listener
  on the broadcast stream does not re-drain it.
- A link pushed after listening is emitted once. `uriLinkStream` drops an
  unparsable link that `stringLinkStream` still emits.
- The last `cancel` calls `stopListening`, and a re-listen drains links queued
  in between.
- The singleton: `AppLinks()` is identical across calls, while `withBackend`
  instances are independent.
- The no-op backend on a non-mobile platform: nulls, and a silent stream.
- The codec: JSON array decode, an empty array, and a malformed payload → `[]`.

**Native state machine.** On iOS, a small XCTest in the example exercising
`DNAppLinksReceive` / `StartListening` without UI. On Android, a JVM unit test
of `AppLinksKit.onIntent` filtering: the history flag, the `SEND` actions,
null data, and the duplicate Intent instance.

**Example app** (`example/`). Declare `CFBundleURLSchemes = applinkskit` and an
Android `<data android:scheme="applinkskit"/>` filter. The app shows the
initial link, the latest link and a live log of `uriLinkStream`.

**Device and simulator validation:**

```bash
# iOS simulator — custom scheme (no association needed)
xcrun simctl openurl booted "applinkskit://claim?code=X"              # warm: app running
xcrun simctl terminate booted <bundle-id>
xcrun simctl openurl booted "applinkskit://claim?code=X"              # cold

# iOS — Universal Link (needs AASA naming this bundle id; ?mode=developer for dev)
xcrun simctl openurl booted "https://daftaar.ly/app/claim?code=X"
# (Real device: tap the link in Notes/Messages — typing it in Safari's bar does not trigger UL.)

# Android — deep link, warm and cold
adb shell am start -W -a android.intent.action.VIEW -d "applinkskit://claim?code=X" <package>
adb shell am force-stop <package>
adb shell am start -W -a android.intent.action.VIEW -d "applinkskit://claim?code=X" <package>

# Android — App Link (https). Naming the package targets the app even before verification:
adb shell am start -W -a android.intent.action.VIEW \
  -c android.intent.category.BROWSABLE -d "https://daftaar.ly/app/claim?code=X" <package>
adb shell pm get-app-links <package>                       # want: daftaar.ly verified
adb shell pm verify-app-links --re-verify <package>
adb shell pm set-app-links-user-selection --user cur --package <package> true daftaar.ly  # dev fallback
```

Hot-restart check (`plugin_async_callbacks.md` checklist): run the app, press
capital `R`, fire a warm link during and after the restart. There should be no
`Callback invoked after it has been deleted`, and the link should arrive after
the restart. Also check the Recents check: open via link, back out, reopen from
Recents; the link must **not** be re-delivered.

**Daftar DoD (P3-B2):** a tap on the claim link opens `ClaimInvitePage` with the
code prefilled, on both platforms, cold and warm, signed-out and after the
intro. See §10 for which URL that can actually be.

## 10. Risks and open questions

1. **Blocking for the ticket's validation URL: path mismatch.** The live
   association claims **only `/app/*`**:
   `apps/landing/app/.well-known/apple-app-site-association/route.ts` has
   `components: [{ "/": "/app/*" }]`, and the Flutter manifest has
   `pathPrefix="/app"`. `apps/mobile/docs/deep-links.md` explains the choice
   ("Claim `/app/*`, not `/get`"). So `https://daftaar.ly/claim?code=X`
   **opens the website on both platforms whatever the plugin does**. Either
   change the link to `https://daftaar.ly/app/claim?code=X` (recommended; it
   fits the existing namespace and needs no server change), or widen the AASA
   and intent filter to `/claim*`. The DoD in
   `docs/architecture/dartnative-port-tickets.md` P3-B2 needs one of these.
2. **Blocking for Universal and App Links in the port app: identity mismatch.**
   `mobile_native` is `ly.daftaar.daftarNative` (iOS) and
   `ly.daftaar.daftar_native` (Android). The AASA names only
   `AFBD5TBR5U.ly.daftaar.app`, and assetlinks names only `ly.daftaar.app` with
   the Play signing key. `mobile_native` also has **no `Runner.entitlements`**
   (no `CODE_SIGN_ENTITLEMENTS`). Until the port ships under `ly.daftaar.app`,
   validating https links needs one of: adding the native app's ids and its
   debug/upload SHA-256 to both well-known files (a landing deploy), or
   validating with a custom scheme instead. Needs a decision: does the port
   take over `ly.daftaar.app` at cutover?
3. **The iOS hook depends on a private class name.** It relies on
   `_TtC14dartnative_ios23DartNativeSceneDelegate` existing and on UIKit
   probing the delegate for the added selectors after `+load`. If DartNative
   renames or restructures the class, the hook turns into a no-op (logged, no
   crash). Mitigations: the `AppLinksKitAutoHook = NO` + manual forwarding
   escape hatch, a startup log line, and filing upstream for a first-class
   `DartNativeSceneDelegate` plugin hook (the P1 upstream-reports list is the
   place).
4. **The Android API is undocumented.** `DNActivityEvents.addIntentListener`
   is public but not in `plugin_development.md`. Its sticky replay, and the
   lack of a remove call, are inferred from bytecode. The fallback is the
   lifecycle-callbacks + `OnNewIntentProvider` route.
   `compileOnly project(':dartnative_android')` assumes the plugin loader
   exposes that Gradle project name. Verify on the first build, and fall back
   to `compileOnly files(...)` or reflection if not.
5. **Re-delivery after process death on Android.** When the OS kills and
   recreates the activity, `onCreate` re-dispatches the original link intent as
   a new Intent object, so the link is delivered again. Upstream behaves the
   same. Acceptable for claim (idempotent prefill); document it.
6. **"OTP link" in the ticket is undefined.** The phone OTP is an SMS code, not
   a link (domain-bound `@daftaar.ly #123456` autofill needs only
   `webcredentials`, not this plugin). Is it the email-verification or
   magic-link flow (`/verify-pending`)? Its path must also live under `/app/`.
7. **App side, outside this package but needed for the DoD:**
   - `ClaimInvitePage` has no `code` parameter; it needs `initialCode` through
     `RouteArgs`.
   - The root router must let a signed-out user reach `/claim` past the
     first-run `/intro` redirect. The Flutter `router.dart` already flags this:
     "a deep link into '/claim' will bounce through here too".
   - Subscribe to `uriLinkStream` once, in `root_router.dart`, and do not also
     call `getInitialLink()`.
8. **Shipping.** Entitlement and manifest changes are native, so for the
   Flutter-side equivalent they need a release (a version-name bump plus
   `release_notes.txt`), not a Shorebird patch, per the project `CLAUDE.md`.
   The same applies to whichever build first carries this plugin.

## 11. Decisions made during implementation

Nobody was available to answer the open questions while this was built, so
these were decided and recorded here.

- **Decided: hook the manifest delegate class too (iOS).** A Swift override of
  a non-`dynamic` `@objc` method calls `super` directly, not through
  `objc_msgSend`, so a base-class hook alone misses an app `SceneDelegate` that
  overrides `willConnectTo`. The Swift compiler also rejects `super` for
  `openURLContexts` / `continue`, because the base class does not declare them.
  So `+load` also reads `UIApplicationSceneManifest` →
  `UISceneDelegateClassName`, and wraps any of the three selectors that the
  class implements *itself*. A per-payload guard (a weak reference to the last
  `options` / `NSSet` / `NSUserActivity`) stops a double capture when both
  hooks run.
- **Decided: no `initialDelivered` flag.** `pending` is the only replay
  source. A link received while Dart is not listening (the cold-start link
  included) enters `pending`, and the first `StartListening` drains it once.
  After a hot restart `pending` is already empty, so the cold link is not
  replayed, while `getInitialLink()` still returns it.
- **Decided: a failed fire re-queues.** If the check before a fire fails
  (slot 0 or generation moved, or `listening` went false between queueing
  and firing), the link goes back to `pending` instead of being dropped.
  Links that arrive during a hot restart therefore reach the new session.
- **Decided: Android state takes one lock.** JNI calls (Dart thread) and
  intents (main thread) share `AppLinksKit`'s state, so every entry point
  synchronises. Fires still post to the main `Handler`.
- **Decided: UTF-8 byte arrays both ways on Android.** The getters and
  `StartListening` return `ByteArray`s, which C++ copies into `malloc`'d,
  NUL-terminated buffers that Dart frees. Delivery passes a `ByteArray` as
  well. No `GetStringUTFChars` anywhere.
- **Decided: `JNI_OnLoad` never fails the load.** A missing class or method
  is logged, and the `DNAppLinks*` exports then return NULL or no-op. This
  matches the no-op matrix instead of throwing `UnsatisfiedLinkError`.
- **Decided: the FFI backend loads lazily.** `AppLinks()` built before
  `registerAll()` still works, because every backend call runs the idempotent
  `loadSymbols()` first. `loadSymbols()` catches lookup failures (logged to
  stderr), so a missing `.so` degrades to nulls and a silent stream.
- **Decided: Android `minSdkVersion 24`, not 26.** DartNative's app template
  defaults to minSdk 24, so a 26 library fails the manifest merge in every
  stock app. The plugin uses no API above 24.
- **Decided: `NoopAppLinksBackend` stays internal.** The package exports only
  `AppLinks`, `AppLinksBackend` and `AppLinksFFIBindings`.
- **Decided: `AppLinksKit.handle(url:)` (Swift) is public too.** It lets an app
  with its own URL source feed the stream. The ObjC names are
  `handleURLContexts:`, `handleUserActivity:` and `handleURL:`.
- **Decided: the example uses the custom scheme only.** There is no demo
  https host: Universal Links and App Links cannot be verified without a
  served AASA or assetlinks.json anyway.
- **Decided (§10.4): `compileOnly project(':dartnative_android')` works.** The
  plugin loader exposes the prebuilt `.aar` as that Gradle project. Verified
  by the example's Android build.
- **Deferred to the Daftar integration (§10.1, 10.2, 10.6, 10.7, 10.8):** the
  `/app/claim` path, the bundle and package identity, the OTP link, the router
  changes and shipping as a release are app decisions. The lead owns them.
- **Framework gap found:** on the iOS 26.0 simulator runtime (23A5276e),
  an `AppBar` over a `SingleChildScrollView` aborts in DartNative's
  `_dnEnsureBarScrollEdgeEffect`, with
  `-[UIScrollEdgeElementContainerInteraction setScrollView:]: unrecognized
  selector`. It needs a `respondsToSelector:` guard upstream. The example
  avoids a scroll view.
- **Verified (2026-09-25).** iOS 26.0 simulator, debug build: a cold start
  from `applinkskit://claim?code=COLD1` shows COLD1 as the initial link and
  as the first stream event, and a warm `WARM2` arrives on the stream. iOS 26
  asks "Open in …?" before handing a custom scheme to the app. Android 16
  emulator (Pixel Tablet AVD), release APK: the same cold and warm results,
  with COLD1 delivered once, so the sticky replay is de-duplicated. Universal
  Links and App Links still need a served AASA or assetlinks.json, so they are
  unverified.
