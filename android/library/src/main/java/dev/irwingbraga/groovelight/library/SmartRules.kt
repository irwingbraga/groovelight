package dev.irwingbraga.groovelight.library

import android.util.JsonReader
import android.util.JsonToken
import org.json.JSONArray
import org.json.JSONObject
import java.time.Instant
import java.time.ZoneId

/**
 * A smart playlist's rules, as the Mac keeps them (`SmartPlaylistRules`), evaluated here on the device's own songs, so
 * loves, ratings and plays made on the device change the playlist at once. Rules on what the device does not know
 * (composer, comments, format, skips, bit rate, BPM, quality, sizes) cannot be evaluated: those playlists keep the
 * songs the Mac chose.
 */
data class SmartRules(val matchAll: Boolean, val rules: List<Rule>, val limit: Limit?) {
    data class Rule(
        val field: String,
        val op: String,
        val text: String = "",
        val number: Double = 0.0,
        val number2: Double = 0.0,
        /** Epoch milliseconds. */
        val date: Long = 0,
        val period: Int = 2,
        val periodUnit: String = "weeks",
    )

    data class Limit(val count: Int, val unit: String, val selectedBy: String, val seed: Long)

    /** Whether every rule and the limit can be evaluated with what the device knows. */
    val evaluable: Boolean get() = rules.all { it.field in FIELDS.keys && it.op in OPERATORS } &&
        (limit == null || (limit.unit in setOf("songs", "minutes", "hours") && limit.selectedBy in ORDERS))

    /**
     * The songs matching, in the Mac's order: by the limit's selection when there is a limit (then cut to it), otherwise
     * as an album list. Null when the rules cannot be evaluated here.
     */
    fun evaluate(tracks: List<Track>, albums: Map<String, Album>, now: Long = System.currentTimeMillis()): List<Track>? {
        if (!evaluable) return null
        val songs = tracks.map { Song(it, albums[it.albumKey]) }
        val matching = songs.filter { song ->
            rules.isEmpty() || if (matchAll) rules.all { matches(it, song, now) } else rules.any { matches(it, song, now) }
        }
        if (limit == null) return matching.sortedWith(ALBUM_ORDER).map { it.track }
        val ordered = matching.sortedWith(ORDERS.getValue(limit.selectedBy)(limit.seed).thenBy { it.track.id })
        if (limit.unit == "songs") return ordered.take(limit.count.coerceAtLeast(0)).map { it.track }
        val perUnit = if (limit.unit == "hours") 3_600_000.0 else 60_000.0
        var total = 0.0
        val result = mutableListOf<Track>()
        for (song in ordered) {
            val size = song.track.durationMs / perUnit
            if (total + size > limit.count) break
            total += size
            result += song.track
        }
        return result
    }

    fun toJson(): String = JSONObject()
        .put("match", if (matchAll) "all" else "any")
        .put("rules", JSONArray(rules.map {
            JSONObject().put("field", it.field).put("op", it.op).put("text", it.text).put("number", it.number).put("number2", it.number2)
                .put("date", it.date).put("period", it.period).put("periodUnit", it.periodUnit)
        }))
        .apply { limit?.let { put("limit", JSONObject().put("count", it.count).put("unit", it.unit).put("selectedBy", it.selectedBy).put("seed", it.seed)) } }
        .toString()

    /** A song with its album, as the rules see it. */
    private class Song(val track: Track, val album: Album?) {
        val albumArtist get() = album?.artist?.takeIf { it.isNotEmpty() } ?: track.artist
    }

