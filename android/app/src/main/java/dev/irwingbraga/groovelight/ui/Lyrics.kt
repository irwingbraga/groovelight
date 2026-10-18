package dev.irwingbraga.groovelight.ui

/** A song's lyrics from the snapshot: synced (LRC, lines with times) or plain text. */
sealed interface Lyrics {
    data class Synced(val lines: List<Line>) : Lyrics {
        /** The line being sung at `positionMs` (-1 before the first one). */
        fun lineAt(positionMs: Long): Int {
            var low = 0
            var high = lines.lastIndex
            var found = -1
            while (low <= high) {
                val middle = (low + high) ushr 1
                if (lines[middle].timeMs <= positionMs) {
                    found = middle
                    low = middle + 1
                } else {
                    high = middle - 1
                }
            }
            return found
        }
    }

    data class Plain(val text: String) : Lyrics

    data class Line(val timeMs: Long, val text: String)

    companion object {
        private val tag = Regex("""\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?]""")
        private val metadata = Regex("""^\[[a-zA-Z#]+:.*]$""")

        /**
         * Reads LRC (`[mm:ss.xx] text`, several times per line allowed, `[offset:+/-ms]` applied, ID tags skipped),
         * or plain text when no line has a time.
         */
        fun parse(text: String?): Lyrics? {
            if (text.isNullOrBlank()) return null
            var offset = 0L
            val lines = mutableListOf<Line>()
            for (raw in text.lineSequence()) {
                val line = raw.trim()
                Regex("""^\[offset:\s*([+-]?\d+)]$""", RegexOption.IGNORE_CASE).find(line)?.let {
                    offset = it.groupValues[1].toLong()
                }
                val times = generateSequence(tag.matchAt(line, 0)) { previous -> tag.matchAt(line, previous.range.last + 1) }.toList()
                if (times.isEmpty()) continue
                val words = line.substring(times.last().range.last + 1).trim()
                for (time in times) {
                    val minutes = time.groupValues[1].toLong()
                    val seconds = time.groupValues[2].toLong()
                    val fraction = time.groupValues[3]
                    val milliseconds = when (fraction.length) {
                        0 -> 0L
                        1 -> fraction.toLong() * 100
                        2 -> fraction.toLong() * 10
                        else -> fraction.take(3).toLong()
                    }
                    lines += Line(minutes * 60_000 + seconds * 1000 + milliseconds, words)
                }
            }
            if (lines.isEmpty()) {
                val plain = text.lineSequence().filterNot { metadata.matches(it.trim()) }.joinToString("\n").trim()
                return if (plain.isEmpty()) null else Plain(plain)
            }
            // A positive offset shows lines earlier.
            return Synced(lines.map { it.copy(timeMs = (it.timeMs - offset).coerceAtLeast(0)) }.sortedBy { it.timeMs })
        }
    }
}
