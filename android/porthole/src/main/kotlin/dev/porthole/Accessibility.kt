package dev.porthole

import android.graphics.Bitmap
import android.graphics.Canvas
import android.os.Build
import android.util.TypedValue
import android.view.View
import android.widget.EditText
import android.widget.TextView
import org.json.JSONObject
import kotlin.math.ceil
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow

/** Roles assistive technology reads as one element with a label. */
internal val elementRoles = setOf(
    "text", "button", "link", "checkbox", "switch", "tab", "menu", "textfield", "securefield",
    "textarea", "slider", "image", "row",
)

/** Roles whose text is worth a contrast measurement. */
private val textBearingRoles = setOf(
    "text", "button", "link", "textfield", "securefield", "textarea", "tab", "menu", "checkbox", "switch", "row",
)

internal object Accessibility {
    /** What TalkBack gets from a View, in the protocol's `a11y` fields. */
    fun ofView(view: View, role: String, density: Float): JSONObject {
        val a = JSONObject().put("class", view.javaClass.name)
        val important = view.isImportantForAccessibility
        val text = (view as? TextView)?.takeIf { it !is EditText }?.text?.toString()?.takeIf { it.isNotEmpty() }
        if (role in elementRoles) {
            a.put("element", important)
            val label = view.contentDescription?.toString()?.takeIf { it.isNotEmpty() }
                ?: (view as? EditText)?.hint?.toString()?.takeIf { it.isNotEmpty() }
                ?: text
            if (label != null) a.put("label", label)
        }
        if (text != null) {
            a.put("text", text)
            if (!important) a.put("hiddenFromAccessibility", true)
        }
        if (view.isClickable && !important) a.put("unreachable", true)
        if (view.isFocusable) a.put("focusable", true)
        (view as? TextView)?.let { a.put("font", font(it, density)) }
        return a
    }

    /** Size in sp when it follows the user's font size, otherwise in dp. */
    private fun font(view: TextView, density: Float): JSONObject {
        val scale = view.resources.configuration.fontScale
        val o = JSONObject()
        if (Build.VERSION.SDK_INT >= 30) {
            val dynamic = view.textSizeUnit == TypedValue.COMPLEX_UNIT_SP
            o.put("size", (view.textSize / density / if (dynamic) scale else 1f).toDouble())
            o.put("dynamicType", dynamic)
        } else {
            o.put("size", (view.textSize / density / scale).toDouble())
        }
        return o
    }

    /** The window drawn at up to 2 pixels per dp, for contrast. */
    fun render(root: View): Pixels? {
        if (root.width <= 0 || root.height <= 0) return null
        val density = root.resources.displayMetrics.density
        val scale = min(density, 2f)
        val factor = scale / density
        val w = max(1, (root.width * factor).toInt())
        val h = max(1, (root.height * factor).toInt())
        val bitmap = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        canvas.scale(factor, factor)
        root.draw(canvas)
        val argb = IntArray(w * h)
        bitmap.getPixels(argb, 0, w, 0, 0, w, h)
        bitmap.recycle()
        return Pixels(w, h, scale, argb)
    }

    /** Fill `a11y.contrast` for text-bearing nodes. */
    fun measureContrast(root: Node, pixels: Pixels?) {
        pixels ?: return
        root.walk { n ->
            if (n.role !in textBearingRoles || n.name == null && n.value == null) return@walk
            val c = pixels.contrast(n.x, n.y, n.w, n.h) ?: return@walk
            (n.a11y ?: JSONObject().also { n.a11y = it }).put("contrast", c)
        }
    }
}

/**
 * A rendered window as ARGB pixels. Contrast is measured as the Apple
 * harness does it: the background is the most common color; "ink" is every
 * pixel that differs from it noticeably, and the foreground is the ink
 * pixel at the 90th percentile of contrast, so anti-aliased glyph edges and
 * stray outliers don't decide the result.
 */
internal class Pixels(val width: Int, val height: Int, private val scale: Float, private val argb: IntArray) {
    /** Foreground, background and WCAG ratio in a rect of window dp. */
    fun contrast(x: Float, y: Float, w: Float, h: Float): JSONObject? {
        val x0 = max(0, floor(x * scale).toInt())
        val y0 = max(0, floor(y * scale).toInt())
        val x1 = min(width, ceil((x + w) * scale).toInt())
        val y1 = min(height, ceil((y + h) * scale).toInt())
        if (x1 - x0 < 2 || y1 - y0 < 2) return null
        val counts = HashMap<Int, Int>()
        val pixels = ArrayList<Int>((x1 - x0) * (y1 - y0))
        for (row in y0 until y1) {
            for (col in x0 until x1) {
                val p = argb[row * width + col]
                if ((p ushr 24) <= 8) continue
                val rgb = p and 0xFFFFFF
                pixels += rgb
                counts.merge(bucket(rgb), 1, Int::plus)
            }
        }
        if (pixels.isEmpty()) return null
        val bgBucket = counts.maxByOrNull { it.value }!!.key
        var r = 0L; var g = 0L; var b = 0L; var n = 0
        for (p in pixels) if (bucket(p) == bgBucket) {
            r += p shr 16 and 0xFF; g += p shr 8 and 0xFF; b += p and 0xFF; n++
        }
        val bg = ((r / n).toInt() shl 16) or ((g / n).toInt() shl 8) or (b / n).toInt()
        val lbg = luminance(bg)
        val ink = pixels.mapNotNull { p -> ratio(luminance(p), lbg).takeIf { it >= 1.25 }?.let { it to p } }
        if (ink.size < max(3, pixels.size / 200)) return JSONObject().put("bg", hex(bg))
        val sorted = ink.sortedBy { it.first }
        val fg = sorted[min(sorted.size - 1, (sorted.size * 0.9).toInt())]
        return JSONObject().put("fg", hex(fg.second)).put("bg", hex(bg))
            .put("ratio", Math.round(fg.first * 100) / 100.0)
    }

    companion object {
        private fun bucket(rgb: Int): Int =
            (rgb shr 20 and 0xF) shl 8 or (rgb shr 12 and 0xF shl 4) or (rgb shr 4 and 0xF)

        fun luminance(rgb: Int): Double {
            fun lin(v: Int): Double {
                val c = v / 255.0
                return if (c <= 0.04045) c / 12.92 else ((c + 0.055) / 1.055).pow(2.4)
            }
            return 0.2126 * lin(rgb shr 16 and 0xFF) + 0.7152 * lin(rgb shr 8 and 0xFF) + 0.0722 * lin(rgb and 0xFF)
        }

        /** WCAG 2 contrast ratio of two relative luminances. */
        fun ratio(la: Double, lb: Double): Double = (max(la, lb) + 0.05) / (min(la, lb) + 0.05)

        fun hex(rgb: Int): String = String.format("#%06X", rgb and 0xFFFFFF)
    }
}
