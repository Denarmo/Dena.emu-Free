// SPDX-License-Identifier: GPL-3.0-or-later
// Specs: docs/specs/latency-spike.md, docs/specs/game-session.md
package app.dena.dena_android

import android.app.Activity
import android.content.ContentValues
import android.content.Context
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.hardware.input.InputManager
import android.os.SystemClock
import android.view.KeyEvent
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.View
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.PluginRegistry
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import io.flutter.view.TextureRegistry
import java.io.File
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** Platform view type for the SurfaceView composition path. */
const val SURFACE_VIEW_TYPE = "dena/surface-view"

/**
 * Android shell plugin: lifecycle API (Pigeon), both composition paths, and a
 * once-per-second metrics log under the tag "Dena".
 */
class DenaAndroidPlugin : FlutterPlugin, ActivityAware, SpikeHostApi, GameHostApi {
    private var activity: Activity? = null
    private var activityBinding: ActivityPluginBinding? = null
    private lateinit var libraryFiles: LibraryFiles
    private lateinit var media: MediaPlayers
    private val onNewIntent = PluginRegistry.NewIntentListener { intent ->
        libraryFiles.onShareIntent(intent)
        libraryFiles.shortcuts.onIntent(intent)
        false
    }
    private lateinit var context: Context
    private lateinit var textures: TextureRegistry
    private var producer: TextureRegistry.SurfaceProducer? = null
    private var running = false
    private var events: GameEventsApi? = null
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private lateinit var external: ExternalDisplay

    /** Forwards session input events to Dart (gamepads.md). */
    private val inputListener = object : DenaInput.Listener {
        override fun onMenuRequested() {
            scope.launch { runCatching { events?.onMenuRequested() } }
        }

        override fun onPlayersChanged(names: List<String>) {
            scope.launch { runCatching { events?.onPlayersChanged(names) } }
        }

        override fun onGamepadUsed() {
            scope.launch { runCatching { events?.onGamepadUsed() } }
        }

        override fun onControllerDisconnected(port: Int, name: String) {
            scope.launch { runCatching { events?.onControllerDisconnected(port.toLong(), name) } }
        }
    }

    private val deviceListener = object : InputManager.InputDeviceListener {
        override fun onInputDeviceAdded(deviceId: Int) {}
        override fun onInputDeviceChanged(deviceId: Int) {}
        override fun onInputDeviceRemoved(deviceId: Int) = DenaInput.onDeviceRemoved(deviceId)
    }
    private var tilt: TiltSensor? = null
    private val main = Handler(Looper.getMainLooper())
    private val logMetrics = object : Runnable {
        override fun run() {
            if (!running) return
            Log.i(TAG, "metrics ${NativeRunner.nativeMetrics()}")
            main.postDelayed(this, 1000)
        }
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        textures = binding.textureRegistry
        SpikeHostApi.setUp(binding.binaryMessenger, this)
        GameHostApi.setUp(binding.binaryMessenger, this)
        events = GameEventsApi(binding.binaryMessenger)
        DenaInput.listener = inputListener
        context.getSystemService(InputManager::class.java)
            ?.registerInputDeviceListener(deviceListener, main)
        libraryFiles = LibraryFiles(context)
        external = ExternalDisplay(context, main) { name ->
            scope.launch { runCatching { events?.onExternalDisplayChanged(name) } }
        }
        LibraryHostApi.setUp(binding.binaryMessenger, libraryFiles)
        media = MediaPlayers(context, textures)
        MediaHostApi.setUp(binding.binaryMessenger, media)
        binding.platformViewRegistry.registerViewFactory(SURFACE_VIEW_TYPE, SurfaceViewFactory())
        tilt = TiltSensor(context, binding.binaryMessenger)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        stop()
        SpikeHostApi.setUp(binding.binaryMessenger, null)
        GameHostApi.setUp(binding.binaryMessenger, null)
        context.getSystemService(InputManager::class.java)
            ?.unregisterInputDeviceListener(deviceListener)
        DenaInput.listener = null
        events = null
        scope.cancel()
        LibraryHostApi.setUp(binding.binaryMessenger, null)
        MediaHostApi.setUp(binding.binaryMessenger, null)
        media.dispose()
        tilt?.dispose()
        tilt = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        activityBinding = binding
        libraryFiles.activity = binding.activity
        external.activity = binding.activity
        binding.addActivityResultListener(libraryFiles)
        binding.addRequestPermissionsResultListener(libraryFiles)
        binding.addOnNewIntentListener(onNewIntent)
        media.activity = binding.activity
        binding.addRequestPermissionsResultListener(media)
        libraryFiles.onShareIntent(binding.activity.intent)
        libraryFiles.shortcuts.onIntent(binding.activity.intent)
    }

