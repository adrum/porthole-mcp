package dev.porthole

import android.content.Context
import android.content.pm.ApplicationInfo
import android.util.Log

/**
 * Porthole's Android harness: lets coding agents inspect and drive this app
 * through the Porthole hub on the developer's Mac.
 *
 * Add it as a debug-only dependency and it starts itself (see
 * [PortholeInitializer]); no code is needed. It connects to the hub through
 * the abstract socket `porthole-mcp`, which the hub maps to its own socket
 * with `adb reverse` for every emulator and USB device it sees.
 */
object Porthole {
    internal const val TAG = "Porthole"

    /** The device-side socket the hub's `adb reverse` provides. */
    const val SOCKET_NAME = "porthole-mcp"

    private var client: HubClient? = null
    internal val hooks = Hooks()

    /**
     * Connect to the hub, now and whenever it (re)starts. Called for you at
     * launch; safe to call again. Does nothing in a build that isn't
     * debuggable, so a release build never connects even if it includes the
     * library by mistake.
     */
    @JvmStatic
    @Synchronized
    fun start(context: Context) {
        if (client != null) return
        val app = context.applicationContext
        if (app.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE == 0) {
            Log.w(TAG, "not started: this build isn't debuggable; Porthole only runs in debug builds")
            return
        }
        if (System.getenv("PORTHOLE_MCP_DISABLE") == "1") {
            Log.i(TAG, "disabled by PORTHOLE_MCP_DISABLE")
            return
        }
        Windows.install(app)
        client = HubClient(app).also { it.start() }
        LogCapture.start { stream, text -> client?.notify("log", mapOf("stream" to stream, "text" to text)) }
    }

    /** Disconnect from the hub. */
    @JvmStatic
    @Synchronized
    fun stop() {
        client?.shutdown()
        client = null
    }

    /**
     * Register a named block the agent can run (`run_hook`), for example to
     * reset the app's state between checks. Hooks run on the main thread.
     */
    @JvmStatic
    fun registerHook(name: String, body: Runnable) {
        hooks.register(name, body)
        client?.notify("hooksChanged", mapOf("hooks" to hooks.names()))
    }

    internal fun uiChanged() {
        client?.notifyUiChanged()
    }
}

/** Hooks by name, safe to touch from any thread. */
internal class Hooks {
    private val byName = linkedMapOf<String, Runnable>()

    @Synchronized
    fun register(name: String, body: Runnable) {
        byName[name] = body
    }

    @Synchronized
    fun names(): List<String> = byName.keys.sorted()

    @Synchronized
    fun get(name: String): Runnable? = byName[name]
}
