// SPDX-License-Identifier: GPL-3.0-or-later
// Spec: docs/specs/gamepads.md
package app.dena.dena_android

/**
 * Assigns input devices to the four RetroPad ports and keeps one [PadState]
 * per device. Pure logic (no Android types) so it runs in JVM tests.
 *
 * A device takes the lowest free port with its first mapped press and keeps it
 * until [disconnect] or [reset]. A fifth device is ignored.
 */
class PlayerSlots(private val maxPorts: Int = 4) {
    /** What an input event changed. [port] is null when the event was ignored. */
    data class Update(
        val handled: Boolean,
        val port: Int? = null,
        val mask: Int = 0,
        /** Start + Select were pressed together: open the pause menu. */
        val menu: Boolean = false,
        /** A device took a port with this event. */
        val assigned: Boolean = false,
    )

    private val deviceAt = arrayOfNulls<Int>(maxPorts)
    private val names = arrayOfNulls<String>(maxPorts)
    private val pads = HashMap<Int, PadState>()

    fun portOf(device: Int): Int? = deviceAt.indexOf(device).takeIf { it >= 0 }

    /** Device names per port, empty for a free port. */
    fun names(): List<String> = names.map { it ?: "" }

    fun onKey(device: Int, name: String, keyCode: Int, down: Boolean): Update {
        if (PadMapper.buttonFor(keyCode) == null) return Update(handled = false)
        val pad = pads.getOrPut(device) { PadState() }
        pad.onKey(keyCode, down)
        return settle(device, name, pad, wantsPort = down)
    }

    fun onAxes(
        device: Int,
        name: String,
        hatX: Float,
        hatY: Float,
        stickX: Float,
        stickY: Float,
        leftTrigger: Float,
        rightTrigger: Float,
        stickAsDpad: Boolean = true,
    ): Update {
        val pad = pads.getOrPut(device) { PadState() }
        val before = pad.mask
        pad.onAxes(hatX, hatY, stickX, stickY, leftTrigger, rightTrigger, stickAsDpad)
        val port = portOf(device)
        if (port != null && pad.mask == before) return Update(handled = true)
        return settle(device, name, pad, wantsPort = pad.mask != 0)
    }

    /** Frees the device's port, if it had one, and returns that port. */
    fun disconnect(device: Int): Int? {
        pads.remove(device)
        val port = portOf(device) ?: return null
        deviceAt[port] = null
        names[port] = null
        return port
    }

    /** Releases every button and frees every port (session end). */
    fun reset() {
        pads.clear()
        deviceAt.fill(null)
        names.fill(null)
    }

    /** Releases every button but keeps the port assignments (pause). */
    fun releaseAll() {
        pads.values.forEach { it.reset() }
    }

    private fun settle(device: Int, name: String, pad: PadState, wantsPort: Boolean): Update {
        var port = portOf(device)
        var assigned = false
        if (port == null) {
            if (!wantsPort) return Update(handled = true)
            port = deviceAt.indexOf(null).takeIf { it >= 0 } ?: return Update(handled = true)
            deviceAt[port] = device
            names[port] = name
            assigned = true
        }
        val chord = RetroPad.bit(RetroPad.START) or RetroPad.bit(RetroPad.SELECT)
        if (pad.mask and chord == chord) {
            pad.reset()
            return Update(handled = true, port = port, mask = 0, menu = true, assigned = assigned)
        }
        return Update(handled = true, port = port, mask = pad.mask, assigned = assigned)
    }
}
