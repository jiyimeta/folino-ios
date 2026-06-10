plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
    id("io.github.jiyimeta.wirelet") version "0.3.2"
}

android {
    namespace = "com.keynumber.folino.soundfont"
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
    api("io.github.jiyimeta:wirelet-runtime:0.3.2")
    api("io.github.jiyimeta:wirelet-observable-runtime:0.3.2")
    api("androidx.lifecycle:lifecycle-viewmodel:2.8.7")
    api("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0")
    implementation("androidx.datastore:datastore-preferences:1.1.1")
    implementation("androidx.core:core-ktx:1.13.1")
}

val packageRoot: File = rootProject.projectDir.resolve("..").canonicalFile

wirelet {
    val infraCheckout = packageRoot.resolve("Packages/Infrastructure/.build/checkouts/swift-wirelet")
    val rootCheckout = packageRoot.resolve(".build/checkouts/swift-wirelet")
    swiftPackagePath.set(if (infraCheckout.exists()) infraCheckout else rootCheckout)

    sources {
        register("main") {
            schemaPaths.from(packageRoot.resolve("Packages/Infrastructure/Sources/FolinoSoundfontJNI"))
            codecPackage.set("com.keynumber.folino.soundfont")
            modelPackage.set("com.keynumber.folino.soundfont")
            emitModels.set(true)
        }
    }
    observable {
        register("main") {
            schemaPaths.from(packageRoot.resolve("Packages/Infrastructure/Sources/FolinoSoundfontJNI"))
            viewModelPackage.set("com.keynumber.folino.soundfont.generated")
            modelPackage.set("com.keynumber.folino.soundfont")
            codecPackage.set("com.keynumber.folino.soundfont")
            libraryName.set("FolinoSoundfontJNI")
            providedAdapterPackage.set("com.keynumber.folino.soundfont")
        }
    }
    provided {
        register("main") {
            schemaPaths.from(packageRoot.resolve("Packages/Infrastructure/Sources/FolinoSoundfontJNI"))
            interfacePackage.set("com.keynumber.folino.soundfont")
            adapterPackage.set("com.keynumber.folino.soundfont")
            modelPackage.set("com.keynumber.folino.soundfont")
            codecPackage.set("com.keynumber.folino.soundfont")
        }
    }
}

// kotlin.android needs the generated dirs wired manually (the plugin hooks
// kotlin.jvm only). Mirror the Settings module's pattern for BOTH the codec
// task and the observable viewmodel task.
val generateCodecs = tasks.named("generateWireletCodecsMain")
val generateViewModels = tasks.named("generateWireletObservableViewModelsMain")
val generateProvided = tasks.named("generateWireletProvidedInterfacesMain")

android {
    sourceSets["main"].kotlin.srcDir(
        generateCodecs.flatMap { (it as io.github.jiyimeta.wirelet.gradle.GenerateWireletCodecs).outputDir }
    )
    sourceSets["main"].kotlin.srcDir(
        generateViewModels.flatMap { (it as io.github.jiyimeta.wirelet.gradle.GenerateWireletObservableViewModels).outputDir }
    )
    sourceSets["main"].kotlin.srcDir(
        generateProvided.flatMap { (it as io.github.jiyimeta.wirelet.gradle.GenerateWireletProvidedInterfaces).outputDir }
    )
}

tasks.matching { it.name.startsWith("compile") && it.name.endsWith("Kotlin") }
    .configureEach { dependsOn(generateCodecs, generateViewModels, generateProvided) }
