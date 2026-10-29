package dev.irwingbraga.groovelight.ui

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import org.json.JSONArray
import org.json.JSONObject
import java.util.Locale
import java.util.UUID

/**
 * A cassette for Now Playing's cassette skin, as on the Mac and the iPhone (GroovelightKit's `CassetteDesign`): the
 * shell, the label and the reels as colors and text, and optionally the user's pictures of the shell and the label.
 * Saved as `cassette.json` in a folder with its pictures, the same file on every platform, so a design made anywhere
 * opens here. Sizes and places are relative to the cassette (0 to 1 across its width and its height), on the
 * template's geometry ([CassetteGeometry.STANDARD]) unless the design has its own.
 */
data class CassetteDesign(
    val id: String,
    val name: String,
    val author: String? = null,
    val shellColor: Color,
    /** 0 solid, up to 0.8 the smoked clear shells. */
    val shellClarity: Float = 0f,
    val detailColor: Color,
    val label: Label,
    val reels: Reels,
    val brand: String = "",
    val tapeType: String = "",
    val side: String = "A",
    /** File names in the design's folder: the shell drawn over the reels (its windows transparent), and the label. */
    val shellImage: String? = null,
    val labelImage: String? = null,
    val geometry: CassetteGeometry? = null,
) {
    data class Label(
        val background: Color,
        val stripes: List<Color> = emptyList(),
        val textColor: Color,
        val showsText: Boolean = true,
        val showsArtwork: Boolean = false,
        val handwritten: Boolean = true,
        /** Bands placed anywhere on the label (over its color, under its text): `y` and `height` relative to the label's height. */
        val bands: List<Band> = emptyList(),
        /** A strip to write on above the window, in its own color, the song written on it in its own ink. */
        val writing: Writing? = null,
    )

    data class Band(val color: Color, val y: Float, val height: Float)
    data class Writing(val background: Color, val textColor: Color)

    /** [ringColor]: a printed ring around each hub's hole (the gold rings of the premium tapes). */
    data class Reels(val hubColor: Color, val tapeColor: Color, val ringColor: Color? = null)

    val resolvedGeometry: CassetteGeometry get() = geometry ?: CassetteGeometry.STANDARD
    val isBuiltIn: Boolean get() = BUILT_IN.any { it.id == id }

    fun toJson(): JSONObject = JSONObject().apply {
        put("format", FORMAT)
        put("id", id)
        put("name", name)
        author?.let { put("author", it) }
        put("shellColor", shellColor.hex())
        put("shellClarity", shellClarity.toDouble())
        put("detailColor", detailColor.hex())
        put("label", JSONObject().apply {
            put("background", label.background.hex())
            put("stripes", JSONArray(label.stripes.map { it.hex() }))
            put("textColor", label.textColor.hex())
            put("showsText", label.showsText)
            put("showsArtwork", label.showsArtwork)
            put("handwritten", label.handwritten)
            // Only when used, so plain designs read as before.
            if (label.bands.isNotEmpty()) put("bands", JSONArray(label.bands.map {
                JSONObject().put("color", it.color.hex()).put("y", it.y.toDouble()).put("height", it.height.toDouble())
            }))
            label.writing?.let { put("writing", JSONObject().put("background", it.background.hex()).put("textColor", it.textColor.hex())) }
        })
        put("reels", JSONObject().apply {
            put("hubColor", reels.hubColor.hex())
            put("tapeColor", reels.tapeColor.hex())
            reels.ringColor?.let { put("ringColor", it.hex()) }
        })
        put("brand", brand)
        put("tapeType", tapeType)
        put("side", side)
        shellImage?.let { put("shellImage", it) }
        labelImage?.let { put("labelImage", it) }
        geometry?.let { put("geometry", it.toJson()) }
    }

    companion object {
        const val FORMAT = 1

        /**
         * A design from its file. Fields left out (a design written by hand, or by a later version) come from the
         * Classic one; fields not known are ignored.
         */
        fun fromJson(json: JSONObject): CassetteDesign {
            val fallback = CLASSIC
            val label = json.optJSONObject("label")
            val reels = json.optJSONObject("reels")
            return CassetteDesign(
                id = json.optString("id").takeIf { it.isNotBlank() }?.uppercase(Locale.ROOT) ?: UUID.randomUUID().toString().uppercase(Locale.ROOT),
                name = json.optString("name").ifBlank { "Cassette" },
                author = json.optString("author").takeIf { it.isNotBlank() },
                shellColor = json.color("shellColor") ?: fallback.shellColor,
                shellClarity = json.optDouble("shellClarity", 0.0).toFloat().coerceIn(0f, 0.8f),
                detailColor = json.color("detailColor") ?: fallback.detailColor,
                label = if (label == null) fallback.label else Label(
                    background = label.color("background") ?: Color(0xFFF2EBDD),
                    stripes = label.optJSONArray("stripes")?.let { array -> (0 until array.length()).mapNotNull { parseHex(array.optString(it)) } }.orEmpty(),
                    textColor = label.color("textColor") ?: Color(0xFF1C2A6B),
                    showsText = label.optBoolean("showsText", true),
                    showsArtwork = label.optBoolean("showsArtwork", false),
                    handwritten = label.optBoolean("handwritten", true),
                    bands = label.optJSONArray("bands")?.let { array ->
                        (0 until array.length()).mapNotNull { i ->
                            array.optJSONObject(i)?.let { band ->
                                band.color("color")?.let { Band(it, band.optDouble("y", 0.0).toFloat(), band.optDouble("height", 0.0).toFloat()) }
                            }
                        }
                    }.orEmpty(),
                    writing = label.optJSONObject("writing")?.let { writing ->
                        writing.color("background")?.let { Writing(it, writing.color("textColor") ?: Color(0xFF1C2A6B)) }
                    },
                ),
                reels = if (reels == null) fallback.reels else Reels(
                    hubColor = reels.color("hubColor") ?: fallback.reels.hubColor,
                    tapeColor = reels.color("tapeColor") ?: fallback.reels.tapeColor,
                    ringColor = reels.color("ringColor"),
                ),
                brand = json.optString("brand"),
                tapeType = json.optString("tapeType"),
                side = json.optString("side").ifEmpty { "A" },
                shellImage = json.optString("shellImage").takeIf { it.isNotBlank() },
                labelImage = json.optString("labelImage").takeIf { it.isNotBlank() },
                geometry = json.optJSONObject("geometry")?.let(CassetteGeometry::fromJson),
            )
        }

        private fun JSONObject.color(key: String): Color? = optString(key).takeIf { it.isNotBlank() }?.let(::parseHex)

        /** "#RRGGBB" or "#RRGGBBAA", as in the file. */
        fun parseHex(text: String): Color? {
            val hex = text.trim().removePrefix("#")
            if (hex.length != 6 && hex.length != 8) return null
            val value = hex.toLongOrNull(16) ?: return null
            val rgba = if (hex.length == 6) value shl 8 or 0xFF else value
            return Color(red = (rgba shr 24 and 0xFF).toInt(), green = (rgba shr 16 and 0xFF).toInt(),
                blue = (rgba shr 8 and 0xFF).toInt(), alpha = (rgba and 0xFF).toInt())
        }

        private fun c(hex: String) = parseHex(hex)!!

        val CLASSIC = CassetteDesign(
            id = "6B1C1C8E-0001-4C55-9C11-000000000001", name = "Classic",
            shellColor = c("#1E1E21"), detailColor = c("#4A4A50"),
            label = Label(c("#F2EBDD"), listOf(c("#D8432E"), c("#EE8A2C"), c("#F3C340")), c("#1C2A6B")),
            reels = Reels(c("#F4F4F2"), c("#3A2618")), brand = "GROOVELIGHT", tapeType = "TYPE I · NORMAL",
        )
        val CHROME = CassetteDesign(
            id = "6B1C1C8E-0001-4C55-9C11-000000000002", name = "Chrome",
            shellColor = c("#ECECEA"), detailColor = c("#A9AAB0"),
            label = Label(c("#1F4E9C"), listOf(c("#E9EEF7")), c("#FFFFFF"), handwritten = false),
            reels = Reels(c("#FFFFFF"), c("#2B2018")), brand = "GROOVELIGHT", tapeType = "TYPE II · CrO2",
        )
        val CLEAR = CassetteDesign(
            id = "6B1C1C8E-0001-4C55-9C11-000000000003", name = "Clear",
            shellColor = c("#9FB4C2"), shellClarity = 0.65f, detailColor = c("#D0D8DE"),
            label = Label(c("#FFFFFF"), emptyList(), c("#202020"), showsArtwork = true, handwritten = false),
            reels = Reels(c("#F7F7F7"), c("#4B3423")), brand = "GROOVELIGHT", tapeType = "TYPE II · HIGH BIAS",
        )
        val METAL = CassetteDesign(
            id = "6B1C1C8E-0001-4C55-9C11-000000000004", name = "Metal",
            shellColor = c("#2B2D31"), detailColor = c("#8D8F94"),
            label = Label(c("#C9A750"), listOf(c("#1A1A1A")), c("#1A1A1A"), handwritten = false),
            reels = Reels(c("#C9C9C9"), c("#1F1A16")), brand = "GROOVELIGHT", tapeType = "TYPE IV · METAL",
        )
        val MIXTAPE = CassetteDesign(
            id = "6B1C1C8E-0001-4C55-9C11-000000000005", name = "Mixtape",
            shellColor = c("#E4497A"), detailColor = c("#F7A6C0"),
            label = Label(c("#FFF6D8"), listOf(c("#47B5C9")), c("#2A2A2A"), showsArtwork = true),
            reels = Reels(c("#FFFFFF"), c("#3A2618")), brand = "MIX", tapeType = "90 MIN",
        )

        // After the classic tapes of the 1980s and 1990s: their colors, bands and rings, under Groovelight's own name.

        /** Black with gold print and gold rings around the hubs: the limited editions of the high bias tapes. */
        val BLACK_GOLD = CassetteDesign(
            id = "6B1C1C8E-0001-4C55-9C11-000000000006", name = "Black Gold",
            shellColor = c("#161618"), detailColor = c("#3C3C40"),
            label = Label(c("#00000000"), emptyList(), c("#D6AE5C"), handwritten = false, bands = listOf(Band(c("#D6AE5C"), 0.43f, 0.012f), Band(c("#232120"), 0.46f, 0.34f), Band(c("#D6AE5C"), 0.8f, 0.012f))),
            reels = Reels(c("#E8E6E0"), c("#2A1D14"), c("#C9A04A")), brand = "GROOVELIGHT GX 60", tapeType = "HIGH POSITION · TYPE II", side = "B",
        )
        /** Clear blue plastic, the whole reels showing: the chrome tapes of the late 1980s. */
        val ICE_CHROME = CassetteDesign(
            id = "6B1C1C8E-0001-4C55-9C11-000000000007", name = "Ice Chrome",
            shellColor = c("#B9CCDD"), shellClarity = 0.7f, detailColor = c("#E3EBF2"),
            label = Label(c("#FFFFFF14"), emptyList(), c("#23356E"), handwritten = false, bands = listOf(Band(c("#3D5FA8"), 0.88f, 0.06f))),
            reels = Reels(c("#F5F7FA"), c("#3A2A20")), brand = "GROOVELIGHT CR 90", tapeType = "CHROME · TYPE II",
        )
        /** Midnight blue with silver print and silver rings: the professional high bias tapes. */
        val MIDNIGHT_PRO = CassetteDesign(
            id = "6B1C1C8E-0001-4C55-9C11-000000000008", name = "Midnight Pro",
            shellColor = c("#1A1F30"), detailColor = c("#59607A"),
            label = Label(c("#00000000"), emptyList(), c("#D5D9E2"), handwritten = false, bands = listOf(Band(c("#262C42"), 0.46f, 0.34f), Band(c("#AEB3BF"), 0.82f, 0.01f))),
            reels = Reels(c("#E9EBEF"), c("#241A14"), c("#BFC4CE")), brand = "GROOVELIGHT PRO 90", tapeType = "SUPER ENERGY · TYPE II",
        )
        /** Black with a white strip to write on and a red band across the window. */
        val RED_BAND = CassetteDesign(
            id = "6B1C1C8E-0001-4C55-9C11-000000000009", name = "Red Band",
            shellColor = c("#121214"), detailColor = c("#3A3A3E"),
            label = Label(c("#00000000"), emptyList(), c("#F1EEE6"), handwritten = true, bands = listOf(Band(c("#B5302A"), 0.44f, 0.38f), Band(c("#F1EEE6"), 0.86f, 0.1f)), writing = Writing(c("#F1EEE6"), c("#1E2A5A"))),
            reels = Reels(c("#EDEDED"), c("#2B1E16")), brand = "GROOVELIGHT S 60", tapeType = "TYPE II · HIGH BIAS",
        )
        /** Smoked plastic, a gray strip to write on and lavender print. */
        val SMOKED_LAVENDER = CassetteDesign(
            id = "6B1C1C8E-0001-4C55-9C11-00000000000A", name = "Smoked Lavender",
            shellColor = c("#33353B"), shellClarity = 0.5f, detailColor = c("#6E7078"),
            label = Label(c("#00000000"), emptyList(), c("#B7A2E8"), handwritten = true, writing = Writing(c("#CFCFCB"), c("#26262A"))),
            reels = Reels(c("#F0F0F0"), c("#2A1E16")), brand = "GROOVELIGHT LX", tapeType = "100 MINUTES",
        )
        /** Graphite with a wide clear window and red rings around the hubs. */
        val GRAPHITE_WINDOW = CassetteDesign(
            id = "6B1C1C8E-0001-4C55-9C11-00000000000B", name = "Graphite Window",
            shellColor = c("#3B3C40"), shellClarity = 0.3f, detailColor = c("#6A6B70"),
            label = Label(c("#00000000"), emptyList(), c("#E0E0DE"), handwritten = true, writing = Writing(c("#ECEBE6"), c("#222222"))),
            reels = Reels(c("#F2F2F2"), c("#2B1E16"), c("#C23B32")), brand = "GROOVELIGHT F 90", tapeType = "IEC II · HIGH POSITION",
            geometry = CassetteGeometry.STANDARD.copy(window = CassetteGeometry.Rect(0.2f, 0.35f, 0.6f, 0.24f)),
        )
        /** Deep green with a cream strip to write on and gold pinstripes. */
        val GREEN_PINSTRIPE = CassetteDesign(
            id = "6B1C1C8E-0001-4C55-9C11-00000000000C", name = "Green Pinstripe",
            shellColor = c("#1C2520"), detailColor = c("#4A564F"),
            label = Label(c("#00000000"), emptyList(), c("#E9E4D0"), handwritten = true, bands = listOf(Band(c("#C8A55A"), 0.8f, 0.018f), Band(c("#EDE8D8"), 0.835f, 0.012f), Band(c("#C8A55A"), 0.86f, 0.018f)), writing = Writing(c("#F2F0E6"), c("#1D2A22"))),
            reels = Reels(c("#F0F0EC"), c("#2A1D14")), brand = "GROOVELIGHT X 90", tapeType = "HIGH BIAS · 70µs EQ",
        )
        /** Smoked clear plastic, a white strip to write on and a bronze band. */
        val BRONZE_CLEAR = CassetteDesign(
            id = "6B1C1C8E-0001-4C55-9C11-00000000000D", name = "Bronze Clear",
            shellColor = c("#5E5A57"), shellClarity = 0.55f, detailColor = c("#B9B2AA"),
            label = Label(c("#00000000"), emptyList(), c("#F4F2EE"), handwritten = false, bands = listOf(Band(c("#B06A33"), 0.84f, 0.1f)), writing = Writing(c("#F4F2EE"), c("#333333"))),
            reels = Reels(c("#F2F2F2"), c("#3A2A20")), brand = "GROOVELIGHT", tapeType = "CHROME II · 100",
        )
        /** Charcoal with a black band and white print, on side B. */
        val CHARCOAL = CassetteDesign(
            id = "6B1C1C8E-0001-4C55-9C11-00000000000E", name = "Charcoal",
            shellColor = c("#2D2E30"), detailColor = c("#4D4E52"),
            label = Label(c("#00000000"), emptyList(), c("#E6E6E6"), handwritten = false, bands = listOf(Band(c("#111111"), 0.78f, 0.1f), Band(c("#E6E6E6"), 0.8f, 0.006f))),
            reels = Reels(c("#E8E8E8"), c("#2A1D14")), brand = "GROOVELIGHT TX 90", tapeType = "HIGH BIAS · 70µs EQ", side = "B",
        )

        /** The designs that come with the app (copied to be changed). */
        val BUILT_IN = listOf(CLASSIC, CHROME, CLEAR, METAL, MIXTAPE, BLACK_GOLD, ICE_CHROME, MIDNIGHT_PRO, RED_BAND, SMOKED_LAVENDER, GRAPHITE_WINDOW, GREEN_PINSTRIPE, BRONZE_CLEAR, CHARCOAL)
    }
}

