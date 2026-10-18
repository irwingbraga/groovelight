plugins {
    id("com.android.library")
    id("com.google.devtools.ksp")
}

// The library on the device: Room database filled from the Mac's library snapshot (protocol v2).
android {
    namespace = "dev.irwingbraga.groovelight.library"
    compileSdk = 37
    defaultConfig { minSdk = 31 }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    testOptions { unitTests.isIncludeAndroidResources = true }
}

// Each schema version is kept in the repository, so migrations can be written and tested against it.
ksp { arg("room.schemaLocation", "$projectDir/schemas") }

dependencies {
    api(libs.room.runtime)
    implementation(libs.room.ktx)
    ksp(libs.room.compiler)
    api(libs.coroutines.android)
    testImplementation(libs.junit)
    testImplementation(libs.robolectric)
    testImplementation(libs.androidx.test.core)
    testImplementation(libs.coroutines.test)
}
