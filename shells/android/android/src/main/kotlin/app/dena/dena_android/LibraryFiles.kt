// SPDX-License-Identifier: GPL-3.0-or-later
// Spec: docs/specs/library.md (Import)
package app.dena.dena_android

import android.Manifest
import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.ContentResolver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.pdf.PdfRenderer
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.ParcelFileDescriptor
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import android.provider.Settings
import io.flutter.plugin.common.PluginRegistry
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import java.io.File
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/**
 * Storage Access Framework picking for the library. Picked documents are copied
 * into `cacheDir/import/` so Dart can read them as plain files; Dart then moves
 * the ROMs it accepts into app-private storage.
 */
class LibraryFiles(private val context: Context) :
    LibraryHostApi,
    PluginRegistry.ActivityResultListener,
    PluginRegistry.RequestPermissionsResultListener {
    var activity: Activity? = null
    private var pending: ((Intent?) -> Unit)? = null
    private var pendingPermission: CompletableDeferred<Unit>? = null
    private val shared = mutableListOf<String>()
    val shortcuts = GameShortcuts(context)
    private val importDir get() = File(context.cacheDir, "import")

    override suspend fun pickFiles(): List<String> {
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT)
            .addCategory(Intent.CATEGORY_OPENABLE)
            .setType("*/*")
            .putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
        val data = launch(intent) ?: return emptyList()
        val uris = buildList {
            data.data?.let { add(it) }
            val clip = data.clipData
            if (clip != null) for (i in 0 until clip.itemCount) add(clip.getItemAt(i).uri)
        }.distinct()
        return withContext(Dispatchers.IO) {
            // One folder per pick, so a .cue finds the .bin tracks picked with it.
            val batch = newCacheDir()
            uris.mapNotNull { copyToCache(it, null, batch) }
        }
    }

    override suspend fun pickFolder(extensions: List<String>): List<String> {
        val tree = launch(Intent(Intent.ACTION_OPEN_DOCUMENT_TREE))?.data ?: return emptyList()
        val wanted = extensions.map { it.lowercase() }
        return withContext(Dispatchers.IO) {
            val out = mutableListOf<String>()
            walk(tree, DocumentsContract.getTreeDocumentId(tree), wanted, out, depth = 0, dir = newCacheDir())
            out
        }
    }

    // file-explorer.md: some phones' system picker shows game folders as
    // empty (Android 16 / HyperOS 3), so Add games browses storage itself.
    override fun hasStorageAccess(): Boolean =
        if (Build.VERSION.SDK_INT >= 30) {
            Environment.isExternalStorageManager()
        } else {
            context.checkSelfPermission(Manifest.permission.READ_EXTERNAL_STORAGE) ==
                PackageManager.PERMISSION_GRANTED
        }

    override suspend fun requestStorageAccess(): Boolean {
        if (hasStorageAccess()) return true
        if (Build.VERSION.SDK_INT >= 30) {
            val app = Intent(
                Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION,
                Uri.parse("package:${context.packageName}"),
            )
            try {
                launch(app)
            } catch (e: ActivityNotFoundException) {
                try {
                    launch(Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION))
                } catch (none: ActivityNotFoundException) {
                    return false
                }
            }
        } else {
            val a = activity ?: return false
            val done = CompletableDeferred<Unit>()
            pendingPermission?.complete(Unit)
            pendingPermission = done
            a.requestPermissions(arrayOf(Manifest.permission.READ_EXTERNAL_STORAGE), PERMISSION_CODE)
            done.await()
        }
        return hasStorageAccess()
    }

    override fun onRequestPermissionsResult(
        requestCode: Int, permissions: Array<out String>, grantResults: IntArray,
    ): Boolean {
        if (requestCode != PERMISSION_CODE) return false
        pendingPermission?.complete(Unit)
        pendingPermission = null
        return true
    }

    override fun takeSharedFiles(): List<String> {
        val result = shared.toList()
        shared.clear()
        return result
    }

    override fun takeLaunchLink(): String? = shortcuts.takeLaunchLink()

    override fun pinShortcut(sha1: String, title: String, iconPath: String?): Boolean =
        shortcuts.pin(sha1, title, iconPath)

    override fun reportPlayed(sha1: String, title: String, iconPath: String?) =
        shortcuts.reportPlayed(sha1, title, iconPath)

    override fun removeShortcut(sha1: String) = shortcuts.remove(sha1)

    override fun clearImportCache() {
        importDir.deleteRecursively()
    }

    /** Called by the plugin for ACTION_SEND / ACTION_SEND_MULTIPLE intents. */
    fun onShareIntent(intent: Intent) {
        // The typed getters are API 33+; minSdk is 26.
        @Suppress("DEPRECATION")
        val uris: List<Uri> = when (intent.action) {
            Intent.ACTION_SEND -> listOfNotNull(intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM))
            Intent.ACTION_SEND_MULTIPLE ->
                intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM).orEmpty()
            else -> emptyList()
        }
        val batch = newCacheDir()
        uris.mapNotNullTo(shared) { copyToCache(it, null, batch) }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_CODE) return false
        val done = pending ?: return true
        pending = null
        done(if (resultCode == Activity.RESULT_OK) data else null)
        return true
    }

    private suspend fun launch(intent: Intent): Intent? = suspendCancellableCoroutine { cont ->
        val a = activity
        if (a == null || pending != null) {
            cont.resume(null)
            return@suspendCancellableCoroutine
        }
        pending = { cont.resume(it) }
        try {
            a.startActivityForResult(intent, REQUEST_CODE)
        } catch (e: ActivityNotFoundException) {
            // No system picker on this device: the app falls back to its own
            // file explorer (docs/specs/file-explorer.md).
            pending = null
            cont.resumeWithException(e)
        }
    }

    // Each source folder gets one cache folder, so a .cue keeps its tracks beside it.
    private fun walk(
        tree: Uri, docId: String, wanted: List<String>, out: MutableList<String>, depth: Int, dir: File,
    ) {
        if (depth > MAX_DEPTH) return
        val children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, docId)
        val cols = arrayOf(
            DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            DocumentsContract.Document.COLUMN_MIME_TYPE,
        )
        context.contentResolver.query(children, cols, null, null, null)?.use { c ->
            while (c.moveToNext()) {
                val id = c.getString(0)
                val name = c.getString(1) ?: continue
                if (c.getString(2) == DocumentsContract.Document.MIME_TYPE_DIR) {
                    walk(tree, id, wanted, out, depth + 1, newCacheDir())
                } else if (wanted.any { name.lowercase().endsWith(it) }) {
                    copyToCache(DocumentsContract.buildDocumentUriUsingTree(tree, id), name, dir)?.let(out::add)
                }
            }
        }
    }

    private fun newCacheDir(): File = File(importDir, System.nanoTime().toString())

    /**
     * Copies one document into [dir] of the import cache (a fresh folder when
     * the name is taken there); null if it can't be read.
     */
    private fun copyToCache(uri: Uri, knownName: String?, dir: File): String? = try {
        val name = (knownName ?: displayName(context.contentResolver, uri) ?: "file").replace('/', '_')
        val into = if (File(dir, name).exists()) newCacheDir() else dir
        into.mkdirs()
        val dest = File(into, name)
        context.contentResolver.openInputStream(uri)?.use { input ->
            dest.outputStream().use { input.copyTo(it) }
        } ?: return null
        dest.absolutePath
    } catch (e: Exception) {
        null
    }

    private fun displayName(resolver: ContentResolver, uri: Uri): String? =
        resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c ->
            if (c.moveToFirst()) c.getString(0) else null
        }

    companion object {
        private const val REQUEST_CODE = 0xDE7A
        private const val PERMISSION_CODE = 0xDE7C
        private const val MAX_DEPTH = 8
    }

    override suspend fun rasterizePdf(pdfPath: String, width: Long, height: Long, outPng: String): String? =
        withContext(Dispatchers.IO) {
            runCatching {
                ParcelFileDescriptor.open(File(pdfPath), ParcelFileDescriptor.MODE_READ_ONLY).use { fd ->
                    PdfRenderer(fd).use { pdf ->
                        pdf.openPage(0).use { page ->
                            val bmp = Bitmap.createBitmap(width.toInt(), height.toInt(), Bitmap.Config.ARGB_8888)
                            bmp.eraseColor(Color.TRANSPARENT)
                            page.render(bmp, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                            val out = File(outPng)
                            out.parentFile?.mkdirs()
                            out.outputStream().use { bmp.compress(Bitmap.CompressFormat.PNG, 100, it) }
                            bmp.recycle()
                            outPng
                        }
                    }
                }
            }.getOrNull()
        }
}
