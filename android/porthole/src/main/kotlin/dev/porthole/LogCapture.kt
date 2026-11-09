package dev.porthole

import android.os.Process
import android.os.SystemClock
import java.io.BufferedReader
import java.io.InputStreamReader

/**
 * The app's own log lines, for the `logs` tool: logcat for this process
 * only, which an app may read without any permission. Errors and warnings
 * go out as stderr, everything else as stdout. At most 200 lines a second.
 */
internal object LogCapture {
    @Volatile private var started = false

    fun start(send: (stream: String, text: String) -> Unit) {
        if (started) return
        started = true
        Thread({
            try {
                // -T 1: from now on, not the backlog. brief: "D/Tag( pid): message".
                val process = ProcessBuilder("logcat", "-v", "brief", "-T", "1", "--pid=${Process.myPid()}")
                    .redirectErrorStream(true)
                    .start()
                val reader = BufferedReader(InputStreamReader(process.inputStream))
                var windowStart = SystemClock.uptimeMillis()
                var sent = 0
                while (true) {
                    val line = reader.readLine() ?: break
                    if (line.startsWith("-----") || line.contains("/Porthole")) continue
                    val now = SystemClock.uptimeMillis()
                    if (now - windowStart >= 1000) {
                        windowStart = now
                        sent = 0
                    }
                    if (++sent > 200) continue
                    val stream = if (line.startsWith("E/") || line.startsWith("W/") || line.startsWith("F/")) "stderr" else "stdout"
                    send(stream, line)
                }
            } catch (_: Exception) {
                // No logcat (a restricted build): the logs tool stays empty.
            }
        }, "porthole-logs").apply { isDaemon = true }.start()
    }
}
