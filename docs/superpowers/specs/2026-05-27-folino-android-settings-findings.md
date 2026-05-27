# Folino Android Settings Spike — Findings

Date: 2026-05-27  
Spike spec: `docs/superpowers/specs/2026-05-27-folino-android-settings-spike-design.md`  
Spike plan: `docs/superpowers/plans/2026-05-27-folino-android-settings-spike.md`

---

## 1. Environment setup

### Toolchain

| Item | Value |
| --- | --- |
| Swift toolchain ID | `org.swift.632202605101a` |
| Swift toolchain banner | `Apple Swift version 6.3.2 (swift-6.3.2-RELEASE)` |
| Host triple | `arm64-apple-macosx26.0` |
| Android Swift SDK name | `swift-6.3.2-RELEASE_android` |
| SDK installed via | `swift sdk list` — already present at session start |

Verified with `TOOLCHAINS=org.swift.632202605101a swift --version`. The banner shows `swift-6.3.2-RELEASE` (not `swiftlang-6.3.2`), confirming the open-source toolchain is active.

### NDK

| Item | Value |
| --- | --- |
| NDK version used | `28.2.13676358` |
| NDK path | `~/Library/Android/sdk/ndk/28.2.13676358` |
| Sysroot setup | `setup-android-sdk.sh` outcome: `success: ndk-sysroot re-linked to Android NDK at …/ndk/28.2.13676358/toolchains/llvm/prebuilt` |

Script location: `~/Library/org.swift.swiftpm/swift-sdks/swift-6.3.2-RELEASE_android.artifactbundle/swift-android/scripts/setup-android-sdk.sh`. Must be re-run whenever the NDK version changes (it rewrites a sysroot symlink inside the artifactbundle).

### Cross-compile smoke test

Target: `aarch64-unknown-linux-android28`, product `SheetMusicCore` from `swift-sheet-music`, release mode.

Command:
```
TOOLCHAINS=org.swift.632202605101a SWIFT_SHEET_MUSIC_ANDROID=1 \
  swift build --package-path <ssm> --product SheetMusicCore \
  --swift-sdk aarch64-unknown-linux-android28 -c release
```

Outcome: **SUCCESS** — `Build of product 'SheetMusicCore' complete! (538.47s)`.

Notable observations:
- The build invoked swift-java's `JExtractSwiftPlugin` to generate JNI thunks for `SheetMusicAndroidJNI` automatically as a build-tool plugin.
- `libSheetMusicAndroidJNI.so` was linked as the final artifact.
- Build time ~9 minutes on Apple M-series (first build; subsequent incremental builds will be much faster).
- One warning during jextract: `Writing types in file group: DrawProgram.swift` — benign, pre-existing in SSM.

### swiftkit-core Maven local publish

Source: `swift-sheet-music/.build/checkouts/swift-java` (resolved as a SwiftPM dependency of SSM).

Command:
```
<swift-java-checkout>/gradlew -p <swift-java-checkout> :SwiftKitCore:publishToMavenLocal
```

Outcome: **BUILD SUCCESSFUL in 42s**.

Artifact path: `~/.m2/repository/org/swift/swiftkit/swiftkit-core/1.0-SNAPSHOT/`

Files present:
- `swiftkit-core-1.0-SNAPSHOT.jar`
- `swiftkit-core-1.0-SNAPSHOT.module`
- `swiftkit-core-1.0-SNAPSHOT.pom`

Note: Gradle printed one unchecked-operation warning from `SimpleCompletableFuture.java` — this is a pre-existing issue in swift-java, not a local problem. The publish completed cleanly.

### JDK versions

| JDK | Version | Notes |
| --- | --- | --- |
| Host `java` (on `PATH`) | OpenJDK 18.0.1.1 (build 18.0.1.1+2-6) | AdoptOpenJDK / JAVA_HOME default |
| Gradle-selected JDK for swiftkit-core publish | Azul Zulu 17.0.17 (`/Library/Java/JavaVirtualMachines/zulu-17.jdk`) | Gradle auto-toolchain via `org.gradle.java.installations.fromEnv=…JAVA_HOME_17…` in swift-java's `gradle.properties` |

Friction: swift-java's Gradle build detects JDK ≥ 21 for Foreign Function & Memory (FFM) modules. With JDK 17, those modules are skipped (`[swift-java] JDK 17 detected — skipping: SwiftKitFFM, Samples:…`). This is expected behavior — `SwiftKitFFM` is the Panama-based alternative to JNI; Folino uses JNI, not FFM. No action needed.

For future Folino Android Gradle builds (AGP), minimum is JDK 17 (compatible). Consider targeting JDK 21 long-term for FFM access if the plan ever shifts to Panama-based interop.

### GitHub Packages credentials

`~/.gradle/gradle.properties` contains `gpr.user` and `gpr.key` — credentials present, wirelet dependency resolution expected to work.

### Summary: frictions and surprises

1. **NDK sysroot re-link is a one-time-per-clone step** (not per build). If the NDK is upgraded or the machine is re-provisioned, `setup-android-sdk.sh` must be re-run. The script is idempotent.
2. **First cross-compile is ~9 minutes** because swift-java's build-tool plugins (StaticBuildConfigPlugin, JExtractSwiftPlugin) and all transitive Swift packages compile from scratch. Incremental rebuilds are much faster.
3. **swiftkit-core is not on Maven Central** — `publishToMavenLocal` is a required setup step on every fresh machine/CI runner. The `gradlew` wrapper inside the SSM SwiftPM checkout is self-contained; no separate Gradle installation needed.
4. **Gradle uses JDK 17, not 18** — Gradle auto-toolchain resolution picks Zulu 17 over AdoptOpenJDK 18 due to `org.gradle.java.installations.fromEnv` preference ordering. This is fine for the JNI path Folino uses.

---

## 2. SettingsLogic package split

_To be filled in Phase 1._

---

## 3. FolinoSettingsJNI module + swift-java bindings

_To be filled in Phase 2._

---

## 4. Android Gradle project scaffold + wirelet integration

_To be filled in Phase 3._

---

## 5. End-to-end screen on emulator + shareability assessment

_To be filled in Phase 4/5._
