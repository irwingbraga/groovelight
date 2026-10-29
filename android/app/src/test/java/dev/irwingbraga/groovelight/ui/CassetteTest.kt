package dev.irwingbraga.groovelight.ui

import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Size
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.io.File
import java.nio.file.Files
import kotlin.math.abs

@RunWith(RobolectricTestRunner::class)
@Config(application = android.app.Application::class)
class CassetteTest {
    private fun folder(): File = Files.createTempDirectory("cassettes").toFile()

    /** A design as GroovelightKit writes it on the Mac and the iPhone (sorted keys, pretty printed). */
    private val fromMac = """
        {
          "brand" : "GROOVELIGHT",
          "detailColor" : "#A9AAB0",
          "format" : 1,
          "id" : "0A8C2D51-5E9B-4C4B-8F41-7E1C2B9D0E11",
          "label" : {
            "background" : "#1F4E9C",
            "handwritten" : false,
            "showsArtwork" : true,
            "showsText" : true,
            "stripes" : [ "#E9EEF7" ],
            "textColor" : "#FFFFFF"
          },
          "name" : "Blue",
          "reels" : { "hubColor" : "#FFFFFF", "tapeColor" : "#2B2018" },
          "shellClarity" : 0.4,
          "shellColor" : "#ECECEA80",
          "side" : "B",
          "tapeType" : "TYPE II · CrO2",
          "geometry" : {
            "aspectRatio" : 1.6, "hubRadius" : 0.05, "reelRadius" : 0.15,
            "leftReel" : { "x" : 0.3, "y" : 0.5 }, "rightReel" : { "x" : 0.7, "y" : 0.5 },
            "window" : { "x" : 0.35, "y" : 0.4, "width" : 0.3, "height" : 0.2 },
            "label" : { "x" : 0.1, "y" : 0.1, "width" : 0.8, "height" : 0.55 }
          }
        }
    """.trimIndent()

    @Test
    fun readsTheMacsDesigns() {
        val design = CassetteDesign.fromJson(JSONObject(fromMac))
        assertEquals("0A8C2D51-5E9B-4C4B-8F41-7E1C2B9D0E11", design.id)
        assertEquals("Blue", design.name)
        assertEquals("#ECECEA80", design.shellColor.hex())
        assertEquals(0.4f, design.shellClarity, 0.001f)
        assertEquals(listOf("#E9EEF7"), design.label.stripes.map { it.hex() })
        assertTrue(design.label.showsArtwork)
        assertEquals("B", design.side)
        assertEquals(0.3f, design.resolvedGeometry.leftReel.x, 0.001f)
        // Written again and read back, it is the same design.
        assertEquals(design, CassetteDesign.fromJson(design.toJson()))
    }

    @Test
    fun builtInDesignsRoundTrip() {
        CassetteDesign.BUILT_IN.forEach { assertEquals(it, CassetteDesign.fromJson(it.toJson())) }
    }

    /** A design written by hand with only some fields opens, the rest from Classic, the clarity kept in range. */
    @Test
    fun handWrittenDesignsOpen() {
        val design = CassetteDesign.fromJson(JSONObject("""{"name": "Mine", "shellColor": "#00FF00", "shellClarity": 3, "label": {"background": "#FFFFFF"}}"""))
        assertEquals("#00FF00", design.shellColor.hex())
        assertEquals(0.8f, design.shellClarity)
        assertEquals("#FFFFFF", design.label.background.hex())
        assertTrue(design.label.showsText)
        assertEquals(CassetteDesign.CLASSIC.reels, design.reels)
        assertEquals(CassetteGeometry.STANDARD, design.resolvedGeometry)
        assertNull(CassetteDesign.parseHex("#12"))
    }

