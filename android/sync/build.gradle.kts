plugins {
    id("com.android.library")
}

// Pairing with the Mac, signed requests, and the sync of the music folder (Groovelight Sync's engine).
android {
    namespace = "dev.irwingbraga.groovelight.sync"
    compileSdk = 37
    defaultConfig { minSdk = 31 }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

dependencies {
    implementation(libs.core.ktx)
    api(libs.work.runtime)
    implementation(libs.documentfile)
    api(libs.coroutines.android)
    testImplementation(libs.junit)
    testImplementation(libs.json)
}
