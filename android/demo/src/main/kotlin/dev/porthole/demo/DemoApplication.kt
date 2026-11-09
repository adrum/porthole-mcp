package dev.porthole.demo

import android.app.Application

class DemoApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        // Porthole hooks, in debug builds only (src/debug); a no-op in release.
        DebugSetup.install(this)
    }
}

/** What the agent's reset hook clears. */
object DemoState {
    var saved: String? = null
    var count = 0
    val listeners = mutableListOf<() -> Unit>()

    fun reset() {
        saved = null
        count = 0
        listeners.forEach { it() }
    }
}
