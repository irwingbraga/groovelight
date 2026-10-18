package dev.irwingbraga.groovelight.ui

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color

// Material 3 tonal palettes from Groovelight's brand blue (the Mac's accent color: #2A4CA0, #6F98E8 in dark mode).

private val Light = lightColorScheme(
    primary = Color(0xFF2A4CA0), onPrimary = Color.White,
    primaryContainer = Color(0xFFDBE1FF), onPrimaryContainer = Color(0xFF00174B),
    secondary = Color(0xFF585E71), onSecondary = Color.White,
    secondaryContainer = Color(0xFFDCE2F9), onSecondaryContainer = Color(0xFF151B2C),
    tertiary = Color(0xFF735471), onTertiary = Color.White,
    tertiaryContainer = Color(0xFFFED7F9), onTertiaryContainer = Color(0xFF2B122B),
    background = Color(0xFFFAF8FF), onBackground = Color(0xFF1A1B21),
    surface = Color(0xFFFAF8FF), onSurface = Color(0xFF1A1B21),
    surfaceVariant = Color(0xFFE2E2EC), onSurfaceVariant = Color(0xFF45464F),
    surfaceContainerLowest = Color.White, surfaceContainerLow = Color(0xFFF4F3FA), surfaceContainer = Color(0xFFEEEDF4),
    surfaceContainerHigh = Color(0xFFE8E7EF), surfaceContainerHighest = Color(0xFFE3E2E9),
    outline = Color(0xFF757680), outlineVariant = Color(0xFFC5C6D0),
    inverseSurface = Color(0xFF2F3036), inverseOnSurface = Color(0xFFF1F0F7), inversePrimary = Color(0xFFB4C5FF),
)

private val Dark = darkColorScheme(
    primary = Color(0xFFB4C5FF), onPrimary = Color(0xFF002A78),
    primaryContainer = Color(0xFF2A4CA0), onPrimaryContainer = Color(0xFFDBE1FF),
    secondary = Color(0xFFC0C6DC), onSecondary = Color(0xFF2A3042),
    secondaryContainer = Color(0xFF404659), onSecondaryContainer = Color(0xFFDCE2F9),
    tertiary = Color(0xFFE1BBDC), onTertiary = Color(0xFF422741),
    tertiaryContainer = Color(0xFF5A3D58), onTertiaryContainer = Color(0xFFFED7F9),
    background = Color(0xFF121318), onBackground = Color(0xFFE3E2E9),
    surface = Color(0xFF121318), onSurface = Color(0xFFE3E2E9),
    surfaceVariant = Color(0xFF45464F), onSurfaceVariant = Color(0xFFC5C6D0),
    surfaceContainerLowest = Color(0xFF0D0E13), surfaceContainerLow = Color(0xFF1A1B21), surfaceContainer = Color(0xFF1E1F25),
    surfaceContainerHigh = Color(0xFF292A2F), surfaceContainerHighest = Color(0xFF34343A),
    outline = Color(0xFF8F909A), outlineVariant = Color(0xFF45464F),
    inverseSurface = Color(0xFFE3E2E9), inverseOnSurface = Color(0xFF2F3036), inversePrimary = Color(0xFF2A4CA0),
)

/** Light and dark follow the system. */
@Composable
fun GroovelightTheme(dark: Boolean = isSystemInDarkTheme(), content: @Composable () -> Unit) {
    MaterialTheme(colorScheme = if (dark) Dark else Light, content = content)
}
