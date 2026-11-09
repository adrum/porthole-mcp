package dev.porthole

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream

class WebSocketTest {
    @Test
    fun acceptKeyMatchesTheRfcExample() {
        // RFC 6455, section 1.3.
        assertEquals("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", WebSocket.acceptKey("dGhlIHNhbXBsZSBub25jZQ=="))
    }

    @Test
    fun base64MatchesKnownValues() {
        assertEquals("", Base64.encode(ByteArray(0)))
        assertEquals("Zg==", Base64.encode("f".toByteArray()))
        assertEquals("Zm8=", Base64.encode("fo".toByteArray()))
        assertEquals("Zm9v", Base64.encode("foo".toByteArray()))
        assertEquals("Zm9vYmFy", Base64.encode("foobar".toByteArray()))
    }

    @Test
    fun maskedFramesDecodeToTheirPayload() {
        val mask = byteArrayOf(1, 2, 3, 4)
        for (size in listOf(0, 5, 125, 126, 300, 70000)) {
            val payload = ByteArray(size) { (it % 251).toByte() }
            val frame = WebSocket.readFrame(ByteArrayInputStream(WebSocket.encodeFrame(Opcode.TEXT, payload, mask)))
            assertEquals(Opcode.TEXT, frame.opcode)
            assertArrayEquals("size $size", payload, frame.payload)
        }
    }

    @Test
    fun continuationFramesJoinIntoOneMessage() {
        // A server's unmasked text frame split in two: "Hel" + "lo".
        val out = ByteArrayOutputStream()
        out.write(byteArrayOf(0x01, 3) + "Hel".toByteArray())
        out.write(byteArrayOf(0x80.toByte(), 2) + "lo".toByteArray())
        val frame = WebSocket.readFrame(ByteArrayInputStream(out.toByteArray()))
        assertEquals(Opcode.TEXT, frame.opcode)
        assertEquals("Hello", frame.text)
    }

    @Test
    fun controlFramesComeBackOnTheirOwn() {
        val ping = byteArrayOf(0x89.toByte(), 2, 'h'.code.toByte(), 'i'.code.toByte())
        val frame = WebSocket.readFrame(ByteArrayInputStream(ping))
        assertEquals(Opcode.PING, frame.opcode)
        assertEquals("hi", frame.text)
    }
}