    override fun onDetachedFromActivityForConfigChanges() = onDetachedFromActivity()

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
        activityBinding = binding
        libraryFiles.activity = binding.activity
        external.activity = binding.activity
        binding.addActivityResultListener(libraryFiles)
        binding.addRequestPermissionsResultListener(libraryFiles)
        binding.addOnNewIntentListener(onNewIntent)
        media.activity = binding.activity
        binding.addRequestPermissionsResultListener(media)
    }

    override fun onDetachedFromActivity() {
        activityBinding?.removeActivityResultListener(libraryFiles)
        activityBinding?.removeRequestPermissionsResultListener(libraryFiles)
        activityBinding?.removeOnNewIntentListener(onNewIntent)
        activityBinding?.removeRequestPermissionsResultListener(media)
        media.activity = null
        activityBinding = null
        activity = null
        libraryFiles.activity = null
        external.activity = null
    }

    override fun debugDispatchKey(keyCode: Long, down: Boolean) {
        val now = SystemClock.uptimeMillis()
        val action = if (down) KeyEvent.ACTION_DOWN else KeyEvent.ACTION_UP
        activity?.dispatchKeyEvent(KeyEvent(now, now, action, keyCode.toInt(), 0))
    }

    override fun start(romPath: String?): String? {
        if (running) return "already running"
        val rom = romPath ?: bundledRom()
        val rc = NativeRunner.nativeStart(CORE_LIBRARY, rom, context.filesDir.absolutePath, "", "")
        if (rc < 0) return NativeRunner.nativeLastError()
        onStarted()
        return null
    }

    override fun start(coreLibrary: String, romPath: String, srmPath: String, statePath: String): StartResult {
        // A session that was never stopped (its screen closed mid-start) would
        // otherwise keep emulating and refuse every later launch.
        if (running) stop()
        File(srmPath).parentFile?.mkdirs()
        File(statePath).parentFile?.mkdirs()
        // First start of a core that needs support files (psp.md): copy them once.
        CoreAssets.install(context.assets, coreLibrary, context.filesDir)
        val rc = NativeRunner.nativeStart(
            coreLibrary, romPath, context.filesDir.absolutePath, srmPath, statePath)
        if (rc < 0) return StartResult(error = NativeRunner.nativeLastError())
        onStarted()
        return StartResult(outcome = StartOutcome.ofRaw(rc))
    }

    private fun onStarted() {
        running = true
        DenaInput.active = true
        main.post(logMetrics)
        external.start()
    }

    /** Also hands gamepad keys back to Flutter so the pause sheet is D-pad operable. */
    override fun pause() {
        if (!running) return
        DenaInput.active = false
        NativeRunner.nativePause()
    }

    override fun resume() {
        if (!running) return
        NativeRunner.nativeResume()
        DenaInput.active = true
    }

    override fun setSpeed(speed: Long) = NativeRunner.nativeSetSpeed(speed.toInt())

    override fun setAudioLatency(ms: Long) = NativeRunner.nativeSetAudioLatency(ms.toInt())

    override fun configureRewind(enabled: Boolean, l2Hold: Boolean) {
        if (running) NativeRunner.nativeConfigureRewind(enabled, l2Hold)
    }

    override fun setUpscale(factor: Long) {
        val f = factor.toInt().coerceIn(0, 4)
        // shaders.md, Upscale: GB, GBC and DS are upscaled by this filter.
        val filter = if (f < 2) "" else {
            CoreAssets.installFolder(context.assets, "shaders", context.filesDir)
                ?.let { File(it, UPSCALE_FILTER) }?.takeIf { it.isFile }?.absolutePath ?: ""
        }
        NativeRunner.nativeSetUpscale(f, filter)
    }

    // desktop-resolution.md: widescreen is offered on the desktop only.
    override fun setWidescreen(on: Boolean) {}

    override fun setShader(id: String): String? {
        val path = if (id.isEmpty()) "" else {
            // Ids are folder names (shaders.md); never a path.
            if (!SHADER_ID.matches(id)) return "Unknown shader"
            val dir = CoreAssets.installFolder(context.assets, "shaders", context.filesDir)
                ?: return "Shaders are not included in this build"
            File(dir, "$id/$id.glslp").takeIf { it.isFile }?.absolutePath ?: return "Unknown shader"
        }
        return when (NativeRunner.nativeSetShader(path)) {
            0 -> null
            1 -> {
                Surfaces.refresh() // the runner switches to GLES on the new surface
                null
            }
            else -> NativeRunner.nativeLastError()
        }
    }

    override fun setDisplayAspect(aspect: Double) {
        external.aspect = aspect
    }

    override fun setAnalogMode(on: Boolean) {
        DenaInput.analogMode = on
    }

    override fun setRewinding(on: Boolean) {
        if (running) NativeRunner.nativeSetRewinding(on)
    }

    override fun saveNow() {
        if (running) NativeRunner.nativeSaveNow()
    }

    override fun saveState(statePath: String, pngPath: String): String? {
        if (!running) return "no game running"
        File(statePath).parentFile?.mkdirs()
        return if (NativeRunner.nativeSaveState(statePath, pngPath) == 0) null
        else "The state could not be saved"
    }

    override suspend fun captureScreenshot(name: String): String? {
        if (!running) return "no game running"
        val tmp = File(context.cacheDir, "screenshot.png")
        if (NativeRunner.nativeScreenshot(tmp.absolutePath) != 0) {
            return "The screenshot could not be taken"
        }
        val error = withContext(Dispatchers.IO) {
            runCatching { publishPicture(tmp, "$name.png") }.exceptionOrNull()
        }
        tmp.delete()
        return error?.let { "The screenshot could not be saved" }
    }

    /** Copies [png] into Pictures/Dena.emu (MediaStore on Android 10+). */
    private fun publishPicture(png: File, displayName: String) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val values = ContentValues().apply {
                put(MediaStore.Images.Media.DISPLAY_NAME, displayName)
                put(MediaStore.Images.Media.MIME_TYPE, "image/png")
                put(MediaStore.Images.Media.RELATIVE_PATH, "${Environment.DIRECTORY_PICTURES}/Dena.emu")
                put(MediaStore.Images.Media.IS_PENDING, 1)
            }
            val resolver = context.contentResolver
            val uri = resolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values)
                ?: error("MediaStore insert failed")
            resolver.openOutputStream(uri)?.use { out -> png.inputStream().use { it.copyTo(out) } }
                ?: error("MediaStore open failed")
            values.clear()
            values.put(MediaStore.Images.Media.IS_PENDING, 0)
            resolver.update(uri, values, null, null)
        } else {
            @Suppress("DEPRECATION")
            val dir = File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_PICTURES), "Dena.emu")
            dir.mkdirs()
            png.copyTo(File(dir, displayName), overwrite = true)
        }
    }

    override fun setTouchMode(on: Boolean) {
        DenaInput.touchMode = on
    }

    override fun setCheats(codes: List<String>) {
        if (running) NativeRunner.nativeSetCheats(codes.toTypedArray())
    }

    override fun loadState(statePath: String): String? {
        if (!running) return "no game running"
        return when (NativeRunner.nativeLoadState(statePath)) {
            0 -> null
            1 -> "That slot is empty"
            else -> "This state doesn't work with this game or core version"
        }
    }

    override fun stop() {
        if (!running) return
        running = false
        external.stop()
        DenaInput.endSession()
        main.removeCallbacks(logMetrics)
        NativeRunner.nativeStop()
        detachTexture()
    }

    override fun attachTexture(width: Long, height: Long): Long {
        detachTexture()
        val p = textures.createSurfaceProducer()
        p.setSize(width.toInt(), height.toInt())
        p.setCallback(object : TextureRegistry.SurfaceProducer.Callback {
            override fun onSurfaceAvailable() {
                Surfaces.router.setPhone(p.surface)
            }

            override fun onSurfaceCleanup() {
                Surfaces.router.setPhone(null)
            }
        })
        Surfaces.router.setPhone(p.surface)
        producer = p
        return p.id()
    }

    override fun detachTexture() {
        val p = producer ?: return
        producer = null
        Surfaces.router.setPhone(null)
        p.release()
    }

    override fun metrics(): String = NativeRunner.nativeMetrics()

    override fun pixel(x: Long, y: Long): Long = NativeRunner.nativePixel(x.toInt(), y.toInt()).toLong()

    private fun bundledRom(): String {
        val out = File(context.filesDir, "latency.gba")
        context.assets.open("dena/latency.gba").use { input ->
            out.outputStream().use { input.copyTo(it) }
        }
        return out.absolutePath
    }

    companion object {
        private const val TAG = "Dena"
        private val SHADER_ID = Regex("^[a-z0-9][a-z0-9-]*$")
        // Not a user shader: its folder starts with "_", which ids never do.
        private const val UPSCALE_FILTER = "_upscale/xbrz-freescale.glslp"
        /** Resolved by the dynamic linker from the app's native library directory. */
        const val CORE_LIBRARY = "libmgba_libretro.so"
    }
}

/** SurfaceView path: the view's surface goes straight to the native runner. */
private class SurfaceViewFactory : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
    override fun create(context: Context, viewId: Int, args: Any?): PlatformView =
        EmulatorSurfaceView(context)
}

private class EmulatorSurfaceView(context: Context) : PlatformView, SurfaceHolder.Callback {
    private val view = SurfaceView(context).apply {
        holder.addCallback(this@EmulatorSurfaceView)
        Surfaces.views.add(this)
    }

    override fun getView(): View = view

    override fun dispose() {
        view.holder.removeCallback(this)
        Surfaces.views.remove(view)
        Surfaces.router.setPhone(null)
    }

    override fun surfaceCreated(holder: SurfaceHolder) {
        Surfaces.router.setPhone(holder.surface)
    }

    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {}

    override fun surfaceDestroyed(holder: SurfaceHolder) {
        Surfaces.router.setPhone(null)
    }
}
