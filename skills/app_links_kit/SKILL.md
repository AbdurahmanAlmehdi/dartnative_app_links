---
name: app_links_kit
description: Handle incoming deep links, Universal Links, App Links or custom URL schemes in a DartNative app with app_links_kit. Use when porting `app_links` code to DartNative, wiring a link to a screen, or when a link opens the website or does nothing.
---

# Incoming links in DartNative with app_links_kit

## Porting from Flutter

1. Replace `package:app_links/app_links.dart` with
   `package:app_links_kit/app_links_kit.dart`. Every name stays the same.
2. `dn pub get`. The registrant loads the plugin; no native code to add.
3. Keep the platform setup you already had (entitlements, AASA,
   `CFBundleURLTypes`, Android intent filters). See the README.

## Rules

- Subscribe to `AppLinks().uriLinkStream` once, near the router. It delivers
  the cold-start link too. Don't also call `getInitialLink()`, or the launch
  link is handled twice.
- iOS: a `SceneDelegate` override of `scene(_:willConnectTo:options:)` must
  still call `super` (it starts Dart). Only with `AppLinksKitAutoHook = NO`
  do you forward links with `AppLinksKit.handle(...)`.
- Android: `MainActivity` must extend `DartNativeActivity` and keep
  `launchMode="singleTop"`; otherwise call `AppLinksKit.handleIntent`.

## When a link does nothing

- The https link opens the browser: the domain association is wrong, not
  the plugin. Check the AASA / assetlinks.json names this bundle id or
  package + signing key, and that the path is in the claimed prefix.
- Test the plugin without a server: a custom scheme with
  `xcrun simctl openurl <udid> "myapp://x"` or
  `adb shell am start -a android.intent.action.VIEW -d "myapp://x"`.
