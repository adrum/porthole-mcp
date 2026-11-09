package dev.porthole

import android.app.Activity
import android.app.Application
import android.os.Bundle
import android.view.View
import android.view.ViewTreeObserver
import java.lang.ref.WeakReference
import java.util.WeakHashMap

/** One window the agent can reach: its root view and what to call it. */
internal class AppWindow(val root: View, val title: String) {
    val id: String get() = "w" + Integer.toString(System.identityHashCode(root), 36)
    val key: Boolean get() = root.hasWindowFocus()
}

/**
 * The app's windows: the resumed activities, plus dialogs and popups when
 * the platform's window list can be read. Each window's draw pass tells the
 * hub the screen changed.
 */
internal object Windows {
    private val activities = mutableListOf<WeakReference<Activity>>()
    private val watched = WeakHashMap<View, Boolean>()

    fun install(app: Application?) {
        val application = app ?: return
        application.registerActivityLifecycleCallbacks(object : Application.ActivityLifecycleCallbacks {
            override fun onActivityResumed(activity: Activity) {
                activities.removeAll { it.get() == null || it.get() === activity }
                activities += WeakReference(activity)
                Porthole.uiChanged()
            }

            override fun onActivityPaused(activity: Activity) {}
            override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) {}
            override fun onActivityStarted(activity: Activity) {}
            override fun onActivityStopped(activity: Activity) {
                activities.removeAll { it.get() == null || it.get() === activity }
                Porthole.uiChanged()
            }

            override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) {}
            override fun onActivityDestroyed(activity: Activity) {
                activities.removeAll { it.get() == null || it.get() === activity }
            }
        })
    }

    fun install(context: android.content.Context) = install(context as? Application)

    /** Whether one of the app's activities is resumed: the app is in front. */
    fun inForeground(): Boolean = activities.any { it.get() != null }

    /** Visible windows, front to back. */
    fun all(): List<AppWindow> {
        val windows = mutableListOf<AppWindow>()
        val seen = HashSet<View>()
        // The platform's own list holds dialogs and popups as well. It's not
        // public API, so it's read when it can be and skipped when not.
        for (root in platformRoots().asReversed()) {
            if (root.isShown && root.width > 0 && root.height > 0 && seen.add(root)) {
                windows += AppWindow(root, titleOf(root))
            }
        }
        for (ref in activities.asReversed()) {
            val activity = ref.get() ?: continue
            val root = activity.window?.decorView ?: continue
            if (root.isShown && seen.add(root)) windows += AppWindow(root, activity.title?.toString() ?: "")
        }
        for (w in windows) watch(w.root)
        return windows
    }

    /** The window a request is for: the named one, the focused one, or the front one. */
    fun resolve(id: String?): AppWindow {
        val all = all()
        if (id != null) {
            return all.firstOrNull { it.id == id }
                ?: throw HarnessError("not_found", "no window \"$id\"; windows: " + all.joinToString { "${it.id} \"${it.title}\"" }.ifEmpty { "none" })
        }
        return all.firstOrNull { it.key } ?: all.firstOrNull()
            ?: throw HarnessError("not_found", "the app has no visible windows")
    }

    private fun titleOf(root: View): String {
        for (ref in activities) {
            val activity = ref.get() ?: continue
            if (activity.window?.decorView === root) return activity.title?.toString() ?: ""
        }
        return (root.layoutParams as? android.view.WindowManager.LayoutParams)?.title?.toString() ?: ""
    }

    @Suppress("UNCHECKED_CAST", "PrivateApi", "DiscouragedPrivateApi")
    private fun platformRoots(): List<View> = try {
        val global = Class.forName("android.view.WindowManagerGlobal")
        val instance = global.getMethod("getInstance").invoke(null)
        val field = global.getDeclaredField("mViews").apply { isAccessible = true }
        (field.get(instance) as? List<View>)?.toList() ?: emptyList()
    } catch (_: Throwable) {
        emptyList()
    }

    private fun watch(root: View) {
        if (watched.containsKey(root)) return
        watched[root] = true
        root.viewTreeObserver.addOnDrawListener(ViewTreeObserver.OnDrawListener { Porthole.uiChanged() })
    }
}
