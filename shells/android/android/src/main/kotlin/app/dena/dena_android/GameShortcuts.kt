// SPDX-License-Identifier: GPL-3.0-or-later
// Deep links and launcher shortcuts. Spec: docs/specs/shortcuts.md
package app.dena.dena_android

import android.content.Context
import android.content.Intent
import android.content.pm.ShortcutInfo
import android.content.pm.ShortcutManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.BlurMaskFilter
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.graphics.Rect
import android.graphics.RectF
import android.graphics.drawable.Icon
import android.net.Uri

/** Parses `dena://play/<sha1>` links. Pure so it runs in unit tests. */
object PlayLink {
    private val sha1 = Regex("^[0-9a-fA-F]{40}$")

    /** The lower-case SHA-1 of a play link, or null for anything else. */
    fun parse(link: String?): String? {
        if (link == null) return null
        val prefix = "dena://play/"
        if (!link.startsWith(prefix, ignoreCase = true)) return null
        val rest = link.substring(prefix.length).trimEnd('/')
        return if (sha1.matches(rest)) rest.lowercase() else null
    }

    fun of(sha1: String): String = "dena://play/$sha1"
}

/**
 * Draws a game's cover as an adaptive launcher icon: the whole cover, fitted
 * into the icon's safe zone with a soft shadow, over a blurred and darkened
 * copy of itself that fills the bleed area, so any launcher mask (circle,
 * squircle, square) shows the full box art.
 */
object CoverIcon {
    /** 108 dp at xxxhdpi. */
    const val SIZE = 432

    /** The 66 dp the launcher never crops, with a little margin. */
    private const val SAFE = SIZE * 62 / 108

    fun render(cover: Bitmap): Bitmap {
        val out = Bitmap.createBitmap(SIZE, SIZE, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(out)
        val paint = Paint(Paint.ANTI_ALIAS_FLAG or Paint.FILTER_BITMAP_FLAG)
        // Background: the cover shrunk to a few pixels and stretched back up
        // (a cheap blur), centre-cropped and dimmed.
        val tiny = Bitmap.createScaledBitmap(cover, 6, 6, true)
        canvas.drawBitmap(tiny, null, Rect(0, 0, SIZE, SIZE), paint)
        canvas.drawColor(Color.argb(110, 0, 0, 0))
        // Foreground: the full cover fitted into the safe zone.
        val scale = minOf(SAFE.toFloat() / cover.width, SAFE.toFloat() / cover.height)
        val w = cover.width * scale
        val h = cover.height * scale
        val dst = RectF((SIZE - w) / 2, (SIZE - h) / 2, (SIZE + w) / 2, (SIZE + h) / 2)
        val shadow = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.argb(140, 0, 0, 0)
            maskFilter = BlurMaskFilter(14f, BlurMaskFilter.Blur.NORMAL)
        }
        canvas.drawRoundRect(RectF(dst).apply { offset(0f, 8f) }, 10f, 10f, shadow)
        canvas.save()
        canvas.clipPath(Path().apply { addRoundRect(dst, 8f, 8f, Path.Direction.CW) })
        canvas.drawBitmap(cover, null, dst, paint)
        canvas.restore()
        return out
    }
}

class GameShortcuts(private val context: Context) {
    private var pending: String? = null
    private val manager get() = context.getSystemService(ShortcutManager::class.java)

    /** Remembers the link of a launch or new intent (ACTION_VIEW). */
    fun onIntent(intent: Intent?) {
        if (intent?.action != Intent.ACTION_VIEW) return
        PlayLink.parse(intent.dataString)?.let { pending = it }
    }

    fun takeLaunchLink(): String? = pending.also { pending = null }

    /** Asks the launcher to pin [sha1]'s shortcut. False if it can't. */
    fun pin(sha1: String, title: String, iconPath: String?): Boolean {
        val m = manager ?: return false
        if (!m.isRequestPinShortcutSupported) return false
        return m.requestPinShortcut(info(sha1, title, iconPath), null)
    }

    /** Puts [sha1] first among the recent-game shortcuts (max four). */
    fun reportPlayed(sha1: String, title: String, iconPath: String?) {
        val m = manager ?: return
        val max = minOf(MAX_RECENT, m.maxShortcutCountPerActivity)
        val others = m.dynamicShortcuts.filter { it.id != sha1 }.sortedBy { it.rank }
        val list = listOf(info(sha1, title, iconPath, rank = 0)) +
            others.take(max - 1).mapIndexed { i, s -> rerank(s, i + 1) }
        runCatching { m.dynamicShortcuts = list }
        m.reportShortcutUsed(sha1)
    }

    /** A game left the library: drop its recent shortcut, disable a pinned one. */
    fun remove(sha1: String) {
        val m = manager ?: return
        m.removeDynamicShortcuts(listOf(sha1))
        if (m.pinnedShortcuts.any { it.id == sha1 }) {
            m.disableShortcuts(listOf(sha1), "Game was removed")
        }
    }

    private fun rerank(s: ShortcutInfo, rank: Int): ShortcutInfo =
        ShortcutInfo.Builder(context, s.id)
            .setShortLabel(s.shortLabel ?: s.id)
            .apply { s.longLabel?.let { setLongLabel(it) } }
            .setIntent(s.intent ?: viewIntent(s.id))
            .setRank(rank)
            .build()

    private fun info(sha1: String, title: String, iconPath: String?, rank: Int = 0): ShortcutInfo =
        ShortcutInfo.Builder(context, sha1)
            .setShortLabel(title.take(SHORT_LABEL))
            .setLongLabel(title)
            .setIcon(icon(iconPath))
            .setIntent(viewIntent(sha1))
            .setRank(rank)
            .build()

    private fun viewIntent(sha1: String): Intent {
        val launch = context.packageManager.getLaunchIntentForPackage(context.packageName)
        return Intent(Intent.ACTION_VIEW, Uri.parse(PlayLink.of(sha1)))
            .setComponent(launch?.component)
            .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
    }

    private fun icon(path: String?): Icon {
        val bmp = path?.let { runCatching { BitmapFactory.decodeFile(it) }.getOrNull() }
            ?: return Icon.createWithResource(context, context.applicationInfo.icon)
        return runCatching { Icon.createWithAdaptiveBitmap(CoverIcon.render(bmp)) }
            .getOrElse { Icon.createWithBitmap(bmp) }
    }

    companion object {
        private const val MAX_RECENT = 4
        private const val SHORT_LABEL = 25
    }
}
