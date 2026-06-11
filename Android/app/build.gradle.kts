import java.io.FileInputStream
import java.util.Properties

// Shared upload-key signing secrets live outside any repo at ~/.android-keystores/keystore.properties
// (storeFile is an absolute path; storePassword / keyAlias / keyPassword). Reused across all the
// Harmolo Android apps and never committed. Loaded here so `release` produces a Play-uploadable AAB.
val keystorePropertiesFile = File(System.getProperty("user.home"), ".android-keystores/keystore.properties")
val keystoreProperties = Properties().apply {
    if (keystorePropertiesFile.exists()) {
        FileInputStream(keystorePropertiesFile).use { load(it) }
    }
}

// versionCode is derived from the git commit count so it strictly increases with every commit and
// never collides with a code already consumed on Play (manual bumps had already burned 1 and 2).
// Falls back to 1 outside a git checkout (e.g. a source export).
val gitCommitCount: Int = providers.exec {
    commandLine("git", "rev-list", "--count", "HEAD")
}.standardOutput.asText.map { it.trim().toIntOrNull() ?: 1 }.getOrElse(1)

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
    id("com.mikepenz.aboutlibraries.plugin")
    id("com.google.gms.google-services")
    id("com.google.firebase.crashlytics")
    id("io.github.takahirom.roborazzi") version "1.32.0"
}

