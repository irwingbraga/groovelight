plugins {
    id("com.android.library")
}

// Playback: the Media3 session service (notification, lock screen, headset and player buttons) and what it reports
// about the audio path (decoder, formats in and out).
android {
    namespace = "dev.irwingbraga.groovelight.playback"
    compileSdk = 37
    defaultConfig { minSdk = 31 }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

dependencies {
    api(libs.media3.exoplayer)
    api(libs.media3.session)
    api(libs.coroutines.android)
    implementation(libs.core.ktx)
    testImplementation(libs.junit)
    testImplementation(libs.json)
}
