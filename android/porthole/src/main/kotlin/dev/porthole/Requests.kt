package dev.porthole

import android.graphics.Bitmap
import android.graphics.Canvas
import android.os.SystemClock
import android.view.KeyCharacterMap
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.View
import android.view.accessibility.AccessibilityNodeInfo
import android.view.inputmethod.EditorInfo
import android.widget.AbsListView
import android.widget.CompoundButton
import android.widget.EditText
import android.widget.TextView
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream

/** The hub's requests, run on the main thread. */
internal object Requests {
    fun handle(method: String, params: JSONObject): JSONObject = when (method) {
        "windows" -> windows()
        "tree" -> tree(params)
        "screenshot" -> screenshot(params)
        "act" -> JSONObject().put("detail", act(params))
        "runHook" -> runHook(params)
        else -> throw HarnessError("invalid_request", "unknown method \"$method\"")
    }

    private fun window(params: JSONObject): AppWindow =
        Windows.resolve(params.optString("window").takeIf { it.isNotEmpty() })

    private fun windows(): JSONObject {
        val list = JSONArray()
        for (w in Windows.all()) {
            val density = w.root.resources.displayMetrics.density
            val loc = IntArray(2).also { w.root.getLocationOnScreen(it) }
            list.put(
                JSONObject().put("id", w.id).put("title", w.title).put("key", w.key)
                    .put("foreground", Windows.inForeground()).put(
                    "frame",
                    JSONObject().put("x", loc[0] / density).put("y", loc[1] / density)
                        .put("w", w.root.width / density).put("h", w.root.height / density),
                ),
            )
        }
        return JSONObject().put("windows", list)
    }

    private fun tree(params: JSONObject): JSONObject {
        val w = window(params)
        return JSONObject().put("window", w.id).put("root", Tree.build(w, params.optBoolean("a11y")).toJson())
    }

    private fun screenshot(params: JSONObject): JSONObject {
        val w = window(params)
        val root = w.root
        val density = root.resources.displayMetrics.density
        val scale = params.optDouble("scale", 1.0).coerceIn(0.25, 3.0).toFloat()
        // The window drawn into a bitmap, at `scale` pixels per dp: no
        // screen capture, so no permission is involved.
        val factor = scale / density
        val width = (root.width * factor).toInt().coerceAtLeast(1)
        val height = (root.height * factor).toInt().coerceAtLeast(1)
        var bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        canvas.scale(factor, factor)
        root.draw(canvas)
        params.optString("node").takeIf { it.isNotEmpty() }?.let { id ->
            val node = Tree.build(w).find(id) ?: throw HarnessError("not_found", "no element with id \"$id\"; inspect again")
            val x = (node.x * scale).toInt().coerceIn(0, width - 1)
            val y = (node.y * scale).toInt().coerceIn(0, height - 1)
            val cw = (node.w * scale).toInt().coerceIn(1, width - x)
            val ch = (node.h * scale).toInt().coerceIn(1, height - y)
            bitmap = Bitmap.createBitmap(bitmap, x, y, cw, ch)
        }
        val png = ByteArrayOutputStream()
        bitmap.compress(Bitmap.CompressFormat.PNG, 100, png)
        return JSONObject().put("png", Base64.encode(png.toByteArray()))
    }

    private fun runHook(params: JSONObject): JSONObject {
        val name = params.optString("name")
        val hook = Porthole.hooks.get(name)
            ?: throw HarnessError("not_found", "no hook \"$name\"; hooks: " + Porthole.hooks.names().joinToString().ifEmpty { "none" })
        hook.run()
        return JSONObject()
    }

