// SPDX-License-Identifier: GPL-3.0-or-later
// Spec: docs/specs/latency-spike.md
package app.dena.dena_android

import android.view.Surface

/** JNI bindings to the native emulator runner (runner.cpp). One core per process. */
object NativeRunner {
    init {
        System.loadLibrary("dena_android")
    }

    /**
     * Loads [corePath] (a library name or path) with [romPath], the battery save at
     * [srmPath] and the auto-save state at [statePath] (empty strings skip them).
     * Returns -1 on error (see [nativeLastError]), 0 fresh, 1 resumed, 2 state rejected.
     */
    external fun nativeStart(
        corePath: String,
        romPath: String,
        systemDir: String,
        srmPath: String,
        statePath: String,
    ): Int
    /**
     * Internal resolution for the next start (shaders.md, Upscale): 0 default, 2-4.
     * [filterPath] is the upscale filter preset for cores with no resolution option ("" for none).
     */
    external fun nativeSetUpscale(factor: Int, filterPath: String)
    /** Stops frames and audio and writes the battery save and auto-save state. */
    external fun nativePause()
    external fun nativeResume()
    /** Core frames per display frame (1..8); audio is muted above 1. */
    external fun nativeSetSpeed(speed: Int)
    /** Audio buffer target in ms (20-80), applied the next time audio opens. */
    external fun nativeSetAudioLatency(ms: Int)
    external fun nativeSaveNow()
    external fun nativeConfigureRewind(enabled: Boolean, l2Hold: Boolean)
    external fun nativeSetRewinding(on: Boolean)
    /** Writes a save state and its PNG thumbnail; 0 ok, -1 error. */
    external fun nativeSaveState(statePath: String, pngPath: String): Int
    /** Writes the current frame as a PNG; 0 ok, -1 error. */
    external fun nativeScreenshot(path: String): Int
    /** Replaces the active cheats (each entry: codes joined by '+'). */
    external fun nativeSetCheats(codes: Array<String>)
    /** 0 ok, -1 rejected, 1 no such file. */
    external fun nativeLoadState(statePath: String): Int
    external fun nativeLastError(): String
    /**
     * Draws through the shader preset at [path] ("" for Off), also before start.
     * 0 ok, -1 error (see [nativeLastError]), 1 needs a fresh surface ([Surfaces.refresh]).
     */
    external fun nativeSetShader(path: String): Int
    /** Routes frames to [surface]; null pauses the emulator. */
    external fun nativeSetSurface(surface: Surface?)
    /** Sets the RetroPad mask of [port]; [eventTimeMs] is the input event's uptime. */
    external fun nativeSetButtons(port: Int, mask: Int, eventTimeMs: Long)
    external fun nativeSetAnalog(port: Int, lx: Int, ly: Int, rx: Int, ry: Int)
    external fun nativeMetrics(): String
    external fun nativePixel(x: Int, y: Int): Int
    /** Saves, then unloads the core. */
    external fun nativeStop()
}
