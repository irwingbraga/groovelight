package dev.irwingbraga.groovelight.app

import android.content.ContentProvider
import android.content.ContentValues
import android.content.Context
import android.database.Cursor
import android.net.Uri
import android.os.ParcelFileDescriptor
import dev.irwingbraga.groovelight.library.ArtworkStore
import java.io.FileNotFoundException

/**
 * The covers, for Android Auto and other media browsers, which show them from another app: read-only, by hash
 * (content://<app>.artwork/<hash>), and covers only (the artwork store's files, nothing else).
 */
class ArtworkProvider : ContentProvider() {
    override fun onCreate() = true

    override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor {
        if (mode != "r") throw SecurityException("Covers are read-only")
        val hash = uri.lastPathSegment?.takeIf { it.matches(Regex("[A-Za-z0-9_-]+")) } ?: throw FileNotFoundException(uri.toString())
        val file = ArtworkStore(context!!).file(hash).takeIf { it.exists() } ?: throw FileNotFoundException(uri.toString())
        return ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
    }

    override fun getType(uri: Uri) = "image/jpeg"
    override fun query(uri: Uri, projection: Array<out String>?, selection: String?, selectionArgs: Array<out String>?, sortOrder: String?): Cursor? = null
    override fun insert(uri: Uri, values: ContentValues?): Uri? = null
    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?) = 0
    override fun update(uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<out String>?) = 0

    companion object {
        /** A cover's address for another app, or null without one (or when this device does not have it). */
        fun uri(context: Context, hash: String?): Uri? = hash?.takeIf { ArtworkStore(context).has(it) }
            ?.let { Uri.parse("content://${context.packageName}.artwork/$it") }
    }
}
