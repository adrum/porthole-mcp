package dev.porthole.demo

import android.app.Application

/** Release builds have no Porthole, so nothing to set up. */
object DebugSetup {
    @Suppress("UNUSED_PARAMETER")
    fun install(app: Application) {}
}
