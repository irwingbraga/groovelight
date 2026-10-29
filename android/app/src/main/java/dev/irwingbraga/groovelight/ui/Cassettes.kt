package dev.irwingbraga.groovelight.ui

import android.content.ClipData
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.net.Uri
import androidx.core.content.FileProvider
import androidx.core.content.edit
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import org.json.JSONObject
import java.io.File
import java.io.InputStream
import java.util.Locale
import java.util.UUID
import java.util.zip.ZipEntry
import java.util.zip.ZipInputStream
import java.util.zip.ZipOutputStream

/** What Now Playing shows in the cover's place, as on the Mac and the iPhone. */
enum class NowPlayingSkin(val label: String) { COVER("Cover"), VINYL("Vinyl"), CASSETTE("Cassette"), CD("CD") }

/**
 * The look chosen for Now Playing and the user's cassettes: a folder for each in the app's files (cassettes/<id>/,
 * holding `cassette.json` and its pictures), beside the built-in ones. A design is shared as a zip of its folder and
 * imported from one (or from a `cassette.json`), so designs travel between Android, the Mac and the iPhone.
 */
object Cassettes {
    const val FILE_NAME = "cassette.json"
    enum class Picture(val key: String) { SHELL("shell"), LABEL("label") }

    private var prefs: SharedPreferences? = null
    private lateinit var folder: File
    private val chosenSkin = MutableStateFlow(NowPlayingSkin.COVER)
    private val chosenCassette = MutableStateFlow(CassetteDesign.CLASSIC.id)
    private val stored = MutableStateFlow<List<CassetteDesign>>(emptyList())
    private val pictureRevision = MutableStateFlow(0)

    val skin: StateFlow<NowPlayingSkin> = chosenSkin
    val cassetteId: StateFlow<String> = chosenCassette
    val custom: StateFlow<List<CassetteDesign>> = stored
    /** Bumped when a design's pictures change, so they are loaded again. */
    val revision: StateFlow<Int> = pictureRevision

    fun init(context: Context) {
        if (prefs != null) return
        folder = File(context.filesDir, "cassettes")
        prefs = context.getSharedPreferences("nowPlaying", Context.MODE_PRIVATE).also { stored ->
            chosenSkin.value = stored.getString("skin", null)?.let { runCatching { NowPlayingSkin.valueOf(it) }.getOrNull() } ?: NowPlayingSkin.COVER
            chosenCassette.value = stored.getString("cassette", null) ?: CassetteDesign.CLASSIC.id
        }
        reload()
    }

    /** For tests: a store in this folder, without preferences. */
    internal fun initForTest(folder: File) {
        this.folder = folder
        reload()
    }

    fun setSkin(skin: NowPlayingSkin) {
        chosenSkin.value = skin
        prefs?.edit { putString("skin", skin.name) }
    }

    fun choose(design: CassetteDesign) {
        chosenCassette.value = design.id
        prefs?.edit { putString("cassette", design.id) }
    }

    val all: List<CassetteDesign> get() = CassetteDesign.BUILT_IN + stored.value

    /** The design with that id, or Classic (a deleted design's choice falls back to it). */
    fun design(id: String?): CassetteDesign = all.firstOrNull { it.id == id } ?: CassetteDesign.CLASSIC

    fun reload() {
        stored.value = (folder.listFiles()?.toList() ?: emptyList())
            .mapNotNull { dir -> runCatching { read(File(dir, FILE_NAME)) }.getOrNull() }
            .sortedBy { it.name.lowercase(Locale.ROOT) }
    }

    fun folderOf(design: CassetteDesign) = File(folder, design.id)

    /** A design's picture on disk (none for a built-in design). */
    fun pictureFile(design: CassetteDesign, picture: Picture): File? {
        if (design.isBuiltIn) return null
        val name = (if (picture == Picture.SHELL) design.shellImage else design.labelImage) ?: return null
        return File(folderOf(design), File(name).name).takeIf { it.isFile }
    }

    fun save(design: CassetteDesign) {
        require(!design.isBuiltIn) { "The built-in cassettes cannot be changed" }
        val dir = folderOf(design).apply { mkdirs() }
        write(design, File(dir, FILE_NAME))
        reload()
    }

    /** A copy to change (built-in designs are changed this way), with its pictures. */
    fun duplicate(design: CassetteDesign, name: String? = null): CassetteDesign {
        val copy = design.copy(id = UUID.randomUUID().toString().uppercase(Locale.ROOT), name = name ?: "${design.name} Copy")
        val dir = folderOf(copy).apply { mkdirs() }
        Picture.entries.forEach { picture -> pictureFile(design, picture)?.let { it.copyTo(File(dir, it.name)) } }
        write(copy, File(dir, FILE_NAME))
        reload()
        return copy
    }

