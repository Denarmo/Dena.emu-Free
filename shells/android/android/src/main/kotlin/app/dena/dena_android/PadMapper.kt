// SPDX-License-Identifier: GPL-3.0-or-later
// Spec: docs/specs/latency-spike.md (Input)
package app.dena.dena_android

import android.view.KeyEvent

/**
 * libretro RetroPad button ids.
 *
 * The ids are bit indices, matching the order libretro reports in the joypad
 * state; use [bit] to turn one into a mask.
 */
object RetroPad {
    /** Bottom face button. */
    const val B = 0

    /** Left face button. */
    const val Y = 1

    /** Select button. */
    const val SELECT = 2

    /** Start button. */
    const val START = 3

    /** D-pad up. */
    const val UP = 4

    /** D-pad down. */
    const val DOWN = 5

    /** D-pad left. */
    const val LEFT = 6

    /** D-pad right. */
    const val RIGHT = 7

    /** Right face button. */
    const val A = 8

    /** Top face button. */
    const val X = 9

    /** Left shoulder. */
    const val L = 10

    /** Right shoulder. */
    const val R = 11

    /** Left trigger. */
    const val L2 = 12

    /** Right trigger. */
    const val R2 = 13

    /** Left thumbstick click. */
    const val L3 = 14

    /** Right thumbstick click. */
    const val R3 = 15

    /** Returns the single-bit mask for the button at index [id]. */
    fun bit(id: Int): Int = 1 shl id
}

/**
 * Maps Android key codes to RetroPad button ids.
 *
 * The mapping is positional: the bottom face button is [RetroPad.B], matching
 * an SNES-style pad rather than the labels printed on an Xbox controller.
 * Only `KeyEvent` constants are used, so this is testable on the JVM.
 */
object PadMapper {
    /**
     * Returns the [RetroPad] bit index for [keyCode], or null when the key is
     * not mapped.
     */
    fun buttonFor(keyCode: Int): Int? = when (keyCode) {
        // Gamepad face buttons, positional.
        KeyEvent.KEYCODE_BUTTON_A -> RetroPad.B
        KeyEvent.KEYCODE_BUTTON_B -> RetroPad.A
        KeyEvent.KEYCODE_BUTTON_X -> RetroPad.Y
        KeyEvent.KEYCODE_BUTTON_Y -> RetroPad.X
        // Shoulders.
        KeyEvent.KEYCODE_BUTTON_L1 -> RetroPad.L
        KeyEvent.KEYCODE_BUTTON_R1 -> RetroPad.R
        // Triggers.
        KeyEvent.KEYCODE_BUTTON_L2 -> RetroPad.L2
        KeyEvent.KEYCODE_BUTTON_R2 -> RetroPad.R2
        // Thumbstick clicks.
        KeyEvent.KEYCODE_BUTTON_THUMBL -> RetroPad.L3
        KeyEvent.KEYCODE_BUTTON_THUMBR -> RetroPad.R3
        // Menu buttons.
        KeyEvent.KEYCODE_BUTTON_START -> RetroPad.START
        KeyEvent.KEYCODE_BUTTON_SELECT -> RetroPad.SELECT
        // D-pad.
        KeyEvent.KEYCODE_DPAD_UP -> RetroPad.UP
        KeyEvent.KEYCODE_DPAD_DOWN -> RetroPad.DOWN
        KeyEvent.KEYCODE_DPAD_LEFT -> RetroPad.LEFT
        KeyEvent.KEYCODE_DPAD_RIGHT -> RetroPad.RIGHT
        KeyEvent.KEYCODE_DPAD_CENTER -> RetroPad.A
        // Keyboard, same positional layout.
        KeyEvent.KEYCODE_Z -> RetroPad.B
        KeyEvent.KEYCODE_X -> RetroPad.A
        KeyEvent.KEYCODE_A -> RetroPad.Y
        KeyEvent.KEYCODE_S -> RetroPad.X
        KeyEvent.KEYCODE_Q -> RetroPad.L
        KeyEvent.KEYCODE_W -> RetroPad.R
        KeyEvent.KEYCODE_ENTER -> RetroPad.START
        KeyEvent.KEYCODE_DEL -> RetroPad.SELECT
        KeyEvent.KEYCODE_SHIFT_RIGHT -> RetroPad.SELECT
        else -> null
    }
}

/**
 * Accumulated RetroPad state from button and axis input.
 *
 * Buttons and axes are tracked in separate masks so that recomputing the axes
 * from a motion event never clobbers held buttons; [mask] is their union.
 */
class PadState {
    /** Mask of buttons currently held (set by [onKey]). */
    private var buttons = 0

    /** Mask derived from the latest motion event (set by [onAxes]). */
    private var axes = 0

    /** Combined button and axis mask sent to native. */
    val mask: Int
        get() = buttons or axes

    /**
     * Sets or clears the bit for [keyCode] and returns true when the key is
     * mapped; unmapped keys return false and leave the state unchanged.
     */
    fun onKey(keyCode: Int, down: Boolean): Boolean {
        val id = PadMapper.buttonFor(keyCode) ?: return false
        val bit = RetroPad.bit(id)
        buttons = if (down) buttons or bit else buttons and bit.inv()
        return true
    }

    /**
     * Recomputes the axis mask from the latest values.
     *
     * Hats read as -1/0/1; sticks use [DEADZONE]; triggers press above 0.5.
     * Android Y axes are positive downward, so a negative Y is up.
     */
    fun onAxes(
        hatX: Float,
        hatY: Float,
        stickX: Float,
        stickY: Float,
        leftTrigger: Float,
        rightTrigger: Float,
        stickAsDpad: Boolean = true,
    ) {
        var m = 0
        // With analog games (n64.md) the stick is passed through as analog
        // instead of pressing the D-pad.
        val sx = if (stickAsDpad) stickX else 0f
        val sy = if (stickAsDpad) stickY else 0f
        if (hatX < -0.5f || sx < -DEADZONE) m = m or RetroPad.bit(RetroPad.LEFT)
        if (hatX > 0.5f || sx > DEADZONE) m = m or RetroPad.bit(RetroPad.RIGHT)
        if (hatY < -0.5f || sy < -DEADZONE) m = m or RetroPad.bit(RetroPad.UP)
        if (hatY > 0.5f || sy > DEADZONE) m = m or RetroPad.bit(RetroPad.DOWN)
        if (leftTrigger > 0.5f) m = m or RetroPad.bit(RetroPad.L2)
        if (rightTrigger > 0.5f) m = m or RetroPad.bit(RetroPad.R2)
        axes = m
    }

    /** Clears both the button and axis masks. */
    fun reset() {
        buttons = 0
        axes = 0
    }

    companion object {
        /** Analog stick deadzone; values past this register as a direction. */
        const val DEADZONE = 0.5f
    }
}
