// SPDX-License-Identifier: GPL-3.0-or-later
// Device tilt for the cover foil sheen. Spec: docs/specs/foil-covers.md
package app.dena.dena_android

import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.os.SystemClock
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel

/**
 * Streams the phone's tilt as `[x, y]` doubles in -1..1 at about 30 Hz,
 * low-pass filtered. Uses the game rotation vector, falling back to the
 * accelerometer. Emits an error (code "no_sensor") when neither exists so the
 * Dart side switches to its time-based sweep. Sensors are only registered
 * while Dart listens.
 */
class TiltSensor(context: Context, messenger: BinaryMessenger) :
    EventChannel.StreamHandler, SensorEventListener {

    private val manager = context.getSystemService(SensorManager::class.java)
    private val channel = EventChannel(messenger, CHANNEL).also { it.setStreamHandler(this) }
    private var sink: EventChannel.EventSink? = null
    private var rotation = false
    private var x = 0f
    private var y = 0f
    private var lastEmit = 0L
    private val matrix = FloatArray(9)
    private val angles = FloatArray(3)

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        val sensor = manager?.getDefaultSensor(Sensor.TYPE_GAME_ROTATION_VECTOR)
            ?.also { rotation = true }
            ?: manager?.getDefaultSensor(Sensor.TYPE_ACCELEROMETER)?.also { rotation = false }
        if (sensor == null) {
            events.error("no_sensor", "No rotation or acceleration sensor", null)
            return
        }
        sink = events
        manager!!.registerListener(this, sensor, SensorManager.SENSOR_DELAY_UI)
    }

    override fun onCancel(arguments: Any?) {
        manager?.unregisterListener(this)
        sink = null
    }

    override fun onSensorChanged(event: SensorEvent) {
        val nx: Float
        val ny: Float
        if (rotation) {
            SensorManager.getRotationMatrixFromVector(matrix, event.values)
            SensorManager.getOrientation(matrix, angles)
            // Roll (left/right) and pitch (towards/away) around a 45° hold;
            // ±25° maps to ±1 so a small wrist turn sweeps the reflection.
            nx = (angles[2] / RANGE).coerceIn(-1f, 1f)
            ny = ((angles[1] + QUARTER_PI) / RANGE).coerceIn(-1f, 1f)
        } else {
            val g = SensorManager.GRAVITY_EARTH
            nx = (-event.values[0] / g * ACCEL_GAIN).coerceIn(-1f, 1f)
            ny = ((event.values[1] / g - REST_Y) * ACCEL_GAIN).coerceIn(-1f, 1f)
        }
        x += (nx - x) * SMOOTHING
        y += (ny - y) * SMOOTHING
        val now = SystemClock.uptimeMillis()
        if (now - lastEmit < EMIT_MS) return
        lastEmit = now
        sink?.success(listOf(x.toDouble(), y.toDouble()))
    }

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {}

    fun dispose() {
        onCancel(null)
        channel.setStreamHandler(null)
    }

    private companion object {
        const val CHANNEL = "app.dena/tilt"
        const val QUARTER_PI = (Math.PI / 4).toFloat()
        const val RANGE = (Math.PI * 25 / 180).toFloat()
        // sin(25°) of gravity is a full ±1; REST_Y is gravity's share at a 45° hold.
        const val ACCEL_GAIN = 2.37f
        const val REST_Y = 0.707f
        const val SMOOTHING = 0.25f
        const val EMIT_MS = 33L
    }
}
