## 0.1.0

- First release: `AppLinks` with `app_links`' API — `getInitialLink`,
  `getInitialLinkString`, `getLatestLink`, `getLatestLinkString`,
  `uriLinkStream`, `stringLinkStream`.
- iOS: Universal Links and custom schemes, cold and warm, with no app code.
  The pod hooks `DartNativeSceneDelegate`; `AppLinksKitAutoHook = NO` in
  Info.plist opts out, and `AppLinksKit.handle(...)` forwards manually.
- Android: App Links and deep links through `DartNativeActivity`'s intent
  events; `AppLinksKit.handleIntent` for custom activities. Links reopened
  from Recents and share intents are ignored.
- Links received before Dart listens are buffered natively (up to 16) and
  delivered to the first stream listener. Hot-restart safe.
