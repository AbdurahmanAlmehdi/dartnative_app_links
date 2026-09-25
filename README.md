# app_links_kit

Incoming links for [DartNative](https://dartnative.com) apps: iOS Universal
Links and custom URL schemes, Android App Links and deep links. The API is
[`app_links`](https://pub.dev/packages/app_links)' API, so link handling
ports from Flutter without code changes.

- Pure FFI: no method channels, no views.
- Zero native code in your app: the plugin hooks DartNative's scene delegate
  (iOS) and activity intents (Android) itself.
- Links that arrive before Dart listens (the cold-start link included) are
  buffered natively and delivered to the first stream listener.

## Install

```yaml
dependencies:
  app_links_kit:
    hosted: https://dartpub.dev
    version: ^0.1.0
```

Run `dn pub get`. The generated `DartNativePluginRegistrant.registerAll()`
loads the plugin; nothing else to call.

## Use

```dart
import 'package:app_links_kit/app_links_kit.dart';

final appLinks = AppLinks(); // singleton

// Cold-start AND warm links, from one place.
final sub = appLinks.uriLinkStream.listen((uri) {
  // route to the page for `uri`
});
```

| API | |
|---|---|
| `uriLinkStream` / `stringLinkStream` | Every incoming link. The first listener also gets the links received before anyone listened (including the launch link). Links `Uri.tryParse` rejects are dropped from `uriLinkStream` only. |
| `getInitialLink()` / `getInitialLinkString()` | The first link this process received, or `null`. |
| `getLatestLink()` / `getLatestLinkString()` | The most recent link, or `null`. |

**Gotcha (same as `app_links`):** subscribe to `uriLinkStream` only. If you
also call `getInitialLink()` you handle the cold-start link twice.

## Platform setup

### iOS

**Custom scheme** (`myapp://…`) — `ios/Runner/Info.plist`:

```xml
<key>CFBundleURLTypes</key>
<array>
  <dict>
    <key>CFBundleURLName</key>
    <string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
    <key>CFBundleURLSchemes</key>
    <array>
      <string>myapp</string>
    </array>
  </dict>
</array>
```

**Universal Links** (`https://example.com/app/…`):

1. `ios/Runner/Runner.entitlements`:

   ```xml
   <?xml version="1.0" encoding="UTF-8"?>
   <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
   <plist version="1.0">
   <dict>
     <key>com.apple.developer.associated-domains</key>
     <array>
       <string>applinks:example.com</string>
     </array>
   </dict>
   </plist>
   ```

   and set `CODE_SIGN_ENTITLEMENTS = Runner/Runner.entitlements` on the
   Runner target (all configurations). Enable **Associated Domains** on the
   App ID and regenerate the provisioning profile, or device builds fail at
   signing. Simulator builds sign ad hoc and won't catch that.
2. Serve `https://example.com/.well-known/apple-app-site-association`:
   HTTP 200, `application/json`, no redirect, no file extension.

   ```json
   {
     "applinks": {
       "details": [
         {
           "appIDs": ["TEAMID.com.example.app"],
           "components": [{ "/": "/app/*" }]
         }
       ]
     }
   }
   ```

   Apple's CDN caches this file: publish it before the build ships. For
   development, `applinks:example.com?mode=developer` plus Developer Mode on
   the device bypasses the CDN.

**No Swift changes.** The pod hooks `DartNativeSceneDelegate` at startup.
If your `SceneDelegate` implements `scene(_:openURLContexts:)` or
`scene(_:continue:)` itself, the pod wraps those too, so they keep working.

**Opting out of the hook.** Add `AppLinksKitAutoHook` = `NO` to
`Info.plist` and forward the links yourself:

```xml
<key>AppLinksKitAutoHook</key>
<false/>
```

```swift
import UIKit
import dartnative_ios
import app_links_kit

@objc class SceneDelegate: DartNativeSceneDelegate {
  override func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
                      options connectionOptions: UIScene.ConnectionOptions) {
    AppLinksKit.handle(connectionOptions)          // before super
    super.scene(scene, willConnectTo: session, options: connectionOptions)
  }

  func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
    AppLinksKit.handle(urlContexts: URLContexts)
  }

  func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
    AppLinksKit.handle(userActivity: userActivity)
  }
}
```

### Android

Keep `android:launchMode="singleTop"` on the activity (the DartNative
scaffold sets it), or a warm link stacks a second activity. Add intent
filters to the **existing** `<activity>` in
`android/app/src/main/AndroidManifest.xml`.

**App Links** (`https://example.com/app/…`):

```xml
<intent-filter android:autoVerify="true">
    <action android:name="android.intent.action.VIEW"/>
    <category android:name="android.intent.category.DEFAULT"/>
    <category android:name="android.intent.category.BROWSABLE"/>
    <data android:scheme="https" android:host="example.com" android:pathPrefix="/app"/>
</intent-filter>
```

and serve `https://example.com/.well-known/assetlinks.json` (200, JSON, no
redirect):

```json
[
  {
    "relation": ["delegate_permission/common.handle_all_urls"],
    "target": {
      "namespace": "android_app",
      "package_name": "com.example.app",
      "sha256_cert_fingerprints": ["AB:CD:…"]
    }
  }
]
```

Use the SHA-256 of the **Play App Signing** certificate (not the upload
key), plus your debug key if you want debug builds verified. Verification
runs at install time: reinstall after publishing the file, then check with
`adb shell pm get-app-links com.example.app`.

**Custom scheme** (`myapp://…`), no verification:

```xml
<intent-filter>
    <action android:name="android.intent.action.VIEW"/>
    <category android:name="android.intent.category.DEFAULT"/>
    <category android:name="android.intent.category.BROWSABLE"/>
    <data android:scheme="myapp"/>
</intent-filter>
```

**No Kotlin changes** if `MainActivity` extends `DartNativeActivity`. A custom
Activity calls `AppLinksKit.handleIntent(intent)` from `onCreate` and
`onNewIntent`.

Links reopened from Recents (`FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY`) and
share intents (`ACTION_SEND*`) are ignored, as in `app_links`. After the OS
kills and recreates the activity, the launch link is delivered again (also
as in `app_links`), so make link handling idempotent.

## Try it

The example registers the `applinkskit` scheme and shows the initial link and
every streamed link:

```sh
cd example && dn pub get && dn run -d <device>
# iOS simulator
xcrun simctl openurl <udid> "applinkskit://claim?code=WARM2"
# Android
adb shell am start -a android.intent.action.VIEW -d "applinkskit://claim?code=WARM2"
```

## Credits & license

- **[app_links](https://github.com/llfbandit/app_links) 7.2.1** by
  llfbandit, Apache-2.0. Adapted: the public Dart API names and signatures,
  doc-comment text, the initial/latest link bookkeeping and the Android
  intent filtering rules. The native plumbing is new, because upstream's is
  built on Flutter plugin registrars that DartNative doesn't have.
- **This package's own code:** MIT, see [LICENSE](LICENSE).
- The full notices are in [THIRD_PARTY_NOTICES](THIRD_PARTY_NOTICES). They
  ship with the package.
