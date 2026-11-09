package dev.porthole

import android.view.View
import androidx.compose.ui.platform.ViewRootForTest
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.SemanticsNode
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.state.ToggleableState
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.TextLayoutResult
import org.json.JSONObject

/**
 * Jetpack Compose, through its semantics tree: the same tree Compose's own
 * UI tests and accessibility read. Compose is compileOnly for Porthole, so
 * none of this runs (or loads) in an app without it.
 */
internal object Compose {
    private val available: Boolean by lazy {
        try {
            Class.forName("androidx.compose.ui.platform.ViewRootForTest", false, Compose::class.java.classLoader)
            true
        } catch (_: Throwable) {
            false
        }
    }

    fun isComposeView(view: View): Boolean = available && view is ViewRootForTest

    fun addTree(view: View, parent: Node, origin: IntArray, density: Float, a11y: Boolean) {
        val owner = (view as ViewRootForTest).semanticsOwner
        // Semantics bounds are in window coordinates, as view locations are;
        // measure from the window root's origin, as the view tree does.
        add(owner.unmergedRootSemanticsNode, parent, view, -origin[0].toFloat(), -origin[1].toFloat(), density, a11y, false)
    }

    /** Roles that read as one control, named by the text inside them. */
    private val controls = setOf("button", "checkbox", "switch", "tab", "menu", "textfield", "securefield", "slider")

    private fun hasControl(node: SemanticsNode): Boolean =
        node.children.any { roleOf(it) in controls || hasControl(it) }

    /** The text a node shows, its own or its descendants', as TalkBack reads it. */
    private fun texts(node: SemanticsNode, out: MutableList<String>) {
        ownName(node)?.let { out += it; return }
        for (child in node.children) texts(child, out)
    }

    private fun ownName(node: SemanticsNode): String? {
        val c = node.config
        return c.getOrNull(SemanticsProperties.ContentDescription)?.joinToString(" ")?.takeIf { it.isNotEmpty() }
            ?: c.getOrNull(SemanticsProperties.Text)?.joinToString(" ") { it.text }?.takeIf { it.isNotEmpty() }
    }

    private fun add(
        node: SemanticsNode, parent: Node, owner: View, dx: Float, dy: Float, density: Float,
        a11y: Boolean, hiddenAbove: Boolean,
    ) {
        val c = node.config
        // invisibleToUser hides a node from assistive tech, not from the
        // screen: keep it, and say so in a11y.
        val hidden = hiddenAbove || c.contains(SemanticsProperties.InvisibleToUser)
        val b = node.boundsInWindow
        if (b.width <= 0f || b.height <= 0f) return
        val role = roleOf(node)
        val tag = c.getOrNull(SemanticsProperties.TestTag)
        val control = role in controls
        // A button's label is the Text inside it: name the button with it,
        // and don't list that text again as a child of its own.
        val absorbed = if (control) node.children.filter { roleOf(it) !in controls && !hasControl(it) } else emptyList()
        val name = ownName(node)
            ?: absorbed.flatMap { mutableListOf<String>().also { out -> texts(it, out) } }.joinToString(" ").takeIf { it.isNotEmpty() }
        val keep = role != "group" || tag != null || name != null && node.children.isEmpty() ||
            c.contains(SemanticsActions.OnClick)
        val here = if (keep) {
            val shownRole = if (role == "group" && name != null && node.children.isEmpty()) "text" else role
            Node(
                // Compose's semantics id lasts as long as the element does,
                // so an id from one inspect still works in the next.
                tag ?: "_c" + Integer.toString(node.id, 36),
                shownRole,
                name,
                valueOf(node),
                statesOf(node),
                (b.left + dx) / density,
                (b.top + dy) / density,
                b.width / density,
                b.height / density,
                Target.OfCompose(node, owner),
            ).also {
                if (a11y) it.a11y = a11yOf(node, shownRole, name, hidden)
                parent.children += it
            }
        } else parent
        for (child in node.children) {
            if (child in absorbed) continue
            add(child, here, owner, dx, dy, density, a11y, hidden)
        }
    }

