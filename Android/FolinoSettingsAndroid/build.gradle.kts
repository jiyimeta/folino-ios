plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
    id("io.github.jiyimeta.wirelet") version "0.2.2"
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
    api("io.github.jiyimeta:wirelet-runtime:0.2.2")
}

// `packageRoot` is the worktree root (one level above the Android/ Gradle root).
val packageRoot: File = rootProject.projectDir.resolve("..").canonicalFile

wirelet {
    // SwiftPM resolves swift-wirelet into Packages/Features/Settings/.build/checkouts
    // at the revision pinned in Package.resolved; reuse that checkout for the emitter.
    // Fall back to a repo-root .build/checkouts clone if the Settings checkout is absent.
    val settingsCheckout = packageRoot.resolve("Packages/Features/Settings/.build/checkouts/swift-wirelet")
    val rootCheckout = packageRoot.resolve(".build/checkouts/swift-wirelet")
    swiftPackagePath.set(if (settingsCheckout.exists()) settingsCheckout else rootCheckout)
    sources {
        register("main") {
            // Where the @WireFormat decls live (VersionHistoryWire / VersionHistoryWireList).
            schemaPaths.from(packageRoot.resolve("Packages/Features/Settings/Sources/SettingsLogic"))
            codecPackage.set("com.keynumber.folino.settings")
            modelPackage.set("com.keynumber.folino.settings")
            emitModels.set(true)
        }
    }
}

// Wire the wirelet-generated source directory into the Android source set
// and make every Kotlin compile task depend on codegen. The wirelet plugin
// v1 only hooks into kotlin.jvm; kotlin.android needs the same wiring added
// manually here.
val generateWireletCodecsMain = tasks.named("generateWireletCodecsMain")

android {
    sourceSets["main"].kotlin.srcDir(
        generateWireletCodecsMain.flatMap {
            (it as io.github.jiyimeta.wirelet.gradle.GenerateWireletCodecs).outputDir
        }
    )
}

tasks.matching { it.name.startsWith("compile") && it.name.endsWith("Kotlin") }
    .configureEach { dependsOn(generateWireletCodecsMain) }
