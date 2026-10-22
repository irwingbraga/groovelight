package dev.irwingbraga.groovelight.update

/**
 * Where the app's own update stands (the GitHub build checks its releases; the Play build leaves updates to Play and
 * stays [Idle]).
 */
sealed interface UpdateState {
    data object Idle : UpdateState
    data object Checking : UpdateState
    /** The newest release is this one (or older). */
    data class UpToDate(val version: String) : UpdateState
    /** A newer release: its APK, with the SHA-256 GitHub gives for it. */
    data class Available(val version: String, val notes: String, val url: String, val size: Long, val sha256: String?) : UpdateState
    /** Downloading the release's APK (`fraction` 0 to 1). */
    data class Downloading(val version: String, val fraction: Float) : UpdateState
    /** Handed to Android's installer: it asks the user, then the app restarts as the new version. */
    data class Installing(val version: String) : UpdateState
    data class Failed(val message: String, val available: Available? = null) : UpdateState
}

/** Versions as "0.4.0" (a tag's "v" dropped): compared part by part, numbers as numbers. */
fun isNewer(candidate: String, current: String): Boolean {
    fun parts(version: String) = version.removePrefix("v").substringBefore('-').split('.').map { it.toIntOrNull() ?: 0 }
    val a = parts(candidate)
    val b = parts(current)
    for (index in 0 until maxOf(a.size, b.size)) {
        val difference = a.getOrElse(index) { 0 } - b.getOrElse(index) { 0 }
        if (difference != 0) return difference > 0
    }
    return false
}

/**
 * A release's notes as plain text for the update dialog: the Android section when there is one (the release also
 * describes the Mac app), without Markdown's marks (headings, emphasis, code, notes and links shown as their text).
 */
fun readableNotes(markdown: String): String {
    val lines = markdown.lines()
    val heading = lines.indexOfFirst { it.trimStart().startsWith("#") && Regex("android|groovelight sync", RegexOption.IGNORE_CASE).containsMatchIn(it) }
    val section = if (heading < 0) lines else {
        val level = lines[heading].trimStart().takeWhile { it == '#' }.length
        val end = (heading + 1 until lines.size).firstOrNull { index ->
            val line = lines[index].trimStart()
            line.startsWith("#") && line.takeWhile { it == '#' }.length <= level
        } ?: lines.size
        lines.subList(heading + 1, end)
    }
    return section.asSequence()
        .filterNot { Regex("""^\s*>\s*\[!\w+]""").containsMatchIn(it) }
        .map { line ->
            line.replace(Regex("""^\s*>\s?"""), "")
                .replace(Regex("""^\s*#+\s*"""), "")
                .replace(Regex("""^(\s*)[-*]\s+"""), "$1• ")
                .replace(Regex("""\[([^\]]+)]\([^)]*\)"""), "$1")
                .replace("**", "").replace("`", "")
        }
        .joinToString("\n").replace(Regex("""\n{3,}"""), "\n\n").trim()
}
