package com.dartnative.applinks

import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin

/**
 * Registered through `pluginClass` in pubspec.yaml. Engine attach runs in
 * `DartNativeApplication.onCreate`, before any Activity exists, so the
 * intent listener is in place for the launch intent.
 */
class DartNativeAppLinksPlugin : FlutterPlugin {
    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        try {
            // Only a JVM-side load fires JNI_OnLoad (plugin_development.md §10).
            System.loadLibrary("app_links_kit")
        } catch (e: UnsatisfiedLinkError) {
            Log.e(AppLinksKit.TAG, "Failed to load libapp_links_kit.so: ${e.message}")
        }
        AppLinksKit.install()
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {}
}
