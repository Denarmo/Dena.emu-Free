// SPDX-License-Identifier: GPL-3.0-or-later
// Spec: docs/specs/gamepads.md
package app.dena.dena_android

import android.view.KeyEvent
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class PlayerSlotsTest {
    private val a = KeyEvent.KEYCODE_BUTTON_A // RetroPad B
    private val start = KeyEvent.KEYCODE_BUTTON_START
    private val select = KeyEvent.KEYCODE_BUTTON_SELECT

    @Test
    fun portsGoInOrderOfFirstPress() {
        val s = PlayerSlots()
        val first = s.onKey(20, "Pad 20", a, true)
        assertEquals(0, first.port)
        assertTrue(first.assigned)
        assertEquals(RetroPad.bit(RetroPad.B), first.mask)
        assertEquals(1, s.onKey(10, "Pad 10", a, true).port)
        assertEquals(0, s.onKey(20, "Pad 20", a, false).port)
        assertEquals(listOf("Pad 20", "Pad 10", "", ""), s.names())
    }

    @Test
    fun releaseWithoutPortAndUnmappedKeysTakeNoPort() {
        val s = PlayerSlots()
        assertNull(s.onKey(1, "Pad", a, false).port)
        assertFalse(s.onKey(1, "Pad", KeyEvent.KEYCODE_VOLUME_UP, true).handled)
        assertNull(s.portOf(1))
    }

    @Test
    fun fifthDeviceIsIgnored() {
        val s = PlayerSlots()
        for (d in 1..4) s.onKey(d, "Pad $d", a, true)
        val fifth = s.onKey(5, "Pad 5", a, true)
        assertTrue(fifth.handled)
        assertNull(fifth.port)
    }

    @Test
    fun disconnectFreesThePortForTheNextDevice() {
        val s = PlayerSlots()
        s.onKey(1, "One", a, true)
        s.onKey(2, "Two", a, true)
        assertEquals(0, s.disconnect(1))
        assertNull(s.disconnect(1))
        assertEquals(listOf("", "Two", "", ""), s.names())
        assertEquals(0, s.onKey(3, "Three", a, true).port)
    }

    @Test
    fun startPlusSelectRequestsTheMenuAndReleasesButtons() {
        val s = PlayerSlots()
        s.onKey(1, "Pad", start, true)
        val chord = s.onKey(1, "Pad", select, true)
        assertTrue(chord.menu)
        assertEquals(0, chord.mask)
        val after = s.onKey(1, "Pad", start, false)
        assertFalse(after.menu)
        assertEquals(0, after.mask)
    }

    @Test
    fun stickMovementTakesAPortAndStillAxesDoNotRepeat() {
        val s = PlayerSlots()
        val idle = s.onAxes(7, "Stick", 0f, 0f, 0f, 0f, 0f, 0f)
        assertNull(idle.port)
        val left = s.onAxes(7, "Stick", 0f, 0f, -1f, 0f, 0f, 0f)
        assertEquals(0, left.port)
        assertEquals(RetroPad.bit(RetroPad.LEFT), left.mask)
        assertNull(s.onAxes(7, "Stick", 0f, 0f, -1f, 0f, 0f, 0f).port)
    }

    @Test
    fun resetFreesEverything() {
        val s = PlayerSlots()
        s.onKey(1, "Pad", a, true)
        s.reset()
        assertEquals(listOf("", "", "", ""), s.names())
        assertNull(s.portOf(1))
    }
}