android {
    namespace = "com.keynumber.folino"
    compileSdk = 35

    defaultConfig {
        // Play package identity (Harmolo developer account). Kept distinct from `namespace`
        // (com.keynumber.folino), which stays the code/JNI package and must not change — the
        // eager-loaded JNI class names and generated wirelet bridges are keyed to it.
        applicationId = "com.harmolo.folino"
        minSdk = 28
        targetSdk = 35
        versionCode = gitCommitCount
        versionName = "1.0.0"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        ndk { abiFilters += listOf("arm64-v8a", "x86_64") }
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        // Route screenshot capture output through the AndroidX Test Storage service so AGP pulls the
        // captured PNGs off the device into
        //   app/build/outputs/connected_android_test_additional_output/debugAndroidTest/connected/<Device>/
        // The capture harness writes each PNG via TestStorage.openOutputFile(relativeName) (see
        // CaptureHarness.kt); without this flag the bitmaps stay on-device and never reach the host.
        testInstrumentationRunnerArguments["useTestStorageService"] = "true"
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    // Both :FolinoSettingsAndroid and :FolinoLibraryAndroid stage the full
    // Swift runtime (libswiftCore.so, libFoundation*.so, libc++_shared.so, …).
    // The copies are byte-identical Swift-runtime artefacts across the two
    // modules, so pick first on every .so to resolve the duplicate-merge.
    packaging {
        jniLibs {
            pickFirsts += setOf("**/libc++_shared.so", "**/*.so")
        }
    }

    signingConfigs {
        create("release") {
            if (keystorePropertiesFile.exists()) {
                storeFile = file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            signingConfig = signingConfigs.getByName("release")
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
            // Upload native symbols for the bundled .so (Swift runtime, Oboe/FluidSynth) so native
            // crashes are symbolicated in release. NDK crash *capture* works in all build types via
            // the firebase-crashlytics-ndk dependency below; this only affects symbolication of
            // release builds. Some prebuilt libs may be stripped — unsymbolicated frames are
            // acceptable and do not fail the build.
            configure<com.google.firebase.crashlytics.buildtools.gradle.CrashlyticsExtension> {
                nativeSymbolUploadEnabled = true
            }
        }
    }
}

aboutLibraries {
    includePlatform = false
    duplicationMode = com.mikepenz.aboutlibraries.plugin.DuplicateMode.MERGE
}

// Copy captured PNGs into the fastlane supply tree.
//
// The capture harness writes each PNG via AndroidX TestStorage as the relative name
// "<deviceAlias>/<playLocale>/<NN>.png" (see CaptureHarness.kt). With useTestStorageService=true,
// AGP pulls the whole TestStorage output tree to the host under
//   <buildDir>/outputs/connected_android_test_additional_output/debugAndroidTest/connected/<Device Name (AVD)>/
// i.e. one extra per-device directory level above our "<deviceAlias>/<playLocale>/<NN>.png" layout.
// We walk every connected-device dir (there is normally one) and fan the PNGs out into:
//   Android/fastlane/metadata/android/<playLocale>/images/<phoneScreenshots|tenInchScreenshots>/<NN>.png
tasks.register("collectScreenshots") {
    description = "Pull device screenshots and copy into fastlane/metadata/android/<locale>/images/*"
    group = "screenshot"
    dependsOn("connectedDebugAndroidTest")
    doLast {
        val additionalOutput = layout.buildDirectory
            .dir("outputs/connected_android_test_additional_output/debugAndroidTest/connected")
            .get().asFile
        val deviceAliasToImageDir = mapOf("phone" to "phoneScreenshots", "tablet" to "tenInchScreenshots")
        val fastlaneRoot = rootProject.file("fastlane/metadata/android")
        var copied = 0
        // Level 1: the per-AVD device directory (e.g. "Pixel_6_Pro_API_36(AVD) - 16").
        additionalOutput.listFiles()?.filter { it.isDirectory }?.forEach { avdDir ->
            // Level 2: our deviceAlias directory ("phone" / "tablet").
            deviceAliasToImageDir.forEach { (deviceAlias, imageDir) ->
                val aliasDir = avdDir.resolve(deviceAlias)
                if (!aliasDir.exists()) return@forEach
                // Level 3: the playLocale directory ("en-US" / "ja-JP"), holding "<NN>.png".
                aliasDir.listFiles()?.filter { it.isDirectory }?.forEach { localeDir ->
                    val target = fastlaneRoot.resolve("${localeDir.name}/images/$imageDir")
                    target.mkdirs()
                    localeDir.listFiles()?.filter { it.extension == "png" }?.forEach { png ->
                        png.copyTo(target.resolve(png.name), overwrite = true)
                        copied++
                    }
                }
            }
        }
        println("Screenshots collected into $fastlaneRoot ($copied files)")
    }
}

dependencies {
    val composeBom = platform("androidx.compose:compose-bom:2024.09.02")
    implementation(composeBom)
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.activity:activity-compose:1.9.2")
    implementation("androidx.navigation:navigation-compose:2.8.0")
    debugImplementation("androidx.compose.ui:ui-tooling")
    testImplementation("junit:junit:4.13.2")
    androidTestImplementation("androidx.test.ext:junit:1.2.1")
    androidTestImplementation("androidx.test:runner:1.6.2")
    androidTestImplementation("androidx.test:core-ktx:1.6.1")

    // Instrumented screenshot harness (androidTest, runs on a connected device — the Reader renders
    // sheet music via native JNI that cannot run on the host JVM, so this is NOT a Robolectric test).
    androidTestImplementation("androidx.test.ext:junit:1.2.1")
    androidTestImplementation("androidx.test:runner:1.6.2")
    androidTestImplementation("androidx.test:rules:1.6.1")
    // Compose ui-test-junit4 (BOM 2024.09.02) pulls espresso-core 3.5.1, whose Espresso.onIdle
    // reflects a private InputManager.getInstance() that was removed on Android 15/16 (API 35/36) —
    // crashing every instrumented test on the API-36 Pixel. 3.6.1+ drops that reflection; pin 3.7.0.
    androidTestImplementation("androidx.test.espresso:espresso-core:3.7.0")
    androidTestImplementation(composeBom)
    androidTestImplementation("androidx.compose.ui:ui-test-junit4")
    androidTestImplementation("io.github.takahirom.roborazzi:roborazzi:1.32.0")
    androidTestImplementation("io.github.takahirom.roborazzi:roborazzi-compose:1.32.0")
    androidTestImplementation("io.github.takahirom.roborazzi:roborazzi-junit-rule:1.32.0")
    debugImplementation("androidx.compose.ui:ui-test-manifest")
    // AndroidX Test Storage service: Roborazzi connected mode writes captures via TestStorage; AGP's
    // additional-test-output pull then copies them to the host (see useTestStorageService above).
    androidTestImplementation("androidx.test.services:storage:1.5.0")
    androidTestUtil("androidx.test.services:test-services:1.5.0")

    implementation(project(":FolinoSettingsAndroid"))
    implementation(project(":FolinoLibraryAndroid"))
    implementation(project(":FolinoSoundfontAndroid"))
    implementation(project(":FolinoReaderAndroid"))
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.8.7")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.8.7")
    implementation("androidx.datastore:datastore-preferences:1.1.1")
    implementation("com.google.android.material:material:1.12.0")

    implementation("com.mikepenz:aboutlibraries-core:11.2.3")
    implementation("com.mikepenz:aboutlibraries-compose-m3:11.2.3")

    implementation("sh.calvin.reorderable:reorderable:2.4.3")

    // Score export primitives (PdfScoreRenderer / AudioScoreExporter) draw via
    // the shared sheet-music layout + render the score to audio. Reader uses
    // these as `implementation` (not exposed transitively), so :app declares
    // them directly. mavenLocal; version is property-driven (see gradle.properties
    // `ssmVersion`). Keep all sheet-music-* AARs on ONE version — engine/compose
    // skew breaks DrawCommand exhaustiveness etc.
    val ssmVersion = (findProperty("ssmVersion") as String?) ?: "0.0.0-SNAPSHOT"
    implementation("io.github.jiyimeta:sheet-music-android:$ssmVersion")
    implementation("io.github.jiyimeta:sheet-music-compose-android:$ssmVersion")
    implementation("io.github.jiyimeta:sheet-music-audio-android:$ssmVersion")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.8.1")
    implementation(platform("com.google.firebase:firebase-bom:33.7.0"))
    implementation("com.google.firebase:firebase-crashlytics")
    implementation("com.google.firebase:firebase-crashlytics-ndk")
}
