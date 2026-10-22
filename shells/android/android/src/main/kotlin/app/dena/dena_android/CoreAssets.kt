// SPDX-License-Identifier: GPL-3.0-or-later
// Copies a core's support files (and the bundled shaders) from the APK into
// app storage. Spec: docs/specs/psp.md (Core), docs/specs/shaders.md
package app.dena.dena_android

import android.content.res.AssetManager
import java.io.File

object CoreAssets {
    /** Asset folder per core library; the core reads it from <system>/<folder>. */
    private val folders = mapOf("libppsspp_libretro.so" to "PPSSPP")

    /** The stamp file inside each folder; its text names the asset version. */
    const val STAMP = "dena-assets.txt"

    /** Installs [coreLibrary]'s assets into [systemDir] unless the same version is there. */
    fun install(assets: AssetManager, coreLibrary: String, systemDir: File) {
        val folder = folders[coreLibrary] ?: return
        installFolder(assets, folder, systemDir)
    }

    /**
     * Copies asset [folder] to [parent]/[folder] unless the same version is there.
     * Returns the folder, or null when this build doesn't package it.
     */
    fun installFolder(assets: AssetManager, folder: String, parent: File): File? {
        val version = try {
            assets.open("$folder/$STAMP").bufferedReader().use { it.readText() }
        } catch (e: java.io.IOException) {
            return null // not packaged in this build
        }
        val dest = File(parent, folder)
        val stamp = File(dest, STAMP)
        if (stamp.exists() && stamp.readText() == version) return dest
        dest.deleteRecursively() // drop shaders or files a newer version removed
        copyTree(assets, folder, dest)
        stamp.writeText(version)
        return dest
    }

    private fun copyTree(assets: AssetManager, path: String, dest: File) {
        val children = assets.list(path).orEmpty()
        if (children.isEmpty()) {
            dest.parentFile?.mkdirs()
            assets.open(path).use { input -> dest.outputStream().use { input.copyTo(it) } }
            return
        }
        dest.mkdirs()
        for (child in children) {
            if (child == STAMP) continue
            copyTree(assets, "$path/$child", File(dest, child))
        }
    }
}
