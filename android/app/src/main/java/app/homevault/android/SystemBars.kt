package app.homevault.android

import android.os.Build
import android.view.View
import android.view.WindowInsets

/**
 * Android 15+ (API 35) enforces edge-to-edge for apps targeting API 35+: the window draws behind
 * the status/navigation bars and the IME no longer resizes it. Pad the layout ourselves there.
 * On older versions the platform keeps the classic, already-inset layout.
 */
object SystemBars {
    fun applyInsets(root: View, appBar: View) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.VANILLA_ICE_CREAM) return
        root.setOnApplyWindowInsetsListener { view, insets ->
            val bars = insets.getInsets(WindowInsets.Type.systemBars() or WindowInsets.Type.displayCutout())
            val ime = insets.getInsets(WindowInsets.Type.ime())
            appBar.setPadding(0, bars.top, 0, 0)
            view.setPadding(bars.left, 0, bars.right, maxOf(bars.bottom, ime.bottom))
            WindowInsets.CONSUMED
        }
        root.requestApplyInsets()
    }
}
