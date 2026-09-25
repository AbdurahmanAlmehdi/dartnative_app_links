// Portions derived from app_links (https://github.com/llfbandit/app_links),
// Apache License 2.0. Modified: re-implemented over dart:ffi for DartNative.

package com.dartnative.applinks

import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.util.Log
import com.dartnative.runtime.DNActivityEvents
import org.json.JSONArray
import java.lang.ref.WeakReference

/**
 * Link state for the process: the initial and latest link, plus the links
 * received while Dart is not listening. Every entry point takes the lock, so
 * the JNI calls (Dart thread) and intents (main thread) never interleave.
 */
object AppLinksKit {
    internal const val TAG = "AppLinksKit"
    private const val MAX_PENDING = 16
    private const val TYPE_LINK = 1

    private val main = Handler(Looper.getMainLooper())
    private val lock = Any()

    private var installed = false
    private var lastIntent: WeakReference<Intent>? = null
    private var initialLink: String? = null
    private var latestLink: String? = null
    private val pending = ArrayDeque<String>()
    private var listening = false

    // The dispatcher slot (plugin_async_callbacks.md): the pointer is valid
    // only while DN_IsolateGen still equals the generation captured with it.
    private var dispatcherPtr = 0L
    private var dispatcherGen = 0L

    /** Subscribes to DartNativeActivity's intents. Idempotent. */
    internal fun install() {
        synchronized(lock) {
            // DNActivityEvents has no remove call, so never add a second one.
            if (installed) return
            installed = true
        }
        try {
            // Replays the sticky intent, so the order against onCreate is moot.
            DNActivityEvents.addIntentListener { handleIntent(it) }
        } catch (e: Throwable) {
            Log.e(TAG, "DNActivityEvents unavailable; call AppLinksKit.handleIntent: $e")
        }
    }

    /**
     * Feeds an intent to the link stream. Call it from `onCreate` and
     * `onNewIntent` only if your Activity does not extend DartNativeActivity.
     */
    @JvmStatic
    fun handleIntent(intent: Intent?) {
        val link = linkOf(intent) ?: return
        synchronized(lock) {
            // The sticky replay and a re-dispatch of getIntent() hand over the
            // same instance; deliver its link once.
            if (lastIntent?.get() === intent) return
            lastIntent = WeakReference(intent)
            if (initialLink == null) initialLink = link
            latestLink = link
            if (listening) main.post { deliver(link) } else enqueue(link)
        }
    }

    private fun linkOf(intent: Intent?): String? {
        if (intent == null) return null
        // Reopened from Recents: the old link is not a new visit.
        if (intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY != 0) return null
        when (intent.action) {
            Intent.ACTION_SEND, Intent.ACTION_SEND_MULTIPLE, Intent.ACTION_SENDTO -> return null
        }
        return intent.dataString?.takeIf { it.isNotEmpty() }
    }

    private fun deliver(link: String) {
        synchronized(lock) {
            val ptr = dispatcherPtr
            if (!listening || ptr == 0L || dispatcherGen != nativeIsolateGen()) {
                enqueue(link)
                return
            }
            nativeDeliver(ptr, 0L, TYPE_LINK, link.toByteArray(Charsets.UTF_8))
        }
    }

    private fun enqueue(link: String) {
        pending.addLast(link)
        while (pending.size > MAX_PENDING) pending.removeFirst()
    }

    // --- JNI surface, called from dn_app_links_bridge.cpp -------------------

    @JvmStatic
    fun setDispatcher(ptr: Long) = synchronized(lock) {
        dispatcherPtr = ptr
        dispatcherGen = nativeIsolateGen()
        // A new Dart session starts deaf: links queue until it subscribes.
        listening = false
    }

    @JvmStatic
    fun initialLinkBytes(): ByteArray? = synchronized(lock) { initialLink?.toByteArray(Charsets.UTF_8) }

    @JvmStatic
    fun latestLinkBytes(): ByteArray? = synchronized(lock) { latestLink?.toByteArray(Charsets.UTF_8) }

    @JvmStatic
    fun startListening(): ByteArray = synchronized(lock) {
        listening = true
        val json = JSONArray(pending.toList()).toString()
        pending.clear()
        json.toByteArray(Charsets.UTF_8)
    }

    @JvmStatic
    fun stopListening() = synchronized(lock) { listening = false }

    @JvmStatic
    private external fun nativeIsolateGen(): Long

    @JvmStatic
    private external fun nativeDeliver(ptr: Long, token: Long, type: Int, payload: ByteArray)
}
