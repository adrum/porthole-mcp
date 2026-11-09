package dev.porthole

import android.graphics.Rect
import android.text.InputType
import android.view.View
import android.view.ViewGroup
import android.widget.AbsListView
import android.widget.AbsSeekBar
import android.widget.Button
import android.widget.CheckBox
import android.widget.CompoundButton
import android.widget.EditText
import android.widget.HorizontalScrollView
import android.widget.ImageButton
import android.widget.ImageView
import android.widget.RadioButton
import android.widget.ScrollView
import android.widget.TextView
import org.json.JSONArray
import org.json.JSONObject

/** What a node acts on: a View, or a Compose semantics node. */
internal sealed class Target {
    class OfView(val view: View) : Target()
    class OfCompose(val node: Any, val owner: View) : Target()
}

/** One element of the tree, in window coordinates measured in dp. */
internal class Node(
    var id: String,
    val role: String,
    val name: String?,
    val value: Any?,
    val states: Map<String, Boolean>,
    val x: Float,
    val y: Float,
    val w: Float,
    val h: Float,
    val target: Target?,
) {
    val children = mutableListOf<Node>()

    /** Accessibility facts, only when the tree was asked for with a11y. */
    var a11y: JSONObject? = null

    /** A press at the center would land on something else on top. */
    var covered = false

    fun toJson(): JSONObject {
        val o = JSONObject().put("id", id).put("role", role)
        if (!name.isNullOrEmpty()) o.put("name", name)
        if (value != null) o.put("value", value)
        if (states.isNotEmpty()) o.put("states", JSONObject(states as Map<*, *>))
        o.put("frame", JSONObject().put("x", x.toDouble()).put("y", y.toDouble()).put("w", w.toDouble()).put("h", h.toDouble()))
        if (covered) o.put("covered", true)
        a11y?.let { o.put("a11y", it) }
        if (children.isNotEmpty()) o.put("children", JSONArray(children.map { it.toJson() }))
        return o
    }

    fun find(id: String): Node? {
        if (this.id == id) return this
        for (c in children) c.find(id)?.let { return it }
        return null
    }

    fun walk(visit: (Node) -> Unit) {
        visit(this)
        for (c in children) c.walk(visit)
    }
}

/** Builds a window's tree from its views, with Compose content inside them. */
internal object Tree {
    fun build(window: AppWindow, a11y: Boolean = false): Node {
        val root = window.root
        val density = root.resources.displayMetrics.density
        val origin = IntArray(2).also { root.getLocationInWindow(it) }
        val node = Node(window.id, "window", window.title, null, emptyMap(), 0f, 0f, root.width / density, root.height / density, Target.OfView(root))
        if (root is ViewGroup) for (i in 0 until root.childCount) addView(root.getChildAt(i), node, origin, density, false, a11y)
        uniqueIds(node)
        markCovered(node, root, origin, density)
        if (a11y) Accessibility.measureContrast(node, Accessibility.render(root))
        return node
    }

    private fun addView(view: View, parent: Node, origin: IntArray, density: Float, inList: Boolean, a11y: Boolean) {
        if (!isVisible(view)) return
        if (Compose.isComposeView(view)) {
            Compose.addTree(view, parent, origin, density, a11y)
            return
        }
        val loc = IntArray(2).also { view.getLocationInWindow(it) }
        val x = (loc[0] - origin[0]) / density
        val y = (loc[1] - origin[1]) / density
        val role = roleOf(view, inList)
        val name = nameOf(view)
        val id = idOf(view)
        // Plain containers fold away, so the tree shows what someone sees.
        val keep = role != "group" && role != "other" || id != null || !view.contentDescription.isNullOrEmpty() || view.isClickable
        val node = if (keep) {
            Node(id ?: synthesized(view), role, name, valueOf(view), statesOf(view), x, y, view.width / density, view.height / density, Target.OfView(view))
                .also {
                    if (a11y) it.a11y = Accessibility.ofView(view, role, density)
                    parent.children += it
                }
        } else parent
        if (view is ViewGroup && role != "textfield") {
            val list = role == "list"
            for (i in 0 until view.childCount) addView(view.getChildAt(i), node, origin, density, list, a11y)
        }
    }

    /**
     * Covered: a touch at the node's center would land on a view outside the
     * node's own view, its descendants and its ancestors (an action bar
     * drawn over content, an overlay).
     */
    private fun markCovered(tree: Node, root: View, origin: IntArray, density: Float) {
        tree.walk { n ->
            if (n === tree) return@walk
            val view = when (val t = n.target) {
                is Target.OfView -> t.view
                is Target.OfCompose -> t.owner
                null -> null
            } ?: return@walk
            val cx = (n.x + n.w / 2).coerceIn(0f, tree.w - 0.5f) * density + origin[0]
            val cy = (n.y + n.h / 2).coerceIn(0f, tree.h - 0.5f) * density + origin[1]
            val hit = hitTest(root, cx, cy) ?: return@walk
            if (hit === view || isDescendant(hit, view) || isDescendant(view, hit)) return@walk
            n.covered = true
        }
    }

