// Portions derived from app_links (https://github.com/llfbandit/app_links),
// Apache License 2.0. Modified: re-implemented over dart:ffi for DartNative.

import Foundation
import UIKit

// All state below is touched on the main thread only: UIKit delivers links
// there and Dart runs its FFI calls there.
private var initialLink: String?
private var latestLink: String?
private var pending: [String] = []
private var listening = false
private let maxPending = 16
private let typeLink: Int32 = 1

// The dispatcher slot (plugin_async_callbacks.md): the framework zeroes it on
// hot restart, so it is re-read before every fire and never copied.
private let dispatcherSlot: UnsafeMutablePointer<Int64> = {
  let p = UnsafeMutablePointer<Int64>.allocate(capacity: 1)
  p.pointee = 0
  return p
}()
private var slotRegistered = false

private typealias Dispatch = @convention(c) (Int64, Int32, UnsafePointer<CChar>) -> Void

private func receive(_ link: String) {
  guard !link.isEmpty else { return }
  if initialLink == nil { initialLink = link }
  latestLink = link
  if listening {
    // Async so a link never re-enters Dart from inside a UIKit callback that
    // is itself under a Dart frame.
    DispatchQueue.main.async { deliver(link) }
  } else {
    enqueue(link)
  }
}

private func deliver(_ link: String) {
  let addr = dispatcherSlot.pointee
  guard listening, addr != 0 else {
    enqueue(link)
    return
  }
  link.withCString { unsafeBitCast(addr, to: Dispatch.self)(0, typeLink, $0) }
}

private func enqueue(_ link: String) {
  pending.append(link)
  if pending.count > maxPending { pending.removeFirst(pending.count - maxPending) }
}

private func onMain(_ body: @escaping () -> Void) {
  if Thread.isMainThread { body() } else { DispatchQueue.main.async(execute: body) }
}

private func dup(_ s: String?) -> UnsafeMutablePointer<CChar>? {
  guard let s, !s.isEmpty else { return nil }
  return strdup(s)
}

/// Receives links from the scene hook (ALKSceneHook.m) or manual forwarding.
@_cdecl("DNAppLinksReceive")
public func DNAppLinksReceive(_ url: UnsafePointer<CChar>?) {
  guard let url else { return }
  let link = String(cString: url)
  onMain { receive(link) }
}

@_cdecl("DNAppLinksSetDispatcher")
public func DNAppLinksSetDispatcher(_ callbackPtr: Int64) {
  dispatcherSlot.pointee = callbackPtr
  // A new Dart session starts deaf: links queue until it subscribes.
  listening = false
  if !slotRegistered {
    slotRegistered = true
    typealias RegFn = @convention(c) (UnsafeMutablePointer<Int64>) -> Void
    if let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "DNRegisterAsyncDispatcherSlot") {
      unsafeBitCast(sym, to: RegFn.self)(dispatcherSlot)
    }
  }
}

@_cdecl("DNAppLinksGetInitialLink")
public func DNAppLinksGetInitialLink() -> UnsafeMutablePointer<CChar>? {
  dup(initialLink)
}

@_cdecl("DNAppLinksGetLatestLink")
public func DNAppLinksGetLatestLink() -> UnsafeMutablePointer<CChar>? {
  dup(latestLink)
}

@_cdecl("DNAppLinksStartListening")
public func DNAppLinksStartListening() -> UnsafeMutablePointer<CChar>? {
  listening = true
  let backlog = pending
  pending.removeAll()
  guard let data = try? JSONSerialization.data(withJSONObject: backlog, options: [.withoutEscapingSlashes]),
        let json = String(data: data, encoding: .utf8)
  else { return strdup("[]") }
  return strdup(json)
}

@_cdecl("DNAppLinksStopListening")
public func DNAppLinksStopListening() {
  listening = false
}

/// Manual forwarding for apps that set `AppLinksKitAutoHook` to `NO` in
/// Info.plist. Call these from your `SceneDelegate`.
@objc public final class AppLinksKit: NSObject {
  /// Call in `scene(_:willConnectTo:options:)`, before `super`.
  @objc public static func handle(_ connectionOptions: UIScene.ConnectionOptions) {
    handle(urlContexts: connectionOptions.urlContexts)
    connectionOptions.userActivities.forEach { handle(userActivity: $0) }
  }

  /// Call in `scene(_:openURLContexts:)`.
  @objc(handleURLContexts:)
  public static func handle(urlContexts: Set<UIOpenURLContext>) {
    urlContexts.forEach { handle(url: $0.url) }
  }

  /// Call in `scene(_:continue:)`. Only web-browsing activities carry links.
  @objc(handleUserActivity:)
  public static func handle(userActivity: NSUserActivity) {
    guard userActivity.activityType == NSUserActivityTypeBrowsingWeb,
          let url = userActivity.webpageURL else { return }
    handle(url: url)
  }

  /// Feeds any URL into the link stream.
  @objc(handleURL:)
  public static func handle(url: URL) {
    let link = url.absoluteString
    onMain { receive(link) }
  }
}