    private fun matches(rule: Rule, song: Song, now: Long): Boolean {
        val value = FIELDS.getValue(rule.field)(song)
        return when (value) {
            is Text -> {
                val text = value.value
                when (rule.op) {
                    "contains" -> text.contains(rule.text, ignoreCase = true)
                    "doesNotContain" -> !text.contains(rule.text, ignoreCase = true)
                    "is" -> text.equals(rule.text, ignoreCase = true)
                    "isNot" -> !text.equals(rule.text, ignoreCase = true)
                    "beginsWith" -> text.startsWith(rule.text, ignoreCase = true)
                    "endsWith" -> text.endsWith(rule.text, ignoreCase = true)
                    else -> true
                }
            }
            is Number -> {
                val scale = SCALES[rule.field] ?: 1.0
                val target = rule.number * scale
                val upper = rule.number2 * scale
                // Whole units compare with a tolerance, as on the Mac (a 3:59.6 song "is 4 minutes"; 44.1 kHz).
                val tolerance = if (rule.field == "time") 30.0 else 0.001
                val number = value.value
                when (rule.op) {
                    "is" -> number != null && number in (target - tolerance)..(target + tolerance)
                    "isNot" -> number == null || number !in (target - tolerance)..(target + tolerance)
                    "greaterThan" -> number != null && number > target
                    "lessThan" -> (number ?: 0.0) < target
                    "inRange" -> number != null && number in (minOf(target, upper) - tolerance)..(maxOf(target, upper) + tolerance)
                    else -> true
                }
            }
            is Moment -> {
                val at = value.value
                val zone = ZoneId.systemDefault()
                val date = Instant.ofEpochMilli(rule.date).atZone(zone).toLocalDate()
                val day = date.atStartOfDay(zone).toInstant().toEpochMilli()
                val since = now - rule.period.toLong() * (PERIOD_DAYS[rule.periodUnit] ?: 1) * 86_400_000
                when (rule.op) {
                    "inTheLast" -> at != null && at >= since
                    "notInTheLast" -> at == null || at < since
                    "isAfter" -> at != null && at >= date.plusDays(1).atStartOfDay(zone).toInstant().toEpochMilli()
                    "isBefore" -> at != null && at < day
                    else -> true
                }
            }
            is Flag -> when (rule.op) {
                "isTrue" -> value.value
                "isFalse" -> !value.value
                else -> true
            }
        }
    }

    private sealed interface Value
    private class Text(val value: String) : Value
    private class Number(val value: Double?) : Value
    private class Moment(val value: Long?) : Value
    private class Flag(val value: Boolean) : Value

