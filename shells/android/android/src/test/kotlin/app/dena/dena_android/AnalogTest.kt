// SPDX-License-Identifier: GPL-3.0-or-later
// Spec: docs/specs/n64.md (Controls)
package app.dena.dena_android

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class AnalogTest {
    @Test
    fun deadzoneReadsAsCentreAndFullTiltIsMax() {
        assertEquals(0, Analog.scale(0f))
        assertEquals(0, Analog.scale(Analog.DEADZONE * 0.9f))
        assertEquals(0x7fff, Analog.scale(1f))
        assertEquals(-0x7fff, Analog.scale(-1f))
        val half = Analog.scale(0.56f)
        assertTrue(half in 0x3000..0x5000, "half tilt was $half")
    }

    @Test
    fun analogModeKeepsTheStickOffTheDpad() {
        val pad = PadState()
        pad.onAxes(0f, 0f, 1f, -1f, 0f, 0f, stickAsDpad = false)
        assertEquals(0, pad.mask)
        pad.onAxes(1f, 0f, 1f, -1f, 0f, 0f, stickAsDpad = false)
        assertEquals(RetroPad.bit(RetroPad.RIGHT), pad.mask) // the hat still works
        pad.onAxes(0f, 0f, 1f, 0f, 0f, 0f)
        assertEquals(RetroPad.bit(RetroPad.RIGHT), pad.mask) // default: stick as D-pad
    }
}
