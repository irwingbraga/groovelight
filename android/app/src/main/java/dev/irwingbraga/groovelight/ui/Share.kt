package dev.irwingbraga.groovelight.ui

import android.content.ClipData
import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.core.content.FileProvider
import java.io.File

// Share on songs and albums: Android's share sheet with the title, artist and album as text and the cover as an
// image; and a song's own file, for sending it to another app or person.

/** Shares text with a cover (when there is one), through Android's share sheet. */
fun shareText(context: Context, title: String, text: String, cover: File?) {
    val image = cover?.takeIf { it.exists() }?.let { runCatching { FileProvider.getUriForFile(context, "${context.packageName}.covers", it) }.getOrNull() }
    val intent = Intent(Intent.ACTION_SEND).apply {
        putExtra(Intent.EXTRA_TEXT, text)
        putExtra(Intent.EXTRA_TITLE, title)
        if (image != null) {
            type = "image/jpeg"
            putExtra(Intent.EXTRA_STREAM, image)
            // The preview in the share sheet, and the receiving app, may read only this cover.
            clipData = ClipData.newUri(context.contentResolver, title, image)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        } else type = "text/plain"
    }
    context.startActivity(Intent.createChooser(intent, title).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
}

/** Shares a song's audio file (in the music folder) with another app, which may read only that file. */
fun shareFile(context: Context, title: String, uri: Uri, mimeType: String) {
    val intent = Intent(Intent.ACTION_SEND).apply {
        type = mimeType
        putExtra(Intent.EXTRA_STREAM, uri)
        putExtra(Intent.EXTRA_TITLE, title)
        clipData = ClipData.newUri(context.contentResolver, title, uri)
        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
    }
    context.startActivity(Intent.createChooser(intent, title).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
}

/** "“Paranoid Android” by Radiohead, from OK Computer (1997)". */
fun songShareText(title: String, artist: String, album: String?, year: Int?): String =
    "“$title” by $artist" + (album?.let { ", from $it" + (year?.let { y -> " ($y)" } ?: "") } ?: "")

/** "OK Computer by Radiohead (1997)". */
fun albumShareText(title: String, artist: String, year: Int?): String = "$title by $artist" + (year?.let { " ($it)" } ?: "")

/** The MIME type of a song's file, from its codec. */
fun audioMimeType(codec: String): String = when (codec) {
    "flac" -> "audio/flac"
    "mp3" -> "audio/mpeg"
    "aac", "alac" -> "audio/mp4"
    "opus" -> "audio/ogg"
    "vorbis" -> "audio/ogg"
    "wav" -> "audio/wav"
    else -> "audio/*"
}