    companion object {
        private val FIELDS: Map<String, (Song) -> Value> = mapOf(
            "title" to { s -> Text(s.track.title) },
            "artist" to { s -> Text(s.track.artist) },
            "album" to { s -> Text(s.album?.title ?: "") },
            "albumArtist" to { s -> Text(s.albumArtist) },
            "genre" to { s -> Text(s.track.genre ?: "") },
            "year" to { s -> Number(s.track.year?.toDouble()) },
            "rating" to { s -> Number(s.track.rating.toDouble()) },
            "plays" to { s -> Number(s.track.playCount.toDouble()) },
            "time" to { s -> Number(s.track.durationMs / 1000.0) },
            "sampleRate" to { s -> Number(s.track.sampleRate?.toDouble()) },
            "bitDepth" to { s -> Number(s.track.bitDepth?.toDouble()) },
            "dateAdded" to { s -> Moment(s.track.dateAdded) },
            "lastPlayed" to { s -> Moment(s.track.lastPlayed) },
            "loved" to { s -> Flag(s.track.loved) },
            "compilation" to { s -> Flag(s.album?.isCompilation == true) },
            "hasArtwork" to { s -> Flag(s.track.artworkHash != null) },
            "hasLyrics" to { s -> Flag(!s.track.lyrics.isNullOrEmpty()) },
        )
        private val OPERATORS = setOf("contains", "doesNotContain", "is", "isNot", "beginsWith", "endsWith", "greaterThan", "lessThan",
            "inRange", "inTheLast", "notInTheLast", "isBefore", "isAfter", "isTrue", "isFalse")
        /** From the unit typed to the value kept (minutes to seconds, kHz to Hz). */
        private val SCALES = mapOf("time" to 60.0, "sampleRate" to 1000.0)
        private val PERIOD_DAYS = mapOf("days" to 1L, "weeks" to 7L, "months" to 30L)

        private val NOCASE = String.CASE_INSENSITIVE_ORDER
        /** SQLite's order: nulls before values going up, after them going down. */
        private fun <T : Comparable<T>> up(key: (Song) -> T?): Comparator<Song> = compareBy(nullsFirst(), key)
        private fun <T : Comparable<T>> down(key: (Song) -> T?): Comparator<Song> = compareByDescending(nullsFirst(), key)
        private val DISC_TRACK: Comparator<Song> = up<Int> { it.track.discNumber }.then(up { it.track.trackNumber })

        private val ALBUM_ORDER: Comparator<Song> = Comparator<Song> { a, b -> NOCASE.compare(a.albumArtist, b.albumArtist) }
            .then { a, b -> NOCASE.compare(a.album?.title ?: "", b.album?.title ?: "") }
            .then(DISC_TRACK).then { a, b -> NOCASE.compare(a.track.title, b.track.title) }

        private val ORDERS: Map<String, (Long) -> Comparator<Song>> = mapOf(
            // The Mac's stable pseudo-random order for the seed (a multiplicative hash of the id).
            "random" to { seed -> up { ((it.track.id + seed) * 2654435761L) % 4294967291L } },
            "title" to { _ -> Comparator { a, b -> NOCASE.compare(a.track.title, b.track.title) } },
            "album" to { _ -> Comparator<Song> { a, b -> NOCASE.compare(a.album?.title ?: "", b.album?.title ?: "") }.then(DISC_TRACK) },
            "artist" to { _ ->
                Comparator<Song> { a, b -> NOCASE.compare(a.track.artist, b.track.artist) }
                    .then { a, b -> NOCASE.compare(a.album?.title ?: "", b.album?.title ?: "") }.then(DISC_TRACK)
            },
            "genre" to { _ ->
                up<String> { it.track.genre?.lowercase() }.then { a, b -> NOCASE.compare(a.track.artist, b.track.artist) }
            },
            "highestRated" to { _ -> down<Int> { it.track.rating }.then(down { it.track.playCount }) },
            "lowestRated" to { _ -> up<Int> { it.track.rating }.then(up { it.track.playCount }) },
            "mostPlayed" to { _ -> down<Int> { it.track.playCount }.then(down { it.track.lastPlayed }) },
            "leastPlayed" to { _ -> up<Int> { it.track.playCount }.then(up { it.track.lastPlayed }) },
            "mostRecentlyPlayed" to { _ -> up<Boolean> { it.track.lastPlayed == null }.then(down { it.track.lastPlayed }) },
            "leastRecentlyPlayed" to { _ -> up<Boolean> { it.track.lastPlayed != null }.then(up { it.track.lastPlayed }) },
            "mostRecentlyAdded" to { _ -> down<Long> { it.track.dateAdded } },
            "leastRecentlyAdded" to { _ -> up<Long> { it.track.dateAdded } },
        )

        fun fromJson(json: String): SmartRules? = runCatching {
            val obj = JSONObject(json)
            val rules = obj.optJSONArray("rules") ?: JSONArray()
            SmartRules(
                matchAll = obj.optString("match", "all") != "any",
                rules = (0 until rules.length()).map { index ->
                    val rule = rules.getJSONObject(index)
                    Rule(rule.getString("field"), rule.getString("op"), rule.optString("text"), rule.optDouble("number", 0.0),
                        rule.optDouble("number2", 0.0), rule.optLong("date"), rule.optInt("period", 2), rule.optString("periodUnit", "weeks"))
                },
                limit = obj.optJSONObject("limit")?.let { Limit(it.getInt("count"), it.getString("unit"), it.getString("selectedBy"), it.optLong("seed")) },
            )
        }.getOrNull()

        /** Reads the Mac's rules from the snapshot (dates as ISO 8601). */
        fun read(reader: JsonReader): SmartRules {
            var matchAll = true; val rules = mutableListOf<Rule>(); var limit: Limit? = null
            reader.beginObject()
            while (reader.hasNext()) when (reader.nextName()) {
                "match" -> matchAll = reader.nextString() != "any"
                "rules" -> {
                    reader.beginArray()
                    while (reader.hasNext()) rules += rule(reader)
                    reader.endArray()
                }
                "limit" -> if (reader.peek() == JsonToken.NULL) reader.nextNull() else {
                    var count = 25; var unit = "songs"; var selectedBy = "random"; var seed = 0L
                    reader.beginObject()
                    while (reader.hasNext()) when (reader.nextName()) {
                        "count" -> count = reader.nextInt()
                        "unit" -> unit = reader.nextString()
                        "selectedBy" -> selectedBy = reader.nextString()
                        "seed" -> seed = reader.nextLong()
                        else -> reader.skipValue()
                    }
                    reader.endObject()
                    limit = Limit(count, unit, selectedBy, seed)
                }
                else -> reader.skipValue()
            }
            reader.endObject()
            return SmartRules(matchAll, rules, limit)
        }

        private fun rule(reader: JsonReader): Rule {
            var rule = Rule("", "")
            reader.beginObject()
            while (reader.hasNext()) {
                rule = when (reader.nextName()) {
                    "field" -> rule.copy(field = reader.nextString())
                    "op" -> rule.copy(op = reader.nextString())
                    "text" -> rule.copy(text = reader.nextString())
                    "number" -> rule.copy(number = reader.nextDouble())
                    "number2" -> rule.copy(number2 = reader.nextDouble())
                    "date" -> rule.copy(date = runCatching { Instant.parse(reader.nextString()).toEpochMilli() }.getOrDefault(0))
                    "period" -> rule.copy(period = reader.nextInt())
                    "periodUnit" -> rule.copy(periodUnit = reader.nextString())
                    else -> rule.also { reader.skipValue() }
                }
            }
            reader.endObject()
            return rule
        }
    }
}
