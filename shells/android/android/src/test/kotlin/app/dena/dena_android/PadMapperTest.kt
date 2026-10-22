// SPDX-License-Identifier: GPL-3.0-or-later
// Spec: docs/specs/latency-spike.md (Input)
package app.dena.dena_android

import android.view.KeyEvent
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class PadMapperTest {
    private val buttonMappings = mapOf(
        // Gamepad, positional.
        KeyEvent.KEYCODE_BUTTON_A to RetroPad.B,
        KeyEvent.KEYCODE_BUTTON_B to RetroPad.A,
        KeyEvent.KEYCODE_BUTTON_X to RetroPad.Y,
        KeyEvent.KEYCODE_BUTTON_Y to RetroPad.X,
        KeyEvent.KEYCODE_BUTTON_L1 to RetroPad.L,
        KeyEvent.KEYCODE_BUTTON_R1 to RetroPad.R,
        KeyEvent.KEYCODE_BUTTON_L2 to RetroPad.L2,
        KeyEvent.KEYCODE_BUTTON_R2 to RetroPad.R2,
        KeyEvent.KEYCODE_BUTTON_THUMBL to RetroPad.L3,
        KeyEvent.KEYCODE_BUTTON_THUMBR to RetroPad.R3,
        KeyEvent.KEYCODE_BUTTON_START to RetroPad.START,
        KeyEvent.KEYCODE_BUTTON_SELECT to RetroPad.SELECT,
        KeyEvent.KEYCODE_DPAD_UP to RetroPad.UP,
        KeyEvent.KEYCODE_DPAD_DOWN to RetroPad.DOWN,
        KeyEvent.KEYCODE_DPAD_LEFT to RetroPad.LEFT,
        KeyEvent.KEYCODE_DPAD_RIGHT to RetroPad.RIGHT,
        KeyEvent.KEYCODE_DPAD_CENTER to RetroPad.A,
        // Keyboard, same positional layout.
        KeyEvent.KEYCODE_Z to RetroPad.B,
        KeyEvent.KEYCODE_X to RetroPad.A,
        KeyEvent.KEYCODE_A to RetroPad.Y,
        KeyEvent.KEYCODE_S to RetroPad.X,
        KeyEvent.KEYCODE_Q to RetroPad.L,
        KeyEvent.KEYCODE_W to RetroPad.R,
        KeyEvent.KEYCODE_ENTER to RetroPad.START,
        KeyEvent.KEYCODE_DEL to RetroPad.SELECT,
        KeyEvent.KEYCODE_SHIFT_RIGHT to RetroPad.SELECT,
    )

    @Test
    fun buttonForMapsEveryControllerAndKeyboardKey() {
        for ((keyCode, id) in buttonMappings) {
            assertEquals(id, PadMapper.buttonFor(keyCode), "keyCode $keyCode")
        }
    }

    @Test
    fun buttonForReturnsNullForUnmappedKey() {
        assertNull(PadMapper.buttonFor(KeyEvent.KEYCODE_HOME))
    }

    @Test
    fun onKeySetsThenClearsBit() {
        val pad = PadState()
        assertTrue(pad.onKey(KeyEvent.KEYCODE_BUTTON_A, down = true))
        assertEquals(RetroPad.bit(RetroPad.B), pad.mask)
        assertTrue(pad.onKey(KeyEvent.KEYCODE_BUTTON_A, down = false))
        assertEquals(0, pad.mask)
    }

    @Test
    fun twoButtonsHeldAtOnce() {
        val pad = PadState()
        pad.onKey(KeyEvent.KEYCODE_BUTTON_A, down = true)
        pad.onKey(KeyEvent.KEYCODE_BUTTON_B, down = true)
        assertEquals(RetroPad.bit(RetroPad.B) or RetroPad.bit(RetroPad.A), pad.mask)
        pad.onKey(KeyEvent.KEYCODE_BUTTON_A, down = false)
        assertEquals(RetroPad.bit(RetroPad.A), pad.mask)
    }

    @Test
    fun unmappedKeyReturnsFalseAndLeavesMaskUnchanged() {
        val pad = PadState()
        assertFalse(pad.onKey(KeyEvent.KEYCODE_HOME, down = true))
        assertEquals(0, pad.mask)

        pad.onKey(KeyEvent.KEYCODE_BUTTON_A, down = true)
        val before = pad.mask
        assertFalse(pad.onKey(KeyEvent.KEYCODE_HOME, down = true))
        assertEquals(before, pad.mask)
    }

    @Test
    fun axesHatDirections() {
        val pad = PadState()
        pad.onAxes(hatX = -1f, hatY = 0f, stickX = 0f, stickY = 0f, leftTrigger = 0f, rightTrigger = 0f)
        assertEquals(RetroPad.bit(RetroPad.LEFT), pad.mask)
        pad.onAxes(hatX = 1f, hatY = 0f, stickX = 0f, stickY = 0f, leftTrigger = 0f, rightTrigger = 0f)
        assertEquals(RetroPad.bit(RetroPad.RIGHT), pad.mask)
        pad.onAxes(hatX = 0f, hatY = -1f, stickX = 0f, stickY = 0f, leftTrigger = 0f, rightTrigger = 0f)
        assertEquals(RetroPad.bit(RetroPad.UP), pad.mask)
        pad.onAxes(hatX = 0f, hatY = 1f, stickX = 0f, stickY = 0f, leftTrigger = 0f, rightTrigger = 0f)
        assertEquals(RetroPad.bit(RetroPad.DOWN), pad.mask)
    }

    @Test
    fun axesStickDirectionsAndDeadzone() {
        val pad = PadState()
        pad.onAxes(0f, 0f, stickX = -0.4f, stickY = 0f, leftTrigger = 0f, rightTrigger = 0f)
        assertEquals(0, pad.mask)
        pad.onAxes(0f, 0f, stickX = -0.6f, stickY = 0f, leftTrigger = 0f, rightTrigger = 0f)
        assertEquals(RetroPad.bit(RetroPad.LEFT), pad.mask)

        pad.onAxes(0f, 0f, stickX = 0.4f, stickY = 0f, leftTrigger = 0f, rightTrigger = 0f)
        assertEquals(0, pad.mask)
        pad.onAxes(0f, 0f, stickX = 0.6f, stickY = 0f, leftTrigger = 0f, rightTrigger = 0f)
        assertEquals(RetroPad.bit(RetroPad.RIGHT), pad.mask)

        pad.onAxes(0f, 0f, stickX = 0f, stickY = -0.6f, leftTrigger = 0f, rightTrigger = 0f)
        assertEquals(RetroPad.bit(RetroPad.UP), pad.mask)
        pad.onAxes(0f, 0f, stickX = 0f, stickY = 0.6f, leftTrigger = 0f, rightTrigger = 0f)
        assertEquals(RetroPad.bit(RetroPad.DOWN), pad.mask)
    }

    @Test
    fun axesTriggers() {
        val pad = PadState()
        pad.onAxes(0f, 0f, 0f, 0f, leftTrigger = 0.4f, rightTrigger = 0.4f)
        assertEquals(0, pad.mask)
        pad.onAxes(0f, 0f, 0f, 0f, leftTrigger = 0.6f, rightTrigger = 0.6f)
        assertEquals(RetroPad.bit(RetroPad.L2) or RetroPad.bit(RetroPad.R2), pad.mask)
    }

    @Test
    fun axesAndButtonsCombineWithOr() {
        val pad = PadState()
        pad.onKey(KeyEvent.KEYCODE_BUTTON_A, down = true)
        pad.onAxes(hatX = -1f, hatY = 0f, stickX = 0f, stickY = 0f, leftTrigger = 0f, rightTrigger = 0f)
        assertEquals(RetroPad.bit(RetroPad.B) or RetroPad.bit(RetroPad.LEFT), pad.mask)

        // Clearing the axes keeps the held button.
        pad.onAxes(hatX = 0f, hatY = 0f, stickX = 0f, stickY = 0f, leftTrigger = 0f, rightTrigger = 0f)
        assertEquals(RetroPad.bit(RetroPad.B), pad.mask)
    }

    @Test
    fun resetClearsBothMasks() {
        val pad = PadState()
        pad.onKey(KeyEvent.KEYCODE_BUTTON_A, down = true)
        pad.onAxes(0f, 0f, stickX = -1f, stickY = 0f, leftTrigger = 1f, rightTrigger = 0f)
        assertTrue(pad.mask != 0)
        pad.reset()
        assertEquals(0, pad.mask)
    }
}
