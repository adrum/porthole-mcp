package dev.porthole.demo

import android.app.Application
import dev.porthole.Porthole

/** Debug builds: hooks the agent can run. Porthole itself starts on its own. */
object DebugSetup {
    fun install(app: Application) {
        Porthole.registerHook("reset") { DemoState.reset() }
    }
}
