package dev.porthole

import java.io.ByteArrayOutputStream
import java.io.EOFException
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.security.MessageDigest
import java.security.SecureRandom

/** A WebSocket frame: its opcode and payload. */
internal class Frame(val opcode: Int, val payload: ByteArray) {
    val text: String get() = String(payload, Charsets.UTF_8)
}

internal object Opcode {
    const val TEXT = 0x1
    const val CLOSE = 0x8
    const val PING = 0x9
    const val PONG = 0xA
}

/**
 * The client half of RFC 6455, enough for the hub: the opening handshake,
 * masked text frames out, and text, ping and close frames in (fragmented or
 * not). No dependencies, so it runs anywhere Porthole does.
 */
internal class WebSocket(private val input: InputStream, private val output: OutputStream) {
    private val random = SecureRandom()

    /** Upgrade `GET path`; throws if the server doesn't agree. */
    fun handshake(path: String) {
        val nonce = ByteArray(16).also { random.nextBytes(it) }
        val key = Base64.encode(nonce)
        val request = "GET $path HTTP/1.1\r\n" +
            "Host: porthole\r\n" +
            "Upgrade: websocket\r\n" +
            "Connection: Upgrade\r\n" +
            "Sec-WebSocket-Key: $key\r\n" +
            "Sec-WebSocket-Version: 13\r\n\r\n"
        output.write(request.toByteArray(Charsets.US_ASCII))
        output.flush()
        val status = readLine()
        if (!status.contains(" 101")) throw IOException("the hub refused the upgrade: $status")
        var accept: String? = null
        while (true) {
            val line = readLine()
            if (line.isEmpty()) break
            val colon = line.indexOf(':')
            if (colon > 0 && line.substring(0, colon).trim().equals("Sec-WebSocket-Accept", ignoreCase = true)) {
                accept = line.substring(colon + 1).trim()
            }
        }
        if (accept != acceptKey(key)) throw IOException("the hub's Sec-WebSocket-Accept didn't match")
    }

    @Synchronized
    fun send(opcode: Int, payload: ByteArray) {
        val mask = ByteArray(4).also { random.nextBytes(it) }
        output.write(encodeFrame(opcode, payload, mask))
        output.flush()
    }

    fun sendText(text: String) = send(Opcode.TEXT, text.toByteArray(Charsets.UTF_8))

    /** The next whole message, or a control frame. */
    fun read(): Frame = readFrame(input)

    private fun readLine(): String {
        val out = ByteArrayOutputStream()
        while (true) {
            val b = input.read()
            if (b < 0) throw EOFException("the hub closed the connection")
            if (b == '\n'.code) break
            if (b != '\r'.code) out.write(b)
        }
        return out.toString("US-ASCII")
    }

    companion object {
        private const val GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

        fun acceptKey(key: String): String {
            val sha1 = MessageDigest.getInstance("SHA-1").digest((key + GUID).toByteArray(Charsets.US_ASCII))
            return Base64.encode(sha1)
        }

        /** A client frame: FIN set, masked with `mask`. */
        fun encodeFrame(opcode: Int, payload: ByteArray, mask: ByteArray): ByteArray {
            val out = ByteArrayOutputStream(payload.size + 14)
            out.write(0x80 or opcode)
            val n = payload.size
            when {
                n < 126 -> out.write(0x80 or n)
                n < 65536 -> {
                    out.write(0x80 or 126)
                    out.write(n ushr 8 and 0xff)
                    out.write(n and 0xff)
                }
                else -> {
                    out.write(0x80 or 127)
                    for (shift in 56 downTo 0 step 8) out.write((n.toLong() ushr shift and 0xff).toInt())
                }
            }
            out.write(mask)
            for (i in 0 until n) out.write(payload[i].toInt() xor mask[i % 4].toInt())
            return out.toByteArray()
        }

        /**
         * Read one message: data frames are joined across continuation
         * frames; control frames come back as they are.
         */
        fun readFrame(input: InputStream): Frame {
            var opcode = -1
            val data = ByteArrayOutputStream()
            while (true) {
                val b0 = readByte(input)
                val b1 = readByte(input)
                val fin = b0 and 0x80 != 0
                val op = b0 and 0x0f
                var len = (b1 and 0x7f).toLong()
                if (len == 126L) len = (readByte(input).toLong() shl 8) or readByte(input).toLong()
                else if (len == 127L) {
                    len = 0
                    repeat(8) { len = (len shl 8) or readByte(input).toLong() }
                }
                val mask = if (b1 and 0x80 != 0) ByteArray(4) { readByte(input).toByte() } else null
                if (len > 64L * 1024 * 1024) throw IOException("frame too large: $len bytes")
                val payload = ByteArray(len.toInt())
                var read = 0
                while (read < payload.size) {
                    val r = input.read(payload, read, payload.size - read)
                    if (r < 0) throw EOFException("the hub closed the connection")
                    read += r
                }
                if (mask != null) for (i in payload.indices) payload[i] = (payload[i].toInt() xor mask[i % 4].toInt()).toByte()
                if (op >= 0x8) return Frame(op, payload)
                if (op != 0) opcode = op
                data.write(payload)
                if (fin) return Frame(if (opcode < 0) Opcode.TEXT else opcode, data.toByteArray())
            }
        }

        private fun readByte(input: InputStream): Int {
            val b = input.read()
            if (b < 0) throw EOFException("the hub closed the connection")
            return b
        }
    }
}

/** Base64 without android.util or java.util.Base64 (API 26), for API 24. */
internal object Base64 {
    private const val ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

    fun encode(data: ByteArray): String {
        val out = StringBuilder((data.size + 2) / 3 * 4)
        var i = 0
        while (i < data.size) {
            val b0 = data[i].toInt() and 0xff
            val b1 = if (i + 1 < data.size) data[i + 1].toInt() and 0xff else 0
            val b2 = if (i + 2 < data.size) data[i + 2].toInt() and 0xff else 0
            out.append(ALPHABET[b0 ushr 2])
            out.append(ALPHABET[(b0 and 0x03) shl 4 or (b1 ushr 4)])
            out.append(if (i + 1 < data.size) ALPHABET[(b1 and 0x0f) shl 2 or (b2 ushr 6)] else '=')
            out.append(if (i + 2 < data.size) ALPHABET[b2 and 0x3f] else '=')
            i += 3
        }
        return out.toString()
    }
}
