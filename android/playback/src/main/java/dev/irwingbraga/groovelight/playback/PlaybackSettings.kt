package dev.irwingbraga.groovelight.playback

import android.content.Context
import android.content.SharedPreferences
import androidx.core.content.edit
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import org.json.JSONArray
import org.json.JSONObject

/**
 * What changes the sound, kept in preferences and shared by the screens and the playback service (one process): the
 * equalizer (on or off, its curve, saved presets), volume normalization and bit-perfect output. The audio thread reads
 * [activeCurve] and [bitPerfectWanted] without locking.
 */
object PlaybackSettings {
    enum class Normalization(val label: String) { TRACK("Song"), ALBUM("Album"), OFF("Off") }

    private lateinit var preferences: SharedPreferences

    private val _eqEnabled = MutableStateFlow(false)
    private val _curve = MutableStateFlow(EqPreset.FLAT)
    private val _autoPreamp = MutableStateFlow(true)
    private val _userPresets = MutableStateFlow(emptyList<EqPreset>())
    private val _normalization = MutableStateFlow(Normalization.TRACK)
    private val _bitPerfect = MutableStateFlow(false)
    private val _bitPerfectActive = MutableStateFlow(false)
    private val _crossfade = MutableStateFlow(0)

    val eqEnabled: StateFlow<Boolean> = _eqEnabled.asStateFlow()
    val curve: StateFlow<EqPreset> = _curve.asStateFlow()
    val autoPreamp: StateFlow<Boolean> = _autoPreamp.asStateFlow()
    /** Presets saved on this device (the Mac's come with the library). */
    val userPresets: StateFlow<List<EqPreset>> = _userPresets.asStateFlow()
    val normalization: StateFlow<Normalization> = _normalization.asStateFlow()
    /** Whether to play bit-perfect to a USB DAC when one is connected (Android 14 and later). */
    val bitPerfect: StateFlow<Boolean> = _bitPerfect.asStateFlow()
    /** Whether the song playing goes out bit-perfect (the DAC accepted its format). */
    val bitPerfectActive: StateFlow<Boolean> = _bitPerfectActive.asStateFlow()
    /** Seconds songs overlap, fading one into the next (0: none, songs follow gapless). */
    val crossfade: StateFlow<Int> = _crossfade.asStateFlow()

    /** The curve the audio thread applies, or null when the equalizer is off. */
    @Volatile var activeCurve: EqPreset? = null
        private set

    @Volatile var bitPerfectWanted = false
        private set

    fun init(context: Context) {
        if (::preferences.isInitialized) return
        preferences = context.applicationContext.getSharedPreferences("sound", Context.MODE_PRIVATE)
        _eqEnabled.value = preferences.getBoolean("eq.enabled", false)
        _curve.value = preferences.getString("eq.curve", null)?.let { runCatching { EqPreset.fromJson(JSONObject(it)) }.getOrNull() } ?: EqPreset.FLAT
        _autoPreamp.value = preferences.getBoolean("eq.autoPreamp", true)
        _userPresets.value = preferences.getString("eq.presets", null)?.let { text ->
            runCatching { JSONArray(text).let { array -> (0 until array.length()).map { EqPreset.fromJson(array.getJSONObject(it)) } } }.getOrNull()
        } ?: emptyList()
        _normalization.value = preferences.getString("normalization", null)?.let { runCatching { Normalization.valueOf(it) }.getOrNull() }
            ?: Normalization.TRACK
        _bitPerfect.value = preferences.getBoolean("bitPerfect", false)
        _crossfade.value = preferences.getInt("crossfade", 0)
        refresh()
    }

    fun setEqEnabled(enabled: Boolean) {
        _eqEnabled.value = enabled
        preferences.edit { putBoolean("eq.enabled", enabled) }
        refresh()
    }

    /** Uses a curve (a preset picked, or one being edited), with the auto preamp when it is on. */
    fun setCurve(preset: EqPreset) {
        val curve = if (_autoPreamp.value) preset.copy(preamp = EqMath.autoPreamp(preset.bands)) else preset
        _curve.value = curve
        preferences.edit { putString("eq.curve", curve.toJson().toString()) }
        refresh()
    }

    /** Changes one band of the curve; a built-in preset edited becomes "Custom", as on the Mac. */
    fun updateBand(index: Int, change: (EqBand) -> EqBand) {
        val current = _curve.value
        val band = current.bands.getOrNull(index) ?: return
        val changed = change(band)
        if (changed == band) return
        val name = if (EqPreset.isBuiltInName(current.name) || current.name.isEmpty()) "Custom" else current.name
        setCurve(current.copy(name = name, bands = current.bands.toMutableList().also { it[index] = changed }))
    }

    fun setPreamp(value: Double) {
        setAutoPreamp(false)
        setCurve(_curve.value.copy(preamp = value.coerceIn(EqMath.PREAMP_RANGE)))
    }

    fun setAutoPreamp(enabled: Boolean) {
        _autoPreamp.value = enabled
        preferences.edit { putBoolean("eq.autoPreamp", enabled) }
        if (enabled) setCurve(_curve.value)
    }

    fun saveCurve(name: String) {
        val saved = _curve.value.copy(name = name)
        _userPresets.value = _userPresets.value.filter { it.name != name } + saved
        _curve.value = saved
        persistPresets()
        preferences.edit { putString("eq.curve", saved.toJson().toString()) }
    }

    fun deletePreset(name: String) {
        _userPresets.value = _userPresets.value.filter { it.name != name }
        persistPresets()
    }

    /** An AutoEq / Equalizer APO file: saved as a preset, used at once with its own preamp. */
    fun importPreset(preset: EqPreset) {
        _userPresets.value = _userPresets.value.filter { it.name != preset.name } + preset
        persistPresets()
        setAutoPreamp(false)
        setCurve(preset)
        setEqEnabled(true)
    }

    fun setNormalization(mode: Normalization) {
        _normalization.value = mode
        preferences.edit { putString("normalization", mode.name) }
    }

    fun setBitPerfect(enabled: Boolean) {
        _bitPerfect.value = enabled
        preferences.edit { putBoolean("bitPerfect", enabled) }
        refresh()
    }

    fun setCrossfade(seconds: Int) {
        _crossfade.value = seconds.coerceIn(0, 12)
        preferences.edit { putInt("crossfade", _crossfade.value) }
    }

    internal fun setBitPerfectActive(active: Boolean) {
        _bitPerfectActive.value = active
    }

    private fun persistPresets() {
        preferences.edit { putString("eq.presets", JSONArray().apply { _userPresets.value.forEach { put(it.toJson()) } }.toString()) }
    }

    private fun refresh() {
        activeCurve = if (_eqEnabled.value) _curve.value else null
        bitPerfectWanted = _bitPerfect.value
    }
}
