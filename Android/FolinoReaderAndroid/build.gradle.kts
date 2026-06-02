plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

android {
    namespace = "com.keynumber.folino.reader"
    compileSdk = 35

    defaultConfig {
        minSdk = 28
        ndk { abiFilters += listOf("arm64-v8a", "x86_64") }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }

    buildFeatures { compose = true }
}

dependencies {
    val composeBom = platform("androidx.compose:compose-bom:2024.09.02")
    implementation(composeBom)
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.8.7")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.8.7")

    implementation("androidx.media3:media3-session:1.5.0")
    implementation("androidx.media3:media3-common:1.5.0")
    implementation("androidx.media:media:1.7.0")

    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.8.1")

    // swift-sheet-music Android libraries (mavenLocal, published in Phase A).
    implementation("io.github.jiyimeta:sheet-music-compose-android:0.0.0-SNAPSHOT")
    implementation("io.github.jiyimeta:sheet-music-audio-android:0.0.0-SNAPSHOT")
    implementation("io.github.jiyimeta:sheet-music-android:0.0.0-SNAPSHOT")
}
