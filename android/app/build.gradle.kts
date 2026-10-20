import com.android.build.api.artifact.SingleArtifact
import javax.xml.parsers.DocumentBuilderFactory

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.plugin.compose")
}

// The player is built in when -Pplayer=true is passed (always in debug builds), until it is ready for releases.
val playerInReleases = (project.findProperty("player") as String?) == "true"

android {
    namespace = "dev.irwingbraga.groovelight"
    compileSdk = 37

    defaultConfig {
        // Groovelight Sync's id: the app installs over it, keeping the pairing, the folder and the scheduled syncs.
        applicationId = "dev.irwingbraga.groovelight.sync"
        minSdk = 31
        targetSdk = 36
        // Releases pass the tag and the run number (-PversionName=0.2.0 -PversionCode=42).
        versionCode = (project.findProperty("versionCode") as String?)?.toInt() ?: 1
        versionName = project.findProperty("versionName") as String? ?: "0.1.0"
    }

    // Where the app is distributed: GitHub releases (APK) or Google Play (App Bundle). Play does not allow an app to
    // update itself from elsewhere, so the GitHub build alone will carry the update check (phase 5).
    flavorDimensions += "distribution"
    productFlavors {
        create("github") {
            dimension = "distribution"
            buildConfigField("boolean", "SELF_UPDATE", "true")
        }
        create("play") {
            dimension = "distribution"
            buildConfigField("boolean", "SELF_UPDATE", "false")
        }
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
        debug {
            buildConfigField("boolean", "PLAYER", "true")
            resValue("string", "app_name", "Groovelight")
        }
        release {
            isMinifyEnabled = false
            buildConfigField("boolean", "PLAYER", playerInReleases.toString())
            resValue("string", "app_name", if (playerInReleases) "Groovelight" else "Groovelight Sync")
            // Local builds without the release key are signed with the debug key (installable for testing).
            signingConfig = if (System.getenv("GROOVELIGHT_KEYSTORE") != null) signingConfigs.getByName("release")
                else signingConfigs.getByName("debug")
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    buildFeatures {
        compose = true
        buildConfig = true
        resValues = true
    }
    lint {
        abortOnError = true
        checkDependencies = true
    }
}

dependencies {
    implementation(project(":sync"))
    implementation(project(":library"))
    implementation(project(":playback"))
    implementation(platform(libs.compose.bom))
    implementation(libs.compose.material3)
    implementation(libs.compose.ui)
    implementation(libs.activity.compose)
    implementation(libs.lifecycle.viewmodel.compose)
    implementation(libs.lifecycle.runtime.compose)
    implementation(libs.documentfile)
    implementation(libs.coil.compose)
    implementation(libs.compose.navigation.suite)
    implementation(libs.navigation3.ui)
    implementation(libs.palette)
    testImplementation(libs.junit)
}

/**
 * Google Play readiness: the Play build's merged manifest asks only for the permissions below, and targets the API level
 * Play requires (raised every August). Runs in CI with every release, so the app could be submitted at any time.
 */
abstract class CheckPlayPolicy : DefaultTask() {
    @get:InputFile abstract val manifest: RegularFileProperty
    @get:Input abstract val allowedPermissions: ListProperty<String>
    @get:Input abstract val minimumTargetSdk: Property<Int>

    @TaskAction
    fun check() {
        val document = DocumentBuilderFactory.newInstance().apply { isNamespaceAware = true }.newDocumentBuilder().parse(manifest.get().asFile)
        val android = "http://schemas.android.com/apk/res/android"
        val requested = (0 until document.getElementsByTagName("uses-permission").length).map {
            (document.getElementsByTagName("uses-permission").item(it) as org.w3c.dom.Element).getAttributeNS(android, "name")
        }
        val allowed = allowedPermissions.get()
        // AndroidX adds a signature permission of the app's own for its receivers.
        val unexpected = requested.filter { it !in allowed && !it.endsWith(".DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION") }
        val target = (document.getElementsByTagName("uses-sdk").item(0) as org.w3c.dom.Element?)?.getAttributeNS(android, "targetSdkVersion")?.toIntOrNull()
        val problems = buildList {
            if (unexpected.isNotEmpty()) add("Permissions not on the Play list: ${unexpected.joinToString()} (add them to allowedPermissions with a reason, or remove them)")
            if (target == null || target < minimumTargetSdk.get()) add("targetSdkVersion $target is below ${minimumTargetSdk.get()}, the level Google Play requires")
        }
        if (problems.isNotEmpty()) throw GradleException(problems.joinToString("\n"))
        logger.lifecycle("Play policy: ${requested.size} permissions allowed, targetSdkVersion $target")
    }
}

androidComponents {
    onVariants(selector().withFlavor("distribution" to "play")) { variant ->
        tasks.register<CheckPlayPolicy>("check${variant.name.replaceFirstChar(Char::uppercase)}Policy") {
            manifest.set(variant.artifacts.get(SingleArtifact.MERGED_MANIFEST))
            minimumTargetSdk.set(36)
            allowedPermissions.set(listOf(
                "android.permission.INTERNET", // talking to the Mac on the local network
                "android.permission.ACCESS_NETWORK_STATE", // syncing on Wi-Fi only
                "android.permission.ACCESS_WIFI_STATE",
                "android.permission.CHANGE_WIFI_MULTICAST_STATE", // finding the Mac with Bonjour
                "android.permission.FOREGROUND_SERVICE",
                "android.permission.FOREGROUND_SERVICE_DATA_SYNC", // syncs
                "android.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK", // playing music
                "android.permission.POST_NOTIFICATIONS", // sync progress and the player's notification
                "android.permission.WAKE_LOCK", // playing and syncing with the screen off
                "android.permission.RECEIVE_BOOT_COMPLETED", // WorkManager: automatic syncs after a restart
                "android.permission.MODIFY_AUDIO_SETTINGS", // bit-perfect output: the USB DAC's mixer set to the song's format
            ))
        }
    }
}