/** "#RRGGBB", or "#RRGGBBAA" when not opaque. */
fun Color.hex(): String {
    val argb = toArgb()
    val rgb = String.format(Locale.ROOT, "#%02X%02X%02X", argb shr 16 and 0xFF, argb shr 8 and 0xFF, argb and 0xFF)
    val alpha = argb ushr 24
    return if (alpha == 0xFF) rgb else rgb + String.format(Locale.ROOT, "%02X", alpha)
}

/** Where a cassette's parts are, relative to the whole (x across its width, y down its height). */
data class CassetteGeometry(
    val aspectRatio: Float,
    val leftReel: Point,
    val rightReel: Point,
    /** A full reel's radius and the bare hub's, relative to the width. */
    val reelRadius: Float,
    val hubRadius: Float,
    val window: Rect,
    val label: Rect,
) {
    data class Point(val x: Float, val y: Float)
    data class Rect(val x: Float, val y: Float, val width: Float, val height: Float)

    fun toJson(): JSONObject = JSONObject().apply {
        put("aspectRatio", aspectRatio.toDouble())
        put("leftReel", JSONObject().put("x", leftReel.x.toDouble()).put("y", leftReel.y.toDouble()))
        put("rightReel", JSONObject().put("x", rightReel.x.toDouble()).put("y", rightReel.y.toDouble()))
        put("reelRadius", reelRadius.toDouble())
        put("hubRadius", hubRadius.toDouble())
        put("window", window.json())
        put("label", label.json())
    }

    private fun Rect.json() = JSONObject().put("x", x.toDouble()).put("y", y.toDouble()).put("width", width.toDouble()).put("height", height.toDouble())

    companion object {
        /** A compact cassette (100.4 x 63.8 mm), its reels 42.5 mm apart: the template's places. */
        val STANDARD = CassetteGeometry(
            aspectRatio = 100.4f / 63.8f,
            leftReel = Point(0.288f, 0.47f),
            rightReel = Point(0.712f, 0.47f),
            reelRadius = 0.165f,
            hubRadius = 0.06f,
            window = Rect(0.33f, 0.38f, 0.34f, 0.18f),
            label = Rect(0.075f, 0.09f, 0.85f, 0.6f),
        )

        fun fromJson(json: JSONObject): CassetteGeometry {
            val s = STANDARD
            fun point(key: String, default: Point) = json.optJSONObject(key)?.let {
                Point(it.optDouble("x", default.x.toDouble()).toFloat(), it.optDouble("y", default.y.toDouble()).toFloat())
            } ?: default
            fun rect(key: String, default: Rect) = json.optJSONObject(key)?.let {
                Rect(it.optDouble("x", default.x.toDouble()).toFloat(), it.optDouble("y", default.y.toDouble()).toFloat(),
                    it.optDouble("width", default.width.toDouble()).toFloat(), it.optDouble("height", default.height.toDouble()).toFloat())
            } ?: default
            return CassetteGeometry(
                aspectRatio = json.optDouble("aspectRatio", s.aspectRatio.toDouble()).toFloat().takeIf { it > 0.2f && it < 5f } ?: s.aspectRatio,
                leftReel = point("leftReel", s.leftReel),
                rightReel = point("rightReel", s.rightReel),
                reelRadius = json.optDouble("reelRadius", s.reelRadius.toDouble()).toFloat(),
                hubRadius = json.optDouble("hubRadius", s.hubRadius.toDouble()).toFloat(),
                window = rect("window", s.window),
                label = rect("label", s.label),
            )
        }
    }
}
