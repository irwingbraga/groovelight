plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

android {
    namespace = "dev.irwingbraga.groovelight.sync"
    compileSdk = 35

    defaultConfig {
        applicationId = "dev.irwingbraga.groovelight.sync"
        minSdk = 31
        targetSdk = 35
        // Releases pass the tag and the run number (-PversionName=0.2.0 -PversionCode=42).
        versionCode = (project.findProperty("versionCode") as String?)?.toInt() ?: 1
        versionName = project.findProperty("versionName") as String? ?: "0.1.0"
    }

    signingConfigs {
        // The release key (CI sets these from repository secrets): every release must be signed with the same key,
        // or Android refuses to install it over the previous one.
        create("release") {
            val keystore = System.getenv("GROOVELIGHT_KEYSTORE")
            if (keystore != null) {
                storeFile = file(keystore)
                storePassword = System.getenv("GROOVELIGHT_KEYSTORE_PASSWORD")
                keyAlias = System.getenv("GROOVELIGHT_KEY_ALIAS")
                keyPassword = System.getenv("GROOVELIGHT_KEYSTORE_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            // Local builds without the release key are signed with the debug key (installable for testing).
            signingConfig = if (System.getenv("GROOVELIGHT_KEYSTORE") != null) signingConfigs.getByName("release")
                else signingConfigs.getByName("debug")
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions {
        jvmTarget = "17"
    }
    buildFeatures {
        compose = true
    }
}

dependencies {
    val composeBom = platform("androidx.compose:compose-bom:2024.12.01")
    implementation(composeBom)
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.material:material-icons-core")
    implementation("androidx.activity:activity-compose:1.9.3")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.8.7")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.8.7")
    implementation("androidx.work:work-runtime-ktx:2.10.0")
    implementation("androidx.documentfile:documentfile:1.0.1")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0")
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.json:json:20240303")
}
