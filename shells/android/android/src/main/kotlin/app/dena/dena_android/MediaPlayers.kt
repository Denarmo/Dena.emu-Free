// SPDX-License-Identifier: GPL-3.0-or-later
// Spec: docs/specs/media-players.md
package app.dena.dena_android

import android.Manifest
import android.app.Activity
import android.content.ComponentName
import android.content.ContentUris
import android.content.Context
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import android.util.Size
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.Player
import androidx.media3.common.VideoSize
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.session.MediaController
import androidx.media3.session.SessionToken
import com.google.common.util.concurrent.MoreExecutors
import io.flutter.plugin.common.PluginRegistry
import io.flutter.view.TextureRegistry
import java.io.ByteArrayOutputStream
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/** MediaStore browsing, the music controller and the video player. */
class MediaPlayers(
    private val context: Context,
    private val textures: TextureRegistry,
) : MediaHostApi, PluginRegistry.RequestPermissionsResultListener {
    var activity: Activity? = null
    private var pendingAccess: CompletableDeferred<Boolean>? = null
    private var controller: MediaController? = null
    private var pendingCommands = mutableListOf<(MediaController) -> Unit>()
    private var connecting = false
    private var video: ExoPlayer? = null
    private var videoTexture: TextureRegistry.SurfaceProducer? = null

    // ---- Permissions ----

    private fun permissions(video: Boolean): Array<String> =
        if (Build.VERSION.SDK_INT >= 33) {
            if (video) arrayOf(Manifest.permission.READ_MEDIA_VIDEO)
            // Notification controls for background music.
            else arrayOf(Manifest.permission.READ_MEDIA_AUDIO, Manifest.permission.POST_NOTIFICATIONS)
        } else {
            arrayOf(Manifest.permission.READ_EXTERNAL_STORAGE)
        }

    private fun granted(p: String) =
        context.checkSelfPermission(p) == PackageManager.PERMISSION_GRANTED

    override suspend fun requestAccess(video: Boolean): Boolean {
        val wanted = permissions(video)
        val read = wanted.first()
        if (granted(read)) return true
        val act = activity ?: return false
        val result = CompletableDeferred<Boolean>()
        pendingAccess?.complete(false)
        pendingAccess = result
        act.requestPermissions(wanted, REQUEST_CODE)
        result.await()
        return granted(read)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int, permissions: Array<out String>, grantResults: IntArray,
    ): Boolean {
        if (requestCode != REQUEST_CODE) return false
        pendingAccess?.complete(true)
        pendingAccess = null
        return true
    }

    // ---- MediaStore ----

    override suspend fun list(video: Boolean): List<MediaEntry> = withContext(Dispatchers.IO) {
        val collection = if (video) MediaStore.Video.Media.EXTERNAL_CONTENT_URI
        else MediaStore.Audio.Media.EXTERNAL_CONTENT_URI
        val projection = mutableListOf(
            MediaStore.MediaColumns._ID,
            MediaStore.MediaColumns.TITLE,
            MediaStore.MediaColumns.DISPLAY_NAME,
            MediaStore.Audio.AudioColumns.DURATION,
        )
        if (video) {
            projection += MediaStore.Video.VideoColumns.BUCKET_DISPLAY_NAME
        } else {
            projection += MediaStore.Audio.AudioColumns.ARTIST
            projection += MediaStore.Audio.AudioColumns.ALBUM
        }
        val selection = if (video) null else "${MediaStore.Audio.AudioColumns.IS_MUSIC} != 0"
        val out = mutableListOf<MediaEntry>()
        runCatching {
            context.contentResolver.query(
                collection, projection.toTypedArray(), selection, null,
                "${MediaStore.MediaColumns.TITLE} COLLATE NOCASE ASC",
            )?.use { c ->
                fun str(col: String): String? =
                    c.getColumnIndex(col).takeIf { it >= 0 }?.let { c.getString(it) }
                fun known(s: String?): String =
                    s?.takeIf { it.isNotBlank() && it != "<unknown>" } ?: ""
                val idCol = c.getColumnIndexOrThrow(MediaStore.MediaColumns._ID)
                val durCol = c.getColumnIndex(MediaStore.Audio.AudioColumns.DURATION)
                while (c.moveToNext()) {
                    val uri = ContentUris.withAppendedId(collection, c.getLong(idCol))
                    val title = str(MediaStore.MediaColumns.TITLE)?.takeIf { it.isNotBlank() }
                        ?: str(MediaStore.MediaColumns.DISPLAY_NAME) ?: "Untitled"
                    out += MediaEntry(
                        uri = uri.toString(),
                        title = title,
                        artist = known(str(MediaStore.Audio.AudioColumns.ARTIST)),
                        album = known(str(MediaStore.Audio.AudioColumns.ALBUM)),
                        folder = known(str(MediaStore.Video.VideoColumns.BUCKET_DISPLAY_NAME)),
                        durationMs = if (durCol >= 0) c.getLong(durCol) else 0L,
                    )
                }
            }
        }
        out
    }

    override suspend fun thumbnail(uri: String, size: Long): ByteArray? = withContext(Dispatchers.IO) {
        if (Build.VERSION.SDK_INT < 29) return@withContext null
        runCatching {
            val px = size.toInt()
            val bitmap = context.contentResolver.loadThumbnail(Uri.parse(uri), Size(px, px), null)
            ByteArrayOutputStream().use { bytes ->
                bitmap.compress(Bitmap.CompressFormat.JPEG, 85, bytes)
                bitmap.recycle()
                bytes.toByteArray()
            }
        }.getOrNull()
    }

    // ---- Music (MusicService through a MediaController) ----

    /** Runs [command] now, or once the controller has connected. */
    private fun withController(command: (MediaController) -> Unit) {
        controller?.let { command(it); return }
        pendingCommands += command
        if (connecting) return
        connecting = true
        val token = SessionToken(context, ComponentName(context, MusicService::class.java))
        val future = MediaController.Builder(context, token).buildAsync()
        future.addListener({
            connecting = false
            val c = runCatching { future.get() }.getOrNull() ?: return@addListener
            controller = c
            val queued = pendingCommands
            pendingCommands = mutableListOf()
            queued.forEach { it(c) }
        }, MoreExecutors.directExecutor())
    }

    override fun playQueue(queue: List<MediaEntry>, index: Long) {
        val items = queue.map { e ->
            MediaItem.Builder()
                .setMediaId(e.uri)
                .setUri(e.uri)
                .setMediaMetadata(
                    MediaMetadata.Builder()
                        .setTitle(e.title)
                        .setArtist(e.artist.ifEmpty { null })
                        .setAlbumTitle(e.album.ifEmpty { null })
                        .build(),
                )
                .build()
        }
        withController { c ->
            c.setMediaItems(items, index.toInt(), 0L)
            c.prepare()
            c.play()
        }
    }

    override fun musicPlay() = withController { it.play() }
    override fun musicPause() = withController { it.pause() }
    override fun musicNext() = withController { it.seekToNextMediaItem() }

    /** Restarts the track after its first seconds, else the previous one. */
    override fun musicPrevious() = withController { it.seekToPrevious() }
    override fun musicSeek(positionMs: Long) = withController { it.seekTo(positionMs) }
    override fun musicSkipTo(index: Long) = withController { it.seekTo(index.toInt(), 0L) }
    override fun setShuffle(on: Boolean) = withController { it.shuffleModeEnabled = on }
    override fun setRepeat(mode: Long) = withController {
        it.repeatMode = when (mode) {
            1L -> Player.REPEAT_MODE_ONE
            2L -> Player.REPEAT_MODE_ALL
            else -> Player.REPEAT_MODE_OFF
        }
    }

    override fun musicStatus(): MusicStatus {
        val c = controller
        if (c == null || c.mediaItemCount == 0) {
            return MusicStatus(
                playing = false, index = -1, positionMs = 0, durationMs = 0,
                shuffle = c?.shuffleModeEnabled ?: false, repeat = (c?.repeatMode ?: 0).toLong(),
            )
        }
        return MusicStatus(
            playing = c.isPlaying || (c.playWhenReady && c.playbackState == Player.STATE_BUFFERING),
            index = c.currentMediaItemIndex.toLong(),
            positionMs = c.currentPosition.coerceAtLeast(0),
            durationMs = c.duration.takeIf { it > 0 } ?: 0L,
            shuffle = c.shuffleModeEnabled,
            repeat = c.repeatMode.toLong(),
        )
    }

    // ---- Video (ExoPlayer into a Flutter texture) ----

    override fun videoOpen(uri: String, startMs: Long): Long {
        videoClose()
        // One player at a time: the music pauses for a video.
        controller?.pause()
        val producer = textures.createSurfaceProducer()
        val player = ExoPlayer.Builder(context).build()
        producer.setCallback(object : TextureRegistry.SurfaceProducer.Callback {
            override fun onSurfaceAvailable() = player.setVideoSurface(producer.surface)
            override fun onSurfaceCleanup() = player.clearVideoSurface()
        })
        player.setVideoSurface(producer.surface)
        player.addListener(object : Player.Listener {
            override fun onVideoSizeChanged(videoSize: VideoSize) {
                if (videoSize.width > 0 && videoSize.height > 0) {
                    producer.setSize(videoSize.width, videoSize.height)
                }
            }
        })
        player.setMediaItem(MediaItem.fromUri(uri), startMs)
        player.prepare()
        player.play()
        video = player
        videoTexture = producer
        return producer.id()
    }

    override fun videoPlay() {
        val p = video ?: return
        if (p.playbackState == Player.STATE_ENDED) p.seekTo(0)
        p.play()
    }

    override fun videoPause() { video?.pause() }
    override fun videoSeek(positionMs: Long) { video?.seekTo(positionMs) }

    override fun videoStatus(): VideoStatus {
        val p = video ?: return VideoStatus(false, false, 0, 0, 0, 0)
        val size = p.videoSize
        return VideoStatus(
            playing = p.isPlaying,
            ended = p.playbackState == Player.STATE_ENDED,
            positionMs = p.currentPosition.coerceAtLeast(0),
            durationMs = p.duration.takeIf { it > 0 } ?: 0L,
            width = size.width.toLong(),
            height = size.height.toLong(),
        )
    }

    override fun videoClose(): Long {
        val p = video ?: return 0
        val pos = if (p.playbackState == Player.STATE_ENDED) 0L else p.currentPosition
        p.release()
        videoTexture?.release()
        video = null
        videoTexture = null
        return pos
    }

    fun dispose() {
        videoClose()
        controller?.release()
        controller = null
    }

    companion object {
        private const val REQUEST_CODE = 0x4D45
    }
}
