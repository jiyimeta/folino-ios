plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
    id("io.github.jiyimeta.wirelet") version "0.2.2"
}

android {
    namespace = "com.keynumber.folino.library"
    compileSdk = 35

    defaultConfig {
        minSdk = 28
        consumerProguardFiles("proguard-consumer.pro")
        ndk { abiFilters += listOf("arm64-v8a", "x86_64") }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }

    sourceSets["main"].jniLibs.srcDirs("src/main/jniLibs")
}

dependencies {
    api("io.github.jiyimeta:wirelet-runtime:0.2.2")
    api("io.github.jiyimeta:wirelet-observable-runtime:0.2.2")
    api("androidx.lifecycle:lifecycle-viewmodel:2.8.7")
    api("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0")
}

val packageRoot: File = rootProject.projectDir.resolve("..").canonicalFile

wirelet {
    val libCheckout = packageRoot.resolve("Packages/Features/Library/.build/checkouts/swift-wirelet")
    val rootCheckout = packageRoot.resolve(".build/checkouts/swift-wirelet")
    swiftPackagePath.set(if (libCheckout.exists()) libCheckout else rootCheckout)

    sources {
        register("main") {
            schemaPaths.from(packageRoot.resolve("Packages/Features/Library/Sources/FolinoLibraryJNI"))
            codecPackage.set("com.keynumber.folino.library")
            modelPackage.set("com.keynumber.folino.library")
            emitModels.set(true)
        }
    }
    observable {
        register("main") {
            schemaPaths.from(packageRoot.resolve("Packages/Features/Library/Sources/FolinoLibraryJNI"))
            viewModelPackage.set("com.keynumber.folino.library.generated")
            modelPackage.set("com.keynumber.folino.library")
            codecPackage.set("com.keynumber.folino.library")
            libraryName.set("FolinoLibraryJNI")
        }
    }
}

// kotlin.android needs the generated dirs wired manually (the plugin hooks
// kotlin.jvm only). Mirror the Settings module's pattern for BOTH the codec
// task and the observable viewmodel task.
val generateCodecs = tasks.named("generateWireletCodecsMain")
val generateViewModels = tasks.named("generateWireletObservableViewModelsMain")

android {
    sourceSets["main"].kotlin.srcDir(
        generateCodecs.flatMap { (it as io.github.jiyimeta.wirelet.gradle.GenerateWireletCodecs).outputDir }
    )
    sourceSets["main"].kotlin.srcDir(
        generateViewModels.flatMap { (it as io.github.jiyimeta.wirelet.gradle.GenerateWireletObservableViewModels).outputDir }
    )
}

tasks.matching { it.name.startsWith("compile") && it.name.endsWith("Kotlin") }
    .configureEach { dependsOn(generateCodecs, generateViewModels) }
