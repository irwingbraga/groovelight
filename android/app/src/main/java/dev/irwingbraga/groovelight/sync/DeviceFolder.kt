package dev.irwingbraga.groovelight.sync

import android.content.ContentResolver
import android.content.Context
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Environment
import android.os.StatFs
import android.provider.DocumentsContract
import android.provider.DocumentsContract.Document
import java.io.File
import java.io.OutputStream

/**
 * The music folder the user picked (any folder on internal storage or an SD card), through the Storage Access
 * Framework. One walk indexes every file and folder by relative path, so the rest needs no further lookups.
 */
class DeviceFolder(private val context: Context, val tree: Uri) {
    private val resolver: ContentResolver = context.contentResolver
    private val rootId = DocumentsContract.getTreeDocumentId(tree)

    data class Item(val id: String, val isFolder: Boolean, val size: Long)

    /** Relative path -> item ("" is the folder itself). */
    private val index = mutableMapOf("" to Item(rootId, true, 0))

    /** Every file and folder under the picked folder. */
    fun scan(): List<String> {
        index.clear()
        index[""] = Item(rootId, true, 0)
        val pending = ArrayDeque(listOf("" to rootId))
        while (pending.isNotEmpty()) {
            val (path, id) = pending.removeFirst()
            val children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, id)
            resolver.query(children, arrayOf(Document.COLUMN_DOCUMENT_ID, Document.COLUMN_DISPLAY_NAME, Document.COLUMN_MIME_TYPE,
                Document.COLUMN_SIZE), null, null, null)?.use { cursor ->
                while (cursor.moveToNext()) {
                    val childPath = if (path.isEmpty()) cursor.getString(1) else "$path/${cursor.getString(1)}"
                    val isFolder = cursor.getString(2) == Document.MIME_TYPE_DIR
                    index[childPath] = Item(cursor.getString(0), isFolder, if (cursor.isNull(3)) 0 else cursor.getLong(3))
                    if (isFolder) pending.addLast(childPath to cursor.getString(0))
                }
            }
        }
        return index.filterValues { !it.isFolder }.keys.filter { it.isNotEmpty() }
    }

    fun exists(path: String) = index.containsKey(path)

    fun size(path: String) = index[path]?.size ?: 0

    fun read(path: String): ByteArray? = index[path]?.let { item ->
        runCatching { resolver.openInputStream(uri(item.id))?.use { it.readBytes() } }.getOrNull()
    }

    /** Replaces a small file's contents (the manifest). */
    fun write(path: String, data: ByteArray) {
        val item = index[path] ?: create(path)
        resolver.openOutputStream(uri(item.id), "wt")!!.use { it.write(data) }
        index[path] = item.copy(size = data.size.toLong())
    }

    /** Where a download goes: `.<name>.partial` beside the target, appended to when it is already there. */
    fun openPartial(path: String): Pair<OutputStream, Long> {
        val partial = partialPath(path)
        val existing = index[partial]
        if (existing != null) {
            return resolver.openOutputStream(uri(existing.id), "wa")!! to existing.size
        }
        val item = create(partial)
        return resolver.openOutputStream(uri(item.id), "w")!! to 0L
    }

    /** Drops a partial download that cannot be resumed. */
    fun discardPartial(path: String) = delete(partialPath(path))

    /** Gives the finished partial its real name, replacing an older copy. */
    fun commit(path: String, size: Long) {
        val partial = partialPath(path)
        val item = index.remove(partial) ?: return
        index[path]?.let { old -> DocumentsContract.deleteDocument(resolver, uri(old.id)) }
        val renamed = DocumentsContract.renameDocument(resolver, uri(item.id), path.substringAfterLast('/'))
        index[path] = Item(renamed?.let { DocumentsContract.getDocumentId(it) } ?: item.id, false, size)
    }

    fun delete(path: String) {
        val item = index.remove(path) ?: return
        runCatching { DocumentsContract.deleteDocument(resolver, uri(item.id)) }
    }

    /** Removes folders left empty, from the deepest up (the picked folder itself stays). */
    fun pruneEmptyFolders(paths: Collection<String>) {
        val folders = paths.map { it.substringBeforeLast('/', "") }.toSortedSet(compareByDescending<String> { it.length }.thenBy { it })
        for (start in folders) {
            var folder = start
            while (folder.isNotEmpty()) {
                val prefix = "$folder/"
                if (index.keys.any { it.startsWith(prefix) }) break
                val item = index.remove(folder) ?: break
                runCatching { DocumentsContract.deleteDocument(resolver, uri(item.id)) }
                folder = folder.substringBeforeLast('/', "")
            }
        }
    }

    private fun create(path: String): Item {
        val parent = folder(path.substringBeforeLast('/', ""))
        val created = DocumentsContract.createDocument(resolver, uri(parent.id), "application/octet-stream", path.substringAfterLast('/'))
            ?: throw java.io.IOException("Could not create $path")
        return Item(DocumentsContract.getDocumentId(created), false, 0).also { index[path] = it }
    }

    private fun folder(path: String): Item {
        index[path]?.let { return it }
        val parent = folder(path.substringBeforeLast('/', ""))
        val created = DocumentsContract.createDocument(resolver, uri(parent.id), Document.MIME_TYPE_DIR, path.substringAfterLast('/'))
            ?: throw java.io.IOException("Could not create the folder $path")
        return Item(DocumentsContract.getDocumentId(created), true, 0).also { index[path] = it }
    }

    private fun uri(id: String): Uri = DocumentsContract.buildDocumentUriUsingTree(tree, id)

    private fun partialPath(path: String): String {
        val folder = path.substringBeforeLast('/', "")
        val name = ".${path.substringAfterLast('/')}.partial"
        return if (folder.isEmpty()) name else "$folder/$name"
    }

    /** The storage (internal memory or an SD card) the folder is on, from Android's list of volumes. */
    val volume: Storage.Volume? get() = Storage.volume(context, rootId)

    /** The folder as a file system path ("primary:Music" is /storage/emulated/0/Music), for media scans. */
    val realPath: File? get() {
        val relative = rootId.substringAfter(':', "")
        val base = volume?.directory ?: if (rootId.startsWith("primary:")) Environment.getExternalStorageDirectory() else return null
        return File(base, relative)
    }

    val freeBytes: Long get() = volume?.free ?: 0
    val totalBytes: Long get() = volume?.total ?: 0

    /** Every volume, the folder's marked. */
    val volumes: List<Storage.Volume> get() = Storage.volumes(context, rootId)

    /** Tells Android's media library about new and removed songs, so player apps see them right away. */
    fun scanMedia(paths: Collection<String>) {
        val root = realPath ?: return
        if (paths.isEmpty()) return
        MediaScannerConnection.scanFile(context, paths.map { File(root, it).path }.toTypedArray(), null, null)
    }

    val displayName: String get() {
        val relative = rootId.substringAfter(':', "")
        val storage = volume?.name ?: if (rootId.startsWith("primary:")) "Internal storage" else "SD card"
        return storage + if (relative.isEmpty()) "" else " / $relative"
    }
}
