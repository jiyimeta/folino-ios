// Top-level build file. No plugins applied at root; subprojects manage their own.
plugins {
    // AGP 8.6+ aligns uncompressed native libs to 16 KB in the packaged APK (Play's 16 KB
    // page-size requirement); 8.5.0 only 4 KB-aligned them. 8.6.1 stays Gradle-8.7 compatible.
    id("com.android.library") version "8.6.1" apply false
    id("com.android.application") version "8.6.1" apply false
    id("org.jetbrains.kotlin.android") version "2.0.20" apply false
    id("org.jetbrains.kotlin.plugin.compose") version "2.0.20" apply false
    id("com.mikepenz.aboutlibraries.plugin") version "11.2.3" apply false
    id("com.google.gms.google-services") version "4.4.2" apply false
    id("com.google.firebase.crashlytics") version "3.0.2" apply false
}
