// SPDX-License-Identifier: GPL-3.0-or-later
// The game picture on an HDMI/USB-C display. Spec: docs/specs/external-display.md
package app.dena.dena_android

import android.app.Activity
import android.app.Presentation
import android.content.Context
import android.graphics.Color
import android.hardware.display.DisplayManager
import android.os.Bundle
import android.os.Handler
import android.view.Display
import android.view.Surface
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.View
import android.widget.FrameLayout

/**
 * Picks the surface the runner draws to: the external display's when there is
 * one, else the phone's. [sink] only hears about changes.
 */
class SurfaceRouter<T : Any>(private val sink: (T?) -> Unit) {
    private var phone: T? = null
    private var external: T? = null
    private var sent: T? = null

    fun setPhone(surface: T?) {
        phone = surface
        push()
    }

    fun setExternal(surface: T?) {
        external = surface
        push()
    }

    private fun push() {
        val want = external ?: phone
        if (want === sent) return
        sent = want
        sink(want)
    }
}

/** The runner's surfaces (phone SurfaceView / texture, external display). */
object Surfaces {
    val router = SurfaceRouter<Surface> { NativeRunner.nativeSetSurface(it) }

    /** The game's SurfaceViews; main thread only. */
    val views = mutableSetOf<SurfaceView>()

    /**
     * Gives every game SurfaceView a new surface by hiding and showing it, for
     * the runner's switch from the CPU blit to GLES (shaders.md): a window the
     * CPU has drawn to can't take an EGL surface.
     */
    fun refresh() {
        for (v in views.toList()) {
            v.visibility = View.INVISIBLE
            v.post { v.visibility = View.VISIBLE }
        }
    }
}

/** The centred rect of [aspect] (width / height) inside a [w]×[h] display. */
fun fitAspect(w: Int, h: Int, aspect: Double): IntArray {
    if (w <= 0 || h <= 0 || aspect <= 0) return intArrayOf(0, 0, w, h)
    var fw = w
    var fh = Math.round(w / aspect).toInt()
    if (fh > h) {
        fh = h
        fw = Math.round(h * aspect).toInt()
    }
    return intArrayOf((w - fw) / 2, (h - fh) / 2, fw, fh)
}

/**
 * While a session runs, shows a [Presentation] on the first presentation
 * display and routes the picture there; reports the display name (or null).
 */
class ExternalDisplay(
    private val context: Context,
    private val handler: Handler,
    private val onChanged: (String?) -> Unit,
) {
    var activity: Activity? = null
    var aspect = 4.0 / 3.0
        set(value) {
            field = value
            presentation?.relayout()
        }
    private var presentation: GamePresentation? = null
    private var active = false
    private val displays get() = context.getSystemService(DisplayManager::class.java)

    private val listener = object : DisplayManager.DisplayListener {
        override fun onDisplayAdded(displayId: Int) = update()
        override fun onDisplayRemoved(displayId: Int) = update()
        override fun onDisplayChanged(displayId: Int) {}
    }

    fun start() {
        if (active) return
        active = true
        displays?.registerDisplayListener(listener, handler)
        update()
    }

    fun stop() {
        if (!active) return
        active = false
        displays?.unregisterDisplayListener(listener)
        close()
    }

    private fun update() {
        val target = displays?.getDisplays(DisplayManager.DISPLAY_CATEGORY_PRESENTATION)?.firstOrNull()
        val current = presentation
        if (current != null && current.display.displayId == target?.displayId) return
        close()
        val a = activity
        if (!active || target == null || a == null) return
        val p = GamePresentation(a, target)
        try {
            p.show()
        } catch (e: Exception) { // WindowManager.InvalidDisplayException and friends
            Surfaces.router.setExternal(null)
            return
        }
        presentation = p
        onChanged(target.name)
    }

    private fun close() {
        val p = presentation ?: return
        presentation = null
        Surfaces.router.setExternal(null)
        Surfaces.views.remove(p.surface)
        runCatching { p.dismiss() }
        onChanged(null)
    }

    private inner class GamePresentation(outer: Activity, display: Display) :
        Presentation(outer, display), SurfaceHolder.Callback {
        private val frame = FrameLayout(outer).apply { setBackgroundColor(Color.BLACK) }
        val surface = SurfaceView(outer)

        override fun onCreate(savedInstanceState: Bundle?) {
            super.onCreate(savedInstanceState)
            surface.holder.addCallback(this)
            Surfaces.views.add(surface)
            frame.addView(surface, FrameLayout.LayoutParams(0, 0))
            frame.addOnLayoutChangeListener { _, _, _, _, _, _, _, _, _ -> relayout() }
            setContentView(frame)
        }

        fun relayout() {
            val r = fitAspect(frame.width, frame.height, aspect)
            val lp = surface.layoutParams as FrameLayout.LayoutParams
            if (lp.leftMargin == r[0] && lp.topMargin == r[1] && lp.width == r[2] && lp.height == r[3]) return
            lp.leftMargin = r[0]
            lp.topMargin = r[1]
            lp.width = r[2]
            lp.height = r[3]
            surface.layoutParams = lp
        }

        override fun surfaceCreated(holder: SurfaceHolder) = Surfaces.router.setExternal(holder.surface)
        override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {}
        override fun surfaceDestroyed(holder: SurfaceHolder) = Surfaces.router.setExternal(null)
    }
}
