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

    fun addTree(view: View, parent: Node, origin: IntArray, density: Float) {
        val owner = (view as ViewRootForTest).semanticsOwner
        // Semantics bounds are in window coordinates, as view locations are;
        // measure from the window root's origin, as the view tree does.
        add(owner.unmergedRootSemanticsNode, parent, view, -origin[0].toFloat(), -origin[1].toFloat(), density)
    }

    private fun add(node: SemanticsNode, parent: Node, owner: View, dx: Float, dy: Float, density: Float) {
        val c = node.config
        if (c.contains(SemanticsProperties.InvisibleToUser)) return
        val b = node.boundsInWindow
        if (b.width <= 0f || b.height <= 0f) return
        val role = roleOf(node)
        val tag = c.getOrNull(SemanticsProperties.TestTag)
        val name = c.getOrNull(SemanticsProperties.ContentDescription)?.joinToString(" ")?.takeIf { it.isNotEmpty() }
            ?: c.getOrNull(SemanticsProperties.Text)?.joinToString(" ") { it.text }?.takeIf { it.isNotEmpty() }
        val keep = role != "group" || tag != null || name != null && node.children.isEmpty() ||
            c.contains(SemanticsActions.OnClick)
        val here = if (keep) {
            Node(
                tag ?: Tree.synthesized(node),
                if (role == "group" && name != null && node.children.isEmpty()) "text" else role,
                name,
                valueOf(node),
                statesOf(node),
                (b.left + dx) / density,
                (b.top + dy) / density,
                b.width / density,
                b.height / density,
                Target.OfCompose(node, owner),
            ).also { parent.children += it }
        } else parent
        for (child in node.children) add(child, here, owner, dx, dy, density)
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
