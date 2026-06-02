pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
        maven {
            name = "WireletGitHubPackages"
            url = uri("https://maven.pkg.github.com/jiyimeta/swift-wirelet")
            credentials {
                username = System.getenv("GITHUB_ACTOR")
                    ?: providers.gradleProperty("gpr.user").orNull
                password = System.getenv("GITHUB_TOKEN")
                    ?: providers.gradleProperty("gpr.key").orNull
            }
            content {
                // Plugin marker POM lives under io.github.jiyimeta.wirelet;
                // plugin artifact lives under io.github.jiyimeta — cover both.
                includeGroupByRegex("io\\.github\\.jiyimeta.*")
            }
        }
    }
}
dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
        // swift-java's swiftkit-core is not yet on Maven Central — propagated
        // via FolinoSettingsAndroid's `api` dep. Locally-published via
        // `cd .build/checkouts/swift-java && ./gradlew :SwiftKitCore:publishToMavenLocal`.
        mavenLocal()
        maven {
            name = "WireletGitHubPackages"
            url = uri("https://maven.pkg.github.com/jiyimeta/swift-wirelet")
            credentials {
                username = System.getenv("GITHUB_ACTOR")
                    ?: providers.gradleProperty("gpr.user").orNull
                password = System.getenv("GITHUB_TOKEN")
                    ?: providers.gradleProperty("gpr.key").orNull
            }
            content {
                // Match the pluginManagement filter — covers both the runtime
                // artifact (io.github.jiyimeta) and any sub-namespaced
                // artefacts that may appear later.
                includeGroupByRegex("io\\.github\\.jiyimeta.*")
            }
        }
    }
}

rootProject.name = "FolinoAndroid"
include(":FolinoSettingsAndroid")
include(":FolinoLibraryAndroid")
include(":FolinoReaderAndroid")
include(":app")
