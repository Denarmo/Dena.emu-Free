// SPDX-License-Identifier: GPL-3.0-or-later
// Specs: docs/specs/latency-spike.md (Input), docs/specs/gamepads.md
package app.dena.dena_android

import android.view.InputDevice
import android.view.KeyEvent
import android.view.MotionEvent

/**
 * Reads gamepad and keyboard input before Flutter sees it. The host Activity
 * calls [dispatchKeyEvent] and [dispatchGenericMotionEvent] first and only
 * passes events on to Flutter when these return false.
 */
object DenaInput {
    /** Session events for the Dart side; set by the plugin. Main thread. */
    interface Listener {
        fun onMenuRequested()
        fun onPlayersChanged(names: List<String>)
        fun onControllerDisconnected(port: Int, name: String)
        fun onGamepadUsed()
    }

    /** Touch controls are showing; the next pad press reports [Listener.onGamepadUsed]. */
    @Volatile
    var touchMode = false

    var listener: Listener? = null

    /** The game reads analog sticks (n64.md): sticks are sent as analog, not D-pad. */
    @Volatile
    var analogMode = false

    /**
     * True while a game is running and not paused; otherwise every event goes
     * to Flutter. Pausing keeps the player slots; [endSession] clears them.
     */
    @Volatile
    var active = false
        set(value) {
            field = value
            if (!value) slots.releaseAll()
        }

    private val slots = PlayerSlots()

    /** Frees every port (the session ended). */
    fun endSession() {
        active = false
        slots.reset()
        listener?.onPlayersChanged(slots.names())
    }

    /** A device was unplugged or switched off. */
    fun onDeviceRemoved(deviceId: Int) {
        val name = slots.names().getOrNull(slots.portOf(deviceId) ?: -1) ?: ""
        val port = slots.disconnect(deviceId) ?: return
        NativeRunner.nativeSetButtons(port, 0, android.os.SystemClock.uptimeMillis())
        listener?.onPlayersChanged(slots.names())
        listener?.onControllerDisconnected(port, name)
    }

    fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (!active) return false
        val down = when (event.action) {
            KeyEvent.ACTION_DOWN -> true
            KeyEvent.ACTION_UP -> false
            else -> return false
        }
        if (down && event.repeatCount > 0) return PadMapper.buttonFor(event.keyCode) != null
        val u = slots.onKey(event.deviceId, deviceName(event.device), event.keyCode, down)
        apply(u, event.eventTime)
        return u.handled
    }

    fun dispatchGenericMotionEvent(event: MotionEvent): Boolean {
        if (!active) return false
        val joystick = event.isFromSource(InputDevice.SOURCE_JOYSTICK) ||
            event.isFromSource(InputDevice.SOURCE_GAMEPAD)
        if (!joystick || event.action != MotionEvent.ACTION_MOVE) return false
        val u = slots.onAxes(
            device = event.deviceId,
            name = deviceName(event.device),
            hatX = event.getAxisValue(MotionEvent.AXIS_HAT_X),
            hatY = event.getAxisValue(MotionEvent.AXIS_HAT_Y),
            stickX = event.getAxisValue(MotionEvent.AXIS_X),
            stickY = event.getAxisValue(MotionEvent.AXIS_Y),
            leftTrigger = maxOf(
                event.getAxisValue(MotionEvent.AXIS_LTRIGGER),
                event.getAxisValue(MotionEvent.AXIS_BRAKE),
            ),
            rightTrigger = maxOf(
                event.getAxisValue(MotionEvent.AXIS_RTRIGGER),
                event.getAxisValue(MotionEvent.AXIS_GAS),
            ),
            stickAsDpad = !analogMode,
        )
        apply(u, event.eventTime)
        if (analogMode) {
            slots.portOf(event.deviceId)?.let { port ->
                NativeRunner.nativeSetAnalog(
                    port,
                    Analog.scale(event.getAxisValue(MotionEvent.AXIS_X)),
                    Analog.scale(event.getAxisValue(MotionEvent.AXIS_Y)),
                    Analog.scale(event.getAxisValue(MotionEvent.AXIS_Z)),
                    Analog.scale(event.getAxisValue(MotionEvent.AXIS_RZ)),
                )
            }
        }
        return true
    }

    private fun apply(u: PlayerSlots.Update, eventTime: Long) {
        val port = u.port ?: return
        NativeRunner.nativeSetButtons(port, u.mask, eventTime)
        if (touchMode && u.mask != 0) {
            touchMode = false
            listener?.onGamepadUsed()
        }
        if (u.assigned) listener?.onPlayersChanged(slots.names())
        if (u.menu) listener?.onMenuRequested()
    }

    private fun deviceName(device: InputDevice?): String = device?.name ?: "Keyboard"
}
