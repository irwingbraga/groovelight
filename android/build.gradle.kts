plugins {
    id("com.android.application") version "9.3.3" apply false
    id("com.android.library") version "9.3.3" apply false
    // Android Gradle Plugin 9 compiles Kotlin itself; this only picks the Kotlin version it uses.
    id("org.jetbrains.kotlin.android") version "2.3.10" apply false
    id("org.jetbrains.kotlin.plugin.compose") version "2.3.10" apply false
    id("com.google.devtools.ksp") version "2.3.9" apply false
}
