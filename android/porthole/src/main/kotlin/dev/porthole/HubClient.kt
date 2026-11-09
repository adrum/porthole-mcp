package dev.porthole

import android.content.Context
import android.net.LocalSocket
import android.net.LocalSocketAddress
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.Process
import android.os.SystemClock
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

/** A request the harness can't carry out, with the protocol's error kind. */
internal class HarnessError(val kind: String, message: String) : Exception(message) {
    val code: Int
        get() = when (kind) {
            "not_found" -> -32001
            "invalid_request" -> -32602
            "unsupported" -> -32003
            else -> -32004
        }
}

/**
 * Keeps the app connected to the hub: dial the abstract socket the hub's
 * `adb reverse` provides, say hello, answer requests on the main thread,
 * and send notifications. Reconnects with backoff from 0.25 s to 5 s for as
 * long as the app runs.
 */
internal class HubClient(private val context: Context) : Thread("porthole-hub") {
    @Volatile private var stopped = false
    @Volatile private var socket: WebSocket? = null
    private var local: LocalSocket? = null
    private val main = Handler(Looper.getMainLooper())
    private var lastUiChanged = 0L
    private var uiChangedPending = false

    init {
        isDaemon = true
    }

    fun shutdown() {
        stopped = true
        try {
            local?.close()
        } catch (_: Exception) {
        }
    }

    override fun run() {
        var delay = 250L
        var reportedWaiting = false
        while (!stopped) {
            try {
                val s = LocalSocket()
                s.connect(LocalSocketAddress(Porthole.SOCKET_NAME, LocalSocketAddress.Namespace.ABSTRACT))
                local = s
                val ws = WebSocket(s.inputStream, s.outputStream)
                ws.handshake("/v2/app")
                val target = hello(ws)
                socket = ws
                Log.i(Porthole.TAG, "connected to the porthole-mcp hub as $target")
                reportedWaiting = false
                delay = 250L
                val why = serve(ws)
                socket = null
                if (!stopped) Log.i(Porthole.TAG, "lost the hub ($why); reconnecting")
            } catch (e: Exception) {
                socket = null
                if (!reportedWaiting) {
                    Log.i(Porthole.TAG, "waiting for the porthole-mcp hub (${e.message}). On the Mac, start it with porthole-mcp; it maps this device with adb reverse.")
                    reportedWaiting = true
                }
            } finally {
                try {
                    local?.close()
                } catch (_: Exception) {
                }
                local = null
            }
            if (stopped) break
            sleep(delay)
            delay = (delay * 2).coerceAtMost(5000L)
        }
    }

    private fun hello(ws: WebSocket): String {
        val pm = context.packageManager
        val label = context.applicationInfo.loadLabel(pm).toString()
        val params = JSONObject()
            .put("protocol", 2)
            .put("appId", context.packageName)
            .put("name", label)
            .put("pid", Process.myPid())
            .put("platform", "android")
            .put("simulator", isEmulator())
            .put("toolkits", JSONArray(toolkits()))
            .put("capabilities", JSONArray(listOf("tree", "screenshot", "press", "pressAt", "fill", "key", "focus", "scroll", "hooks")))
            .put("hooks", JSONArray(Porthole.hooks.names()))
        ws.sendText(JSONObject().put("jsonrpc", "2.0").put("id", 1).put("method", "hello").put("params", params).toString())
        while (true) {
            val frame = ws.read()
            if (frame.opcode == Opcode.PING) {
                ws.send(Opcode.PONG, frame.payload)
                continue
            }
            if (frame.opcode == Opcode.CLOSE) throw java.io.IOException("the hub closed the connection")
            val reply = JSONObject(frame.text)
            reply.optJSONObject("error")?.let { throw java.io.IOException(it.optString("message")) }
            return reply.getJSONObject("result").optString("target")
        }
    }

    /** Answer requests until the connection drops; returns why it did. */
    private fun serve(ws: WebSocket): String {
        while (!stopped) {
            val frame = try {
                ws.read()
            } catch (e: Exception) {
                return e.message ?: "read failed"
            }
            when (frame.opcode) {
                Opcode.PING -> ws.send(Opcode.PONG, frame.payload)
                Opcode.CLOSE -> return "closed by the hub"
                Opcode.TEXT -> {
                    val msg = try {
                        JSONObject(frame.text)
                    } catch (_: Exception) {
                        continue
                    }
                    if (msg.has("id") && msg.has("method")) ws.sendText(respond(msg).toString())
                }
            }
        }
        return "stopped"
    }

    private fun respond(msg: JSONObject): JSONObject {
        val id = msg.get("id")
        val reply = JSONObject().put("jsonrpc", "2.0").put("id", id)
        return try {
            reply.put("result", onMain { Requests.handle(msg.getString("method"), msg.optJSONObject("params") ?: JSONObject()) })
        } catch (e: HarnessError) {
            reply.put("error", JSONObject().put("code", e.code).put("message", e.message).put("data", JSONObject().put("kind", e.kind)))
        } catch (e: Exception) {
            reply.put("error", JSONObject().put("code", -32004).put("message", e.message ?: e.toString()).put("data", JSONObject().put("kind", "failed")))
        }
    }

    /** Run on the main thread and wait for the result (UI work belongs there). */
    private fun <T> onMain(work: () -> T): T {
        if (Looper.myLooper() == Looper.getMainLooper()) return work()
        val result = AtomicReference<Result<T>>()
        val done = CountDownLatch(1)
        main.post {
            result.set(runCatching(work))
            done.countDown()
        }
        if (!done.await(20, TimeUnit.SECONDS)) throw HarnessError("failed", "the app's main thread didn't respond within 20 s")
        return result.get().getOrThrow()
    }

    /** A notification, if connected; dropped otherwise, as the hub isn't there. */
    fun notify(method: String, params: Map<String, Any>) {
        val ws = socket ?: return
        val p = JSONObject()
        for ((k, v) in params) p.put(k, if (v is List<*>) JSONArray(v) else v)
        try {
            ws.sendText(JSONObject().put("jsonrpc", "2.0").put("method", method).put("params", p).toString())
        } catch (_: Exception) {
        }
    }

    /** At most ten a second, the last one always sent. */
    fun notifyUiChanged() {
        if (socket == null) return
        val now = SystemClock.uptimeMillis()
        if (now - lastUiChanged >= 100) {
            lastUiChanged = now
            notify("uiChanged", emptyMap())
        } else if (!uiChangedPending) {
            uiChangedPending = true
            main.postDelayed({
                uiChangedPending = false
                lastUiChanged = SystemClock.uptimeMillis()
                notify("uiChanged", emptyMap())
            }, 100 - (now - lastUiChanged))
        }
    }

    private fun toolkits(): List<String> {
        val kits = mutableListOf("views")
        if (classExists("androidx.compose.ui.platform.AndroidComposeView")) kits += "compose"
        if (classExists("com.facebook.react.ReactRootView")) kits += "react-native"
        return kits
    }

    private fun classExists(name: String) = try {
        Class.forName(name, false, javaClass.classLoader)
        true
    } catch (_: Throwable) {
        false
    }

    private fun isEmulator() = Build.FINGERPRINT.startsWith("generic") ||
        Build.FINGERPRINT.contains("emulator") ||
        Build.HARDWARE.contains("goldfish") ||
        Build.HARDWARE.contains("ranchu") ||
        Build.PRODUCT.contains("sdk")
}