    fun delete(design: CassetteDesign) {
        require(!design.isBuiltIn) { "The built-in cassettes cannot be changed" }
        folderOf(design).deleteRecursively()
        if (chosenCassette.value == design.id) choose(CassetteDesign.CLASSIC)
        reload()
    }

    /** Sets (or with null, removes) a picture, copied into the design's folder; the design is saved with it. */
    fun setPicture(design: CassetteDesign, picture: Picture, source: InputStream?, extension: String = "png"): CassetteDesign {
        val dir = folderOf(design).apply { mkdirs() }
        pictureFile(design, picture)?.delete()
        val name = source?.use { input ->
            "${picture.key}-${UUID.randomUUID().toString().take(8)}.$extension".also { File(dir, it).outputStream().use { out -> input.copyTo(out) } }
        }
        val changed = if (picture == Picture.SHELL) design.copy(shellImage = name) else design.copy(labelImage = name)
        save(changed)
        pictureRevision.value++
        return changed
    }

    /**
     * Adds a design from a zip of its folder (a shared `.cassette`, its files at the top or in one folder) or from its
     * `cassette.json`. It keeps its id unless one here has it already, then it comes in as a copy.
     */
    fun import(context: Context, uri: Uri): CassetteDesign {
        val resolver = context.contentResolver
        val bytes = resolver.openInputStream(uri)?.use { it.readBytes() } ?: error("The file could not be read")
        val isZip = bytes.size > 4 && bytes[0] == 0x50.toByte() && bytes[1] == 0x4B.toByte()
        return if (isZip) importZip(bytes.inputStream()) else importJson(String(bytes))
    }

    internal fun importJson(text: String): CassetteDesign {
        var design = CassetteDesign.fromJson(JSONObject(text)).copy(shellImage = null, labelImage = null)
        if (all.any { it.id == design.id }) design = design.copy(id = UUID.randomUUID().toString().uppercase(Locale.ROOT))
        save(design)
        return design
    }

    internal fun importZip(input: InputStream): CassetteDesign {
        val files = mutableMapOf<String, ByteArray>()
        ZipInputStream(input).use { zip ->
            generateSequence { zip.nextEntry }.forEach { entry ->
                // Only the name: nothing is written outside the design's folder, whatever the zip says.
                if (!entry.isDirectory && !entry.name.contains("__MACOSX")) files[File(entry.name).name] = zip.readBytes()
            }
        }
        val json = files[FILE_NAME] ?: error("This is not a cassette: it has no $FILE_NAME")
        var design = CassetteDesign.fromJson(JSONObject(String(json)))
        if (all.any { it.id == design.id }) design = design.copy(id = UUID.randomUUID().toString().uppercase(Locale.ROOT))
        val dir = folderOf(design).apply { mkdirs() }
        fun keep(name: String?) = name?.let { File(it).name }?.takeIf { files[it] != null }?.also { File(dir, it).writeBytes(files[it]!!) }
        design = design.copy(shellImage = keep(design.shellImage), labelImage = keep(design.labelImage))
        save(design)
        return design
    }

    /** The design as a zip of its `.cassette` folder ("Name.cassette/cassette.json" and its pictures). */
    fun zip(design: CassetteDesign, target: File) {
        val root = "${design.name.replace(Regex("[/:\\\\]"), "-")}.cassette/"
        ZipOutputStream(target.outputStream()).use { zip ->
            zip.putNextEntry(ZipEntry(root + FILE_NAME))
            zip.write(design.toJson().toString(2).toByteArray())
            zip.closeEntry()
            Picture.entries.forEach { picture ->
                pictureFile(design, picture)?.let { file ->
                    zip.putNextEntry(ZipEntry(root + file.name))
                    file.inputStream().use { it.copyTo(zip) }
                    zip.closeEntry()
                }
            }
        }
    }

    /** Shares the design through Android's share sheet, as a zip that opens on the Mac and the iPhone too. */
    fun share(context: Context, design: CassetteDesign) {
        val dir = File(context.cacheDir, "shared-cassettes").apply { deleteRecursively(); mkdirs() }
        val file = File(dir, "${design.name.replace(Regex("[/:\\\\]"), "-")}.cassette.zip")
        zip(design, file)
        val uri = FileProvider.getUriForFile(context, "${context.packageName}.covers", file)
        val intent = Intent(Intent.ACTION_SEND).apply {
            type = "application/zip"
            putExtra(Intent.EXTRA_STREAM, uri)
            putExtra(Intent.EXTRA_TITLE, design.name)
            clipData = ClipData.newUri(context.contentResolver, design.name, uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        context.startActivity(Intent.createChooser(intent, design.name).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }

    private fun read(file: File) = CassetteDesign.fromJson(JSONObject(file.readText()))

    private fun write(design: CassetteDesign, file: File) {
        val temporary = File(file.parentFile, "${file.name}.tmp")
        temporary.writeText(design.toJson().toString(2))
        temporary.renameTo(file)
    }
}