    private fun act(params: JSONObject): String {
        val w = window(params)
        val action = params.optString("action")
        fun node(): Node {
            val id = params.optString("node")
            if (id.isEmpty()) throw HarnessError("invalid_request", "$action needs a node")
            return Tree.build(w).find(id) ?: throw HarnessError("not_found", "no element with id \"$id\"; inspect again")
        }
        return when (action) {
            "press" -> press(node(), w)
            "pressAt" -> {
                tap(w.root, params.optDouble("x").toFloat(), params.optDouble("y").toFloat())
                "tapped at (${params.optDouble("x")}, ${params.optDouble("y")})"
            }
            "fill" -> fill(node(), params.optString("text"))
            "key" -> key(w, params.optString("key"))
            "focus" -> focus(node())
            "scroll" -> scroll(w, params.optString("node").takeIf { it.isNotEmpty() }?.let { node() }, params.optDouble("dx", 0.0).toFloat(), params.optDouble("dy", 0.0).toFloat())
            else -> throw HarnessError("invalid_request", "unknown action \"$action\"")
        }
    }

    private fun press(node: Node, w: AppWindow): String {
        if (node.states["enabled"] == false) throw HarnessError("failed", "${node.role} \"${node.name ?: node.id}\" is disabled")
        when (val t = node.target) {
            is Target.OfCompose -> if (Compose.press(t)) return "clicked ${node.role}"
            is Target.OfView -> {
                val v = t.view
                // A control's own click first: that's what a tap does.
                // performClick's result only says whether an OnClickListener
                // ran; a CheckBox toggles either way, so never click twice.
                if (v.isClickable || v is CompoundButton) {
                    v.performClick()
                    return "clicked ${v.javaClass.simpleName}"
                }
                if (v.performAccessibilityAction(AccessibilityNodeInfo.ACTION_CLICK, null)) return "pressed ${node.role} via accessibility"
                // A list row: its list handles the click.
                (v.parent as? AbsListView)?.let { list ->
                    val position = list.getPositionForView(v)
                    if (position != AbsListView.INVALID_POSITION && list.performItemClick(v, position, list.getItemIdAtPosition(position))) {
                        return "selected row $position"
                    }
                }
            }
            null -> {}
        }
        tap(w.root, node.x + node.w / 2, node.y + node.h / 2)
        return "tapped the center of ${node.role}"
    }

    /** A real touch at window coordinates (dp), through the window's own dispatch. */
    private fun tap(root: View, xDp: Float, yDp: Float) {
        val density = root.resources.displayMetrics.density
        val origin = IntArray(2).also { root.getLocationInWindow(it) }
        val x = xDp * density + origin[0]
        val y = yDp * density + origin[1]
        val down = SystemClock.uptimeMillis()
        val pressed = MotionEvent.obtain(down, down, MotionEvent.ACTION_DOWN, x, y, 0)
        val released = MotionEvent.obtain(down, down + 50, MotionEvent.ACTION_UP, x, y, 0)
        root.dispatchTouchEvent(pressed)
        root.dispatchTouchEvent(released)
        pressed.recycle()
        released.recycle()
    }

    private fun fill(node: Node, text: String): String {
        when (val t = node.target) {
            is Target.OfCompose -> if (Compose.fill(t, text)) return "filled ${node.role}"
            is Target.OfView -> {
                val v = t.view
                if (v is EditText) {
                    v.requestFocus()
                    v.setText(text)
                    v.setSelection(v.text?.length ?: 0)
                    return "filled ${v.javaClass.simpleName}"
                }
            }
            null -> {}
        }
        throw HarnessError("unsupported", "${node.role} \"${node.name ?: node.id}\" isn't a text field")
    }

    private fun focus(node: Node): String {
        when (val t = node.target) {
            is Target.OfCompose -> if (Compose.focus(t)) return "focused ${node.role}"
            is Target.OfView -> if (t.view.requestFocus()) return "focused ${t.view.javaClass.simpleName}"
            null -> {}
        }
        throw HarnessError("unsupported", "${node.role} \"${node.name ?: node.id}\" can't take focus")
    }

