// SPDX-License-Identifier: GPL-3.0-or-later
// Apps tab and home-launcher role (docs/specs/apps-tab.md).
package app.dena.dena_emu

import android.app.Activity
import android.app.role.RoleManager
import android.content.ComponentName
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.Drawable
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.util.concurrent.Executors

class DeviceApps(private val activity: Activity) : MethodChannel.MethodCallHandler {
    private val io = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private val pm get() = activity.packageManager

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "list" -> io.execute {
                val apps = try { list() } catch (e: Exception) {
                    main.post { result.error("list", e.message, null) }
                    return@execute
                }
                main.post { result.success(apps) }
            }
            "launch" -> {
                val intent = pm.getLaunchIntentForPackage(call.arguments as String)
                if (intent == null) {
                    result.error("launch", "not launchable", null)
                } else {
                    activity.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                    result.success(null)
                }
            }
            "isHome" -> result.success(isHome())
            "requestHome" -> { requestHome(); result.success(null) }
            else -> result.notImplemented()
        }
    }

    private fun list(): List<Map<String, Any?>> {
        val query = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
        val self = activity.packageName
        return pm.queryIntentActivities(query, 0)
            .filter { it.activityInfo.packageName != self }
            .distinctBy { it.activityInfo.packageName }
            .map {
                mapOf(
                    "package" to it.activityInfo.packageName,
                    "label" to it.loadLabel(pm).toString(),
                    "icon" to png(it.loadIcon(pm)),
                )
            }
    }

    private fun png(d: Drawable): ByteArray? = try {
        val size = 96
        val bmp = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        d.setBounds(0, 0, size, size)
        d.draw(Canvas(bmp))
        ByteArrayOutputStream().also { bmp.compress(Bitmap.CompressFormat.PNG, 100, it) }
            .toByteArray()
    } catch (e: Exception) { null }

    private fun isHome(): Boolean {
        val home = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME)
        val r = pm.resolveActivity(home, PackageManager.MATCH_DEFAULT_ONLY)
        return r?.activityInfo?.packageName == activity.packageName
    }

    private fun requestHome() {
        // The HOME alias ships disabled so installing never hijacks Home.
        pm.setComponentEnabledSetting(
            ComponentName(activity.packageName, "app.dena.dena_emu.HomeAlias"),
            PackageManager.COMPONENT_ENABLED_STATE_ENABLED,
            PackageManager.DONT_KILL_APP,
        )
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val roles = activity.getSystemService(RoleManager::class.java)
            if (roles != null && roles.isRoleAvailable(RoleManager.ROLE_HOME) &&
                !roles.isRoleHeld(RoleManager.ROLE_HOME)
            ) {
                activity.startActivityForResult(
                    roles.createRequestRoleIntent(RoleManager.ROLE_HOME), 4207,
                )
                return
            }
        }
        try {
            activity.startActivity(Intent(Settings.ACTION_HOME_SETTINGS))
        } catch (e: Exception) {
            activity.startActivity(Intent(Settings.ACTION_SETTINGS))
        }
    }
}