    @Test
    fun designsTravelAsZips() {
        Cassettes.initForTest(folder())
        val design = Cassettes.duplicate(CassetteDesign.CHROME, "Shared")
        val withPicture = Cassettes.setPicture(design, Cassettes.Picture.SHELL, byteArrayOf(1, 2, 3).inputStream())
        assertNotNull(Cassettes.pictureFile(withPicture, Cassettes.Picture.SHELL))
        val zip = File(folder(), "Shared.cassette.zip")
        Cassettes.zip(withPicture, zip)

        // Elsewhere it keeps its id and its picture; imported again here, it is a copy.
        Cassettes.initForTest(folder())
        val imported = Cassettes.importZip(zip.inputStream())
        assertEquals(withPicture.id, imported.id)
        assertNotNull(Cassettes.pictureFile(imported, Cassettes.Picture.SHELL))
        val again = Cassettes.importZip(zip.inputStream())
        assertNotEquals(imported.id, again.id)
        assertEquals(2, Cassettes.custom.value.size)

        Cassettes.delete(again)
        assertEquals(1, Cassettes.custom.value.size)
    }

    @Test
    fun reelsWindTheTape() {
        val geometry = CassetteGeometry.STANDARD
        fun at(time: Double) = ReelState.of(geometry, 1000f, SkinPlayback("", "", true, time, 200.0))
        val start = at(0.0)
        val end = at(200.0)
        assertTrue(start.leftRadius > start.rightRadius)
        assertEquals(start.rightRadius, end.leftRadius, 0.01f)
        // At the start the bare right hub turns half a turn a second.
        assertEquals(180f, at(1.0).rightAngle, 6f)
        // At the end the full right reel turns slower than the near-bare left one.
        val late = at(199.0)
        assertTrue(end.rightAngle - late.rightAngle < end.leftAngle - late.leftAngle)
    }

    @Test
    fun tonearmGoesInOverTheSong() {
        val side = 1000f
        val center = Offset(side * 0.43f, side * 0.5f)
        val outer = tonearmAngle(side, center, side * 0.38f * 0.95f)
        val inner = tonearmAngle(side, center, side * 0.38f * 0.4f)
        assertTrue(outer > 0f && inner > outer)
        assertTrue(abs(inner - outer) > 5f)
    }

    /** One above the other on a phone and an open Z Fold, side by side on a wide screen, on either side of a half-open fold. */
    @Test
    fun decksFollowTheScreenAndTheFold() {
        val phone = DeckRegions.of(Size(1080f, 2200f), 30f, null, 1f)
        assertTrue(phone.panel.top > phone.stage.bottom)
        val open = DeckRegions.of(Size(1968f, 2000f), 30f, null, 1f)
        assertTrue(open.panel.top > open.stage.bottom)
        val wide = DeckRegions.of(Size(2400f, 1080f), 30f, null, 1f)
        assertTrue(wide.panel.left > wide.stage.right)
        val hinge = Rect(970f, 0f, 1000f, 2000f)
        val book = DeckRegions.of(Size(1968f, 2000f), 30f, hinge, 1f)
        assertTrue(book.stage.right <= hinge.left && book.panel.left >= hinge.right)
        val level = Rect(0f, 990f, 1968f, 1010f)
        val tabletop = DeckRegions.of(Size(1968f, 2000f), 30f, level, 1f)
        assertTrue(tabletop.stage.bottom <= level.top && tabletop.panel.top >= level.bottom)
    }

    /** The VU meters read the music's level as on the Mac and the iPhone: silence rests, -12 dBFS is 0 VU, louder goes into the red. */
    @Test
    fun vuMetersFollowTheLevel() {
        assertEquals(0.0, vuPosition(0f), 0.0)
        assertEquals(0.78, vuPosition(Math.pow(10.0, -12.0 / 20).toFloat()), 0.001)
        assertTrue(vuPosition(Math.pow(10.0, -22.0 / 20).toFloat()) < vuPosition(Math.pow(10.0, -15.0 / 20).toFloat()))
        assertTrue(vuPosition(1f) > 1.0)
    }
}
