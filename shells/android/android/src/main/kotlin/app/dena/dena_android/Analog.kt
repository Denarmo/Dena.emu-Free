// SPDX-License-Identifier: GPL-3.0-or-later
// Spec: docs/specs/n64.md (Controls)
package app.dena.dena_android

/** Android stick axes (-1..1, +y down) to libretro analog values. */
object Analog {
    /** Inside this, a stick reads as centred (worn sticks drift). */
    const val DEADZONE = 0.12f

    /** -1..1 to -0x7fff..0x7fff, rescaled so the deadzone edge is 0. */
    fun scale(v: Float): Int {
        val a = kotlin.math.abs(v)
        if (a < DEADZONE) return 0
        val t = ((a - DEADZONE) / (1f - DEADZONE)).coerceAtMost(1f)
        return (if (v < 0) -t else t).times(0x7fff).toInt()
    }
}