    private fun a11yOf(node: SemanticsNode, role: String, name: String?, hidden: Boolean): JSONObject {
        val c = node.config
        val a = JSONObject().put("class", "compose")
        if (role in elementRoles) {
            a.put("element", !hidden)
            if (name != null) a.put("label", name)
        }
        val text = c.getOrNull(SemanticsProperties.Text)?.joinToString(" ") { it.text }?.takeIf { it.isNotEmpty() }
        if (text != null) a.put("text", text)
        if (hidden && (text != null || name != null)) a.put("hiddenFromAccessibility", true)
        if (hidden && c.contains(SemanticsActions.OnClick)) a.put("unreachable", true)
        if (c.contains(SemanticsProperties.Focused)) a.put("focusable", true)
        fontOf(node)?.let { a.put("font", it) }
        return a
    }

    /** The text's size from its layout: sp follows the user's font size. */
    private fun fontOf(node: SemanticsNode): JSONObject? {
        val get = node.config.getOrNull(SemanticsActions.GetTextLayoutResult)?.action ?: return null
        val results = mutableListOf<TextLayoutResult>()
        if (!get(results)) return null
        val size = results.firstOrNull()?.layoutInput?.style?.fontSize ?: return null
        if (!size.isSp) return null
        return JSONObject().put("size", size.value.toDouble()).put("dynamicType", true)
    }

    private fun roleOf(node: SemanticsNode): String {
        val c = node.config
        return when (c.getOrNull(SemanticsProperties.Role)) {
            Role.Button -> "button"
            Role.Checkbox, Role.RadioButton -> "checkbox"
            Role.Switch -> "switch"
            Role.Tab -> "tab"
            Role.Image -> "image"
            Role.DropdownList -> "menu"
            else -> when {
                c.contains(SemanticsProperties.EditableText) ->
                    if (c.contains(SemanticsProperties.Password)) "securefield" else "textfield"
                c.contains(SemanticsProperties.ToggleableState) -> "checkbox"
                c.contains(SemanticsProperties.ProgressBarRangeInfo) && c.contains(SemanticsActions.SetProgress) -> "slider"
                c.contains(SemanticsProperties.VerticalScrollAxisRange) || c.contains(SemanticsProperties.HorizontalScrollAxisRange) -> "scrollview"
                c.contains(SemanticsActions.OnClick) -> "button"
                c.contains(SemanticsProperties.Text) -> "text"
                else -> "group"
            }
        }
    }

    private fun valueOf(node: SemanticsNode): Any? {
        val c = node.config
        c.getOrNull(SemanticsProperties.EditableText)?.let {
            return if (c.contains(SemanticsProperties.Password)) "" else it.text
        }
        c.getOrNull(SemanticsProperties.ToggleableState)?.let { return it == ToggleableState.On }
        c.getOrNull(SemanticsProperties.ProgressBarRangeInfo)?.let { return it.current }
        return null
    }

    private fun statesOf(node: SemanticsNode): Map<String, Boolean> {
        val c = node.config
        val s = mutableMapOf<String, Boolean>()
        if (c.contains(SemanticsProperties.Disabled)) s["enabled"] = false
        if (c.getOrNull(SemanticsProperties.Focused) == true) s["focused"] = true
        if (c.getOrNull(SemanticsProperties.Selected) == true) s["selected"] = true
        if (c.getOrNull(SemanticsProperties.ToggleableState) == ToggleableState.On) s["checked"] = true
        return s
    }

    /** The node's click action; false when it has none. */
    fun press(target: Target.OfCompose): Boolean {
        val node = target.node as SemanticsNode
        val action = node.config.getOrNull(SemanticsActions.OnClick)?.action ?: return false
        return action()
    }

    fun fill(target: Target.OfCompose, text: String): Boolean {
        val node = target.node as SemanticsNode
        node.config.getOrNull(SemanticsActions.RequestFocus)?.action?.invoke()
        val set = node.config.getOrNull(SemanticsActions.SetText)?.action ?: return false
        return set(AnnotatedString(text))
    }

    fun focus(target: Target.OfCompose): Boolean {
        val node = target.node as SemanticsNode
        return node.config.getOrNull(SemanticsActions.RequestFocus)?.action?.invoke() ?: false
    }

    /** Scroll by pixels; false when the node can't scroll. */
    fun scroll(target: Target.OfCompose, dxPx: Float, dyPx: Float): Boolean {
        val node = target.node as SemanticsNode
        val by = node.config.getOrNull(SemanticsActions.ScrollBy)?.action ?: return false
        return by(dxPx, dyPx)
    }

    fun canScroll(target: Target.OfCompose): Boolean =
        (target.node as SemanticsNode).config.contains(SemanticsActions.ScrollBy)
}
