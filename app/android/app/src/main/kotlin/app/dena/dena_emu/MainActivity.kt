// SPDX-License-Identifier: GPL-3.0-or-later
package app.dena.dena_emu

import android.view.KeyEvent
import android.view.MotionEvent
import app.dena.dena_android.DenaInput
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val apps by lazy { DeviceApps(this) }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "app.dena/apps")
            .setMethodCallHandler(apps)
    }

    // Game input is read here, before Flutter, so it never waits on the UI thread's
    // frame (docs/specs/latency-spike.md, Input).
    override fun dispatchKeyEvent(event: KeyEvent): Boolean =
        DenaInput.dispatchKeyEvent(event) || super.dispatchKeyEvent(event)

    override fun dispatchGenericMotionEvent(event: MotionEvent): Boolean =
        DenaInput.dispatchGenericMotionEvent(event) || super.dispatchGenericMotionEvent(event)
}