    /** The view on top at a point in window pixels that would take a touch or draws there. */
    private fun hitTest(v: View, x: Float, y: Float): View? {
        if (v.visibility != View.VISIBLE || v.alpha < 0.01f) return null
        val loc = IntArray(2).also { v.getLocationInWindow(it) }
        if (x < loc[0] || y < loc[1] || x >= loc[0] + v.width || y >= loc[1] + v.height) return null
        if (v is ViewGroup) {
            // Topmost first: higher z, then later in drawing order.
            val order = (0 until v.childCount).sortedWith(
                compareByDescending<Int> { v.getChildAt(it).z }.thenByDescending { it },
            )
            for (i in order) hitTest(v.getChildAt(i), x, y)?.let { return it }
        }
        return if (v.isClickable || !v.willNotDraw()) v else null
    }

    private fun isDescendant(v: View, of: View): Boolean {
        var p = v.parent
        while (p is View) {
            if (p === of) return true
            p = p.parent
        }
        return false
    }

    private fun isVisible(view: View): Boolean {
        if (view.visibility != View.VISIBLE || view.alpha < 0.01f || view.width <= 0 || view.height <= 0) return false
        return view.getGlobalVisibleRect(Rect())
    }

    private fun roleOf(view: View, inList: Boolean): String = when {
        view is EditText -> when {
            isPassword(view.inputType) -> "securefield"
            view.inputType and InputType.TYPE_TEXT_FLAG_MULTI_LINE != 0 -> "textarea"
            else -> "textfield"
        }
        view is CheckBox || view is RadioButton -> "checkbox"
        view is CompoundButton -> "switch"
        view is Button || view is ImageButton -> "button"
        view is AbsSeekBar -> "slider"
        view is TextView -> if (view.isClickable) "button" else "text"
        view is ImageView -> if (view.isClickable) "button" else "image"
        view is ScrollView || view is HorizontalScrollView || view.javaClass.name.endsWith("NestedScrollView") -> "scrollview"
        view is AbsListView || view.javaClass.name.endsWith("RecyclerView") -> "list"
        inList -> "row"
        view.isClickable -> "button"
        view is ViewGroup -> "group"
        else -> "other"
    }

    private fun isPassword(type: Int): Boolean {
        val variation = type and InputType.TYPE_MASK_VARIATION
        return variation == InputType.TYPE_TEXT_VARIATION_PASSWORD ||
            variation == InputType.TYPE_TEXT_VARIATION_WEB_PASSWORD ||
            variation == InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD ||
            type and InputType.TYPE_MASK_CLASS == InputType.TYPE_CLASS_NUMBER && variation == InputType.TYPE_NUMBER_VARIATION_PASSWORD
    }

    private fun nameOf(view: View): String? {
        view.contentDescription?.toString()?.takeIf { it.isNotEmpty() }?.let { return it }
        if (view is EditText) return view.hint?.toString()
        if (view is TextView) return view.text?.toString()
        return null
    }

    private fun valueOf(view: View): Any? = when (view) {
        is EditText -> if (isPassword(view.inputType)) "" else view.text?.toString() ?: ""
        is CompoundButton -> view.isChecked
        is AbsSeekBar -> view.progress
        else -> null
    }

    private fun statesOf(view: View): Map<String, Boolean> {
        val s = mutableMapOf<String, Boolean>()
        if (!view.isEnabled) s["enabled"] = false
        if (view.isFocused) s["focused"] = true
        if (view.isSelected) s["selected"] = true
        if (view is CompoundButton && view.isChecked) s["checked"] = true
        return s
    }

    /**
     * The view's own name for itself: its resource id (`R.id.save` is
     * "save"), or a React Native testID.
     */
    private fun idOf(view: View): String? {
        reactTestId(view)?.let { return it }
        if (view.id != View.NO_ID && view.id > 0) {
            return try {
                view.resources.getResourceEntryName(view.id)
            } catch (_: Exception) {
                null
            }
        }
        return null
    }

    /** React Native puts testID in the view's tag under its react_test_id key. */
    private fun reactTestId(view: View): String? {
        val key = view.resources.getIdentifier("react_test_id", "id", view.context.packageName)
        if (key == 0) return null
        return view.getTag(key) as? String
    }

    fun synthesized(obj: Any): String = "_" + Integer.toString(System.identityHashCode(obj), 36)

    /** Repeated ids become `id`, `id@2`, `id@3`, ... in tree order. */
    fun uniqueIds(root: Node) {
        val seen = HashMap<String, Int>()
        root.walk { n ->
            val count = (seen[n.id] ?: 0) + 1
            seen[n.id] = count
            if (count > 1) n.id = "${n.id}@$count"
        }
    }
}
