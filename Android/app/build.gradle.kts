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
        applicationId = "com.keynumber.folino"
        minSdk = 28
        targetSdk = 35
        versionCode = 1
        versionName = "0.1"
        ndk { abiFilters += listOf("arm64-v8a", "x86_64") }
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
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

    buildTypes {
        release {
            isMinifyEnabled = false
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
//   <buildDir>/outputs/roborazzi/<deviceAlias>/<playLocale>/<NN>.png
//   -> Android/fastlane/metadata/android/<playLocale>/images/<phoneScreenshots|tenInchScreenshots>/<NN>.png
tasks.register("collectScreenshots") {
    description = "Pull device screenshots and copy into fastlane/metadata/android/<locale>/images/*"
    group = "screenshot"
    dependsOn("connectedDebugAndroidTest")
    doLast {
        val src = layout.buildDirectory.dir("outputs/roborazzi").get().asFile
        val deviceToImageDir = mapOf("phone" to "phoneScreenshots", "tablet" to "tenInchScreenshots")
        val fastlaneRoot = rootProject.file("fastlane/metadata/android")
        deviceToImageDir.forEach { (deviceAlias, imageDir) ->
            val deviceDir = src.resolve(deviceAlias)
            if (!deviceDir.exists()) return@forEach
            deviceDir.listFiles()?.filter { it.isDirectory }?.forEach { localeDir ->
                val target = fastlaneRoot.resolve("${localeDir.name}/images/$imageDir")
                target.mkdirs()
                localeDir.listFiles()?.filter { it.extension == "png" }?.forEach { png ->
                    png.copyTo(target.resolve(png.name), overwrite = true)
                }
            }
        }
        println("Screenshots collected into $fastlaneRoot")
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

    // Instrumented screenshot harness (androidTest, runs on a connected device — the Reader renders
    // sheet music via native JNI that cannot run on the host JVM, so this is NOT a Robolectric test).
    androidTestImplementation("androidx.test.ext:junit:1.2.1")
    androidTestImplementation("androidx.test:runner:1.6.2")
    androidTestImplementation("androidx.test:rules:1.6.1")
    androidTestImplementation(composeBom)
    androidTestImplementation("androidx.compose.ui:ui-test-junit4")
    androidTestImplementation("io.github.takahirom.roborazzi:roborazzi:1.32.0")
    androidTestImplementation("io.github.takahirom.roborazzi:roborazzi-compose:1.32.0")
    androidTestImplementation("io.github.takahirom.roborazzi:roborazzi-junit-rule:1.32.0")
    debugImplementation("androidx.compose.ui:ui-test-manifest")

    implementation(project(":FolinoSettingsAndroid"))
    implementation(project(":FolinoLibraryAndroid"))
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
    // them directly. mavenLocal, published in Phase A.
    implementation("io.github.jiyimeta:sheet-music-android:0.0.0-SNAPSHOT")
    implementation("io.github.jiyimeta:sheet-music-compose-android:0.0.0-SNAPSHOT")
    implementation("io.github.jiyimeta:sheet-music-audio-android:0.0.0-SNAPSHOT")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.8.1")
    implementation(platform("com.google.firebase:firebase-bom:33.7.0"))
    implementation("com.google.firebase:firebase-crashlytics")
    implementation("com.google.firebase:firebase-crashlytics-ndk")
}