    private val keyCodes = mapOf(
        "Enter" to KeyEvent.KEYCODE_ENTER,
        "Tab" to KeyEvent.KEYCODE_TAB,
        "Escape" to KeyEvent.KEYCODE_ESCAPE,
        "Backspace" to KeyEvent.KEYCODE_DEL,
        "Delete" to KeyEvent.KEYCODE_FORWARD_DEL,
        "Space" to KeyEvent.KEYCODE_SPACE,
        "ArrowUp" to KeyEvent.KEYCODE_DPAD_UP,
        "ArrowDown" to KeyEvent.KEYCODE_DPAD_DOWN,
        "ArrowLeft" to KeyEvent.KEYCODE_DPAD_LEFT,
        "ArrowRight" to KeyEvent.KEYCODE_DPAD_RIGHT,
        "Home" to KeyEvent.KEYCODE_MOVE_HOME,
        "End" to KeyEvent.KEYCODE_MOVE_END,
        "PageUp" to KeyEvent.KEYCODE_PAGE_UP,
        "PageDown" to KeyEvent.KEYCODE_PAGE_DOWN,
    )

    private fun key(w: AppWindow, key: String): String {
        val focused = w.root.findFocus() ?: w.root
        // Enter in a text field is its editor action (Done, Go, Search...),
        // which is what the keyboard's action button sends.
        if (key == "Enter" && focused is TextView && focused.onCheckIsTextEditor()) {
            val imeAction = focused.imeOptions and EditorInfo.IME_MASK_ACTION
            focused.onEditorAction(if (imeAction == EditorInfo.IME_ACTION_UNSPECIFIED) EditorInfo.IME_ACTION_DONE else imeAction)
            return "sent the editor action to ${focused.javaClass.simpleName}"
        }
        val events: Array<KeyEvent> = keyCodes[key]?.let { code ->
            arrayOf(KeyEvent(KeyEvent.ACTION_DOWN, code), KeyEvent(KeyEvent.ACTION_UP, code))
        } ?: if (key.length == 1) {
            KeyCharacterMap.load(KeyCharacterMap.VIRTUAL_KEYBOARD).getEvents(key.toCharArray())
                ?: throw HarnessError("invalid_request", "can't type \"$key\"")
        } else {
            throw HarnessError("invalid_request", "unknown key \"$key\"; use Enter, Tab, Escape, Backspace, Delete, Space, arrows, Home, End, PageUp, PageDown, or one character")
        }
        for (e in events) focused.dispatchKeyEvent(e)
        return "sent to ${focused.javaClass.simpleName}"
    }

    private fun scroll(w: AppWindow, node: Node?, dx: Float, dy: Float): String {
        val density = w.root.resources.displayMetrics.density
        val target = node ?: largestScrollable(Tree.build(w))
            ?: throw HarnessError("not_found", "nothing on screen scrolls")
        when (val t = target.target) {
            is Target.OfCompose -> {
                if (!Compose.scroll(t, dx * density, dy * density)) throw HarnessError("unsupported", "${target.role} \"${target.id}\" doesn't scroll")
                return "scrolled ${target.role} by ($dx, $dy)"
            }
            is Target.OfView -> {
                val v = t.view
                val canX = dx != 0f && v.canScrollHorizontally(if (dx > 0) 1 else -1)
                val canY = dy != 0f && v.canScrollVertically(if (dy > 0) 1 else -1)
                if (!canX && !canY) return "nothing to scroll: ${v.javaClass.simpleName} is already at its end"
                v.scrollBy((dx * density).toInt(), (dy * density).toInt())
                return "scrolled ${v.javaClass.simpleName} by ($dx, $dy)"
            }
            null -> throw HarnessError("unsupported", "${target.role} \"${target.id}\" doesn't scroll")
        }
    }

    private fun largestScrollable(root: Node): Node? {
        var best: Node? = null
        root.walk { n ->
            val scrolls = when (val t = n.target) {
                is Target.OfCompose -> Compose.canScroll(t)
                is Target.OfView -> n.role == "scrollview" || n.role == "list" ||
                    t.view.canScrollVertically(1) || t.view.canScrollVertically(-1)
                null -> false
            }
            if (scrolls && n.role != "window" && (best == null || n.w * n.h > best!!.w * best!!.h)) best = n
        }
        return best
    }
}
