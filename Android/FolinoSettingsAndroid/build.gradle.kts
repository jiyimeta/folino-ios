plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "com.keynumber.folino.settings"
    compileSdk = 35

    defaultConfig {
        minSdk = 28
        consumerProguardFiles("proguard-consumer.pro")
        ndk {
            abiFilters += listOf("arm64-v8a", "x86_64")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions { jvmTarget = "17" }

    // Prebuilt Swift JNI .so libs will be staged here in Phase 3.
    sourceSets["main"].jniLibs.srcDirs("src/main/jniLibs")

    // swift-java jextract output (Java bindings) will be copied here in Phase 3.
    sourceSets["main"].java.srcDirs("src/main/java-generated")
}

dependencies {
    // Runtime support for swift-java-generated Java bindings.
    // Locally-published from the swift-java repo until it ships to Maven Central.
    api("org.swift.swiftkit:swiftkit-core:1.0-SNAPSHOT")
    // wirelet-runtime provides BinaryReader/BinaryWriter used by wirelet-generated codecs.
    api("io.github.jiyimeta:wirelet-runtime:0.1.0-alpha.2")
}
