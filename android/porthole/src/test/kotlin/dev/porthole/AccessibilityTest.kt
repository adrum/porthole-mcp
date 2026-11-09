package dev.porthole

import org.junit.Assert.assertEquals
import org.junit.Test

class AccessibilityTest {
    @Test
    fun blackOnWhiteIsTwentyOneToOne() {
        val ratio = Pixels.ratio(Pixels.luminance(0x000000), Pixels.luminance(0xFFFFFF))
        assertEquals(21.0, ratio, 0.001)
    }

    @Test
    fun ratioIsSymmetricAndOneForTheSameColor() {
        val gray = Pixels.luminance(0x767676)
        val white = Pixels.luminance(0xFFFFFF)
        assertEquals(Pixels.ratio(gray, white), Pixels.ratio(white, gray), 1e-9)
        assertEquals(1.0, Pixels.ratio(gray, gray), 1e-9)
        // #767676 on white is the classic just-passing AA gray.
        assertEquals(4.54, Pixels.ratio(gray, white), 0.01)
    }
}
