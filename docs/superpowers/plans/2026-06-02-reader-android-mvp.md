# Reader Android MVP Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring Folino's Reader to Android as a vertical-scroll render + play + cursor-follow + seek experience, reusing `swift-sheet-music`'s Android rendering (promoted into a new reusable library module) and its existing audio engine.

**Architecture:** Two repos, two phases. **Phase A** promotes the score-rendering Compose/Kotlin code that is currently trapped in `swift-sheet-music`'s Android *example app* into a new publishable Android library module `sheet-music-compose-android`, parameterizing the only app-coupled piece (font loading) behind a `FontProvider` and bundling the rendering fonts as library assets. **Phase B** adds a Kotlin-only `:FolinoReaderAndroid` Gradle module to Folino that consumes that library plus the existing `sheet-music-audio-android` engine, and replaces the Reader stub with a real screen wired to the Library's on-disk scores. No `FolinoReaderJNI` Swift target is created for the MVP — rendering, audio, and score parsing all come from the shared `swift-sheet-music` Android libraries.

**Tech Stack:** Kotlin, Jetpack Compose, Material3, AndroidX Lifecycle/ViewModel, Media3, `swift-sheet-music` Android libraries (`sheet-music-android`, `sheet-music-audio-android`, new `sheet-music-compose-android`), Gradle (`com.android.library`, `maven-publish`, `io.github.jiyimeta.wirelet`), consumed via `mavenLocal`.

---

## Conventions & invariants (read before starting)

- **Two working trees:**
  - `swift-sheet-music` dev clone: `/Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music` — Phase A. Work on a feature branch `folino-reader-compose-lib`.
  - Folino worktree: `/Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/reader-android` (branch `reader-android`) — Phase B. **All Folino paths below are relative to this worktree root.**
- **Version coherence (critical):** Folino's iOS build pins `swift-sheet-music` at revision `70761806733a1e9cbbb58315bb4565ffd6c972df` (`Packages/Features/Reader/Package.swift`). The dev clone MUST be checked out at this revision before building/publishing the Android `.so`-bearing modules, so the `DrawProgram` / cursor wire formats match. Verify with `git -C <clone> rev-parse HEAD`.
- **Maven version string:** all three Android modules publish at the default `0.0.0-SNAPSHOT` (the example already expects this). Folino depends on `0.0.0-SNAPSHOT` from `mavenLocal()`.
- **Android Swift toolchain:** building the `.so` for `sheet-music-android` / `sheet-music-audio-android` uses the documented cross-compile toolchain (see project memory `project_android_build_toolchain`: host = `xcrun swift`; cross-compile uses `/Library/Developer/Toolchains/swift-6.3.2-RELEASE.xctoolchain/usr/bin` prefixed on `PATH`). The new `sheet-music-compose-android` module is **pure Kotlin** and needs no Swift build.
- **Gradle invocation:** prefix gradle commands with the XcodeDefault toolchain `PATH` where the existing allowlist does, and pass `--no-daemon`. Use the dev clone's / worktree's own `gradlew`.
- **Build = the test.** This is native Android/Compose glue: "tests" are successful module compiles plus a final manual `installDebug` + `adb` launch verification. Pure-logic helpers added on the Folino side get small JVM unit tests where noted.
- **Commit discipline:** commit after each task. Per project rules, stage whole files (no `git add -p`). Pre-commit hook only touches Swift; these are Kotlin/Gradle changes so it is a no-op.

---

## File structure

### Phase A — `swift-sheet-music` dev clone (new module `Android/SheetMusicComposeAndroid/`)

```
Android/SheetMusicComposeAndroid/
├── build.gradle.kts                      # com.android.library + maven-publish + compose + wirelet(Draw)
├── proguard-consumer.pro                 # empty consumer rules
├── src/main/AndroidManifest.xml          # bare manifest
├── src/main/assets/fonts/
│   ├── Bravura.otf                        # moved from example assets
│   ├── Edwin-Roman.otf                    # moved from example assets
│   ├── Bravura.LICENSE.txt
│   └── Edwin.LICENSE.txt
└── src/main/kotlin/io/github/jiyimeta/sheetmusic/compose/
    ├── draw/model/{DrawCommand,DrawProgram,EncodablePage,FontID}.kt   # moved, repackaged
    ├── draw/DrawProgramReader.kt          # moved, repackaged
    ├── render/FontProvider.kt             # NEW abstraction + default asset impl
    ├── render/ScoreCanvas.kt              # moved from example, font-loading refactored
    ├── cursor/{CursorFrame,LoopHighlightFrame}.kt   # moved, repackaged
    └── cursor/{PlaybackCursorOverlay,LoopHighlightOverlay}.kt        # moved, repackaged
```

Modified: `Android/settings.gradle.kts` (include new module); `Examples/Android/app/build.gradle.kts` + example sources (Phase A validation — repoint to the library).

### Phase B — Folino worktree (new module `Android/FolinoReaderAndroid/`)

```
Android/FolinoReaderAndroid/
├── build.gradle.kts                      # com.android.library + compose + media3 + lib deps
├── src/main/AndroidManifest.xml          # ReaderPlaybackService + foreground-service perms
├── src/main/assets/
│   └── GeneralUser-GS.sf2                 # copied from App/Resources/Soundfonts/
├── src/main/res/drawable/ic_play_arrow.xml  # notification icon
└── src/main/kotlin/com/keynumber/folino/reader/
    ├── FolinoSoundfontResolver.kt         # NEW (implements audio lib SoundfontResolver)
    ├── EnginePlayer.kt                    # copied from example (pure Media3 adapter)
    ├── ReaderAudioViewModel.kt            # adapted from example AudioViewModel
    ├── ReaderPlaybackService.kt           # adapted from example PlaybackService
    ├── ReaderState.kt                     # NEW (load state)
    ├── ReaderViewModel.kt                 # NEW (load .mscz → layout → DrawProgram)
    └── ReaderScreen.kt                    # NEW Compose screen (Scaffold + canvas + transport)
```

Modified: `Android/settings.gradle.kts` (include module); `Android/app/build.gradle.kts` (dependency); `Android/app/src/main/kotlin/com/keynumber/folino/MainActivity.kt` (navigation: pass score id, use ReaderScreen). Deleted: `Android/app/src/main/kotlin/com/keynumber/folino/ui/library/ReaderStubScreen.kt`.

> **Note on audio glue placement.** `EnginePlayer` / `ReaderAudioViewModel` / `ReaderPlaybackService` are Android-only Media3/Service plumbing with **no iOS counterpart** (iOS uses AVFoundation via `SheetMusicAudio`). The parity principle's "don't reimplement iOS logic" therefore does not apply — there is no shared business logic here, only platform glue that *can only* exist on Android. They are adapted from the example into Folino for the MVP. Promoting them into a shared `sheet-music` audio-UI module later is an optional cleanup, not a correctness issue.

---

## PHASE A — Promote rendering into `sheet-music-compose-android`

### Task A0: Branch the dev clone at the pinned revision

**Files:** none (git only).

- [ ] **Step 1: Confirm the dev clone is at Folino's pinned revision**

Run: `git -C /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music rev-parse HEAD`
Expected: `70761806733a1e9cbbb58315bb4565ffd6c972df`. If it differs, stop and reconcile with the user before continuing (building `.so` from a different revision risks wire-format skew).

- [ ] **Step 2: Create the feature branch**

Run: `git -C /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music checkout -b folino-reader-compose-lib`
Expected: `Switched to a new branch 'folino-reader-compose-lib'`

- [ ] **Step 3: Resolve SwiftPM checkouts (needed for the wirelet plugin's swiftPackagePath)**

Run: `swift package --package-path /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music resolve`
Expected: completes; `.build/checkouts/swift-wirelet` exists.

---

### Task A1: Create the empty `SheetMusicComposeAndroid` library module

**Files:**
- Create: `Android/SheetMusicComposeAndroid/build.gradle.kts`
- Create: `Android/SheetMusicComposeAndroid/proguard-consumer.pro`
- Create: `Android/SheetMusicComposeAndroid/src/main/AndroidManifest.xml`
- Modify: `Android/settings.gradle.kts`

(Paths in this task are under the dev clone root `/Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music`.)

- [ ] **Step 1: Create the AndroidManifest**

`Android/SheetMusicComposeAndroid/src/main/AndroidManifest.xml`:
```xml
<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android" />
```

- [ ] **Step 2: Create the consumer proguard file (empty)**

`Android/SheetMusicComposeAndroid/proguard-consumer.pro`:
```
# No consumer rules required yet.
```

- [ ] **Step 3: Create build.gradle.kts**

`Android/SheetMusicComposeAndroid/build.gradle.kts`:
```kotlin
plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
    `maven-publish`
    id("io.github.jiyimeta.wirelet") version "0.1.0-alpha.2"
}

android {
    namespace = "io.github.jiyimeta.sheetmusic.compose"
    compileSdk = 35

    defaultConfig {
        minSdk = 28
        consumerProguardFiles("proguard-consumer.pro")
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }

    buildFeatures { compose = true }

    publishing {
        singleVariant("release") { withSourcesJar() }
    }
}

group = "io.github.jiyimeta"
version = (project.findProperty("version") as String?)
    ?.takeIf { it != "unspecified" }
    ?: "0.0.0-SNAPSHOT"

dependencies {
    val composeBom = platform("androidx.compose:compose-bom:2024.09.02")
    api(composeBom)
    api("androidx.compose.ui:ui")
    api("androidx.compose.foundation:foundation")
    // ScoreCursor / LoopRange model types referenced by the overlays + their
    // wirelet codecs (ScoreCursorCodec) live in the audio module.
    api(project(":SheetMusicAudioAndroid"))
}

val packageRoot: File = rootProject.projectDir.resolve("..").canonicalFile

wirelet {
    swiftPackagePath.set(File(packageRoot, ".build/checkouts/swift-wirelet"))
    sources {
        register("main") {
            schemaPaths.from(packageRoot.resolve("Sources/SheetMusicAndroidJNI/Draw"))
            codecPackage.set("io.github.jiyimeta.sheetmusic.compose.draw")
            modelPackage.set("io.github.jiyimeta.sheetmusic.compose.draw.model")
            // Hand-written model classes are moved into draw/model/ in Task A2,
            // matching the example (emitModels stays false).
        }
    }
}

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

afterEvaluate {
    publishing {
        publications {
            register<MavenPublication>("release") {
                from(components["release"])
                groupId = "io.github.jiyimeta"
                artifactId = "sheet-music-compose-android"
                pom {
                    name.set("SheetMusic Compose Android")
                    description.set(
                        "Jetpack Compose rendering for swift-sheet-music draw programs: " +
                            "score canvas, playback-cursor and loop overlays, bundled SMuFL fonts."
                    )
                    url.set("https://github.com/jiyimeta/swift-sheet-music")
                    licenses {
                        license {
                            name.set("MIT")
                            url.set("https://opensource.org/licenses/MIT")
                        }
                    }
                }
            }
        }
        repositories {
            maven {
                name = "GithubPackages"
                url = uri("https://maven.pkg.github.com/jiyimeta/swift-sheet-music")
                credentials {
                    username = System.getenv("GITHUB_ACTOR")
                        ?: project.findProperty("gpr.user") as String?
                    password = System.getenv("GITHUB_TOKEN")
                        ?: project.findProperty("gpr.token") as String?
                }
            }
        }
    }
}
```

- [ ] **Step 4: Register the module in settings**

In `Android/settings.gradle.kts`, add after the existing `include(...)` lines:
```kotlin
include(":SheetMusicComposeAndroid")
```

- [ ] **Step 5: Verify the empty module configures**

Run: `git -C /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music checkout HEAD -- Android` is NOT needed; instead from the `Android/` dir:
`./gradlew :SheetMusicComposeAndroid:help --no-daemon`
Expected: `BUILD SUCCESSFUL` (project resolves; the `kotlin.plugin.compose` plugin version is inherited from the existing root/plugin management — if the plugin id is unresolved, add `id("org.jetbrains.kotlin.plugin.compose") version "<kotlinVersion>"` matching the example app's Kotlin version).

- [ ] **Step 6: Commit**

```bash
git -C /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music add Android/SheetMusicComposeAndroid Android/settings.gradle.kts
git -C /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music commit -m "feat(android): scaffold sheet-music-compose-android library module"
```

---

### Task A2: Move the draw model + DrawProgramReader into the library

**Files:**
- Create (move): `Android/SheetMusicComposeAndroid/src/main/kotlin/io/github/jiyimeta/sheetmusic/compose/draw/model/{DrawCommand,DrawProgram,EncodablePage,FontID}.kt`
- Create (move): `Android/SheetMusicComposeAndroid/src/main/kotlin/io/github/jiyimeta/sheetmusic/compose/draw/DrawProgramReader.kt`

Source files are under `Examples/Android/app/src/main/java/com/example/sheetmusic/draw/`.

- [ ] **Step 1: Copy the four hand-written model files + the reader into the library tree**

Copy these files verbatim, then change only their `package` declaration from `com.example.sheetmusic.draw[.model]` to `io.github.jiyimeta.sheetmusic.compose.draw[.model]`, and update any `import com.example.sheetmusic.draw...` lines to the new package:
- `draw/model/DrawCommand.kt`
- `draw/model/DrawProgram.kt`
- `draw/model/EncodablePage.kt`
- `draw/model/FontID.kt`
- `draw/DrawProgramReader.kt`

Do **not** copy `draw/model/DrawProgramWire.kt` — that is wirelet-generated output and will be regenerated into the library's build dir by the `wirelet` block configured in Task A1. (If `DrawProgramWire.kt` is in fact hand-written in the example, copy it too and repackage; verify by checking whether `Examples/Android/app/build/generated` contains a `DrawProgramWire` — if generated, skip it.)

- [ ] **Step 2: Verify the library compiles the models + generated codec**

From `Android/`: `./gradlew :SheetMusicComposeAndroid:compileReleaseKotlin --no-daemon`
Expected: `BUILD SUCCESSFUL`. The wirelet codegen runs first (the `dependsOn` wiring) and `DrawProgramReader` resolves the generated codec.

- [ ] **Step 3: Commit**

```bash
git -C /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music add Android/SheetMusicComposeAndroid/src/main/kotlin/io/github/jiyimeta/sheetmusic/compose/draw
git -C /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music commit -m "feat(android): move draw model + reader into compose lib"
```

---

### Task A3: Add the `FontProvider` abstraction + bundle fonts

**Files:**
- Create: `Android/SheetMusicComposeAndroid/src/main/kotlin/io/github/jiyimeta/sheetmusic/compose/render/FontProvider.kt`
- Create (move): `Android/SheetMusicComposeAndroid/src/main/assets/fonts/{Bravura.otf,Edwin-Roman.otf,Bravura.LICENSE.txt,Edwin.LICENSE.txt}`

Font sources are at `Examples/Android/app/src/main/assets/fonts/` and `Examples/Android/app/src/main/assets/` (the LICENSE files sit at the assets root in the example — move them under `fonts/` in the library).

- [ ] **Step 1: Copy the font assets into the library**

Copy `Bravura.otf`, `Edwin-Roman.otf`, `Bravura.LICENSE.txt`, `Edwin.LICENSE.txt` into `Android/SheetMusicComposeAndroid/src/main/assets/fonts/`.

- [ ] **Step 2: Write FontProvider**

`Android/SheetMusicComposeAndroid/src/main/kotlin/io/github/jiyimeta/sheetmusic/compose/render/FontProvider.kt`:
```kotlin
package io.github.jiyimeta.sheetmusic.compose.render

import android.content.Context
import android.graphics.Typeface

/**
 * Supplies the two typefaces the score renderer draws with:
 * a SMuFL music font (Bravura) and a text font (Edwin).
 *
 * The library ships both fonts as assets and provides
 * [bundledFontProvider]; consumers may pass their own implementation
 * to [ScoreCanvas] to override.
 */
interface FontProvider {
    /** SMuFL music glyph font (Bravura). */
    fun smuflTypeface(): Typeface

    /** Text/lyric font (Edwin). */
    fun textTypeface(): Typeface
}

/**
 * [FontProvider] backed by the fonts bundled in this library's assets.
 * Typefaces are created once and cached.
 */
fun bundledFontProvider(context: Context): FontProvider {
    val appContext = context.applicationContext
    return object : FontProvider {
        private val bravura: Typeface by lazy {
            Typeface.createFromAsset(appContext.assets, "fonts/Bravura.otf")
        }
        private val edwin: Typeface by lazy {
            Typeface.createFromAsset(appContext.assets, "fonts/Edwin-Roman.otf")
        }

        override fun smuflTypeface(): Typeface = bravura
        override fun textTypeface(): Typeface = edwin
    }
}
```

- [ ] **Step 3: Verify compile**

From `Android/`: `./gradlew :SheetMusicComposeAndroid:compileReleaseKotlin --no-daemon`
Expected: `BUILD SUCCESSFUL`.

- [ ] **Step 4: Commit**

```bash
git -C /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music add Android/SheetMusicComposeAndroid/src/main
git -C /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music commit -m "feat(android): bundle SMuFL fonts + FontProvider in compose lib"
```

---

### Task A4: Move `ScoreCanvas` into the library, refactored for `FontProvider`

**Files:**
- Create: `Android/SheetMusicComposeAndroid/src/main/kotlin/io/github/jiyimeta/sheetmusic/compose/render/ScoreCanvas.kt`

Source: `Examples/Android/app/src/main/java/com/example/sheetmusic/ScoreCanvas.kt`. The example reads `state: ScoreState.Ready` (an example type) and loads fonts from app assets. The library version takes the `DrawProgram` page directly and a `FontProvider`, removing all app coupling.

- [ ] **Step 1: Write the library ScoreCanvas**

`Android/SheetMusicComposeAndroid/src/main/kotlin/io/github/jiyimeta/sheetmusic/compose/render/ScoreCanvas.kt`:
```kotlin
package io.github.jiyimeta.sheetmusic.compose.render

import android.graphics.Paint
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.gestures.detectTransformGestures
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.drawIntoCanvas
import androidx.compose.ui.graphics.drawscope.withTransform
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.input.pointer.pointerInput
import io.github.jiyimeta.sheetmusic.compose.draw.model.DrawCommand
import io.github.jiyimeta.sheetmusic.compose.draw.model.EncodablePage
import io.github.jiyimeta.sheetmusic.compose.draw.model.FontID

/** Pan/zoom transform shared between [ScoreCanvas] and the cursor overlays. */
data class ScoreTransform(
    val scale: Float = 1f,
    val panOffset: Offset = Offset.Zero,
)

/**
 * Renders a single [EncodablePage] of a draw program onto a Compose
 * [Canvas], with pinch-zoom + pan gesture handling.
 *
 * @param page          the page to draw (document coordinates in mm)
 * @param fontProvider  supplies the SMuFL + text typefaces
 * @param transform     current pan/zoom (hoisted so overlays can share it)
 * @param onTransformChange invoked on gesture
 * @param onPxPerMMChange reports pixels-per-mm so overlays can map mm → px
 */
@Composable
fun ScoreCanvas(
    page: EncodablePage,
    fontProvider: FontProvider,
    transform: ScoreTransform,
    onTransformChange: (ScoreTransform) -> Unit,
    onPxPerMMChange: (Float) -> Unit,
    modifier: Modifier = Modifier,
) {
    val currentTransform by rememberUpdatedState(transform)
    val currentOnTransformChange by rememberUpdatedState(onTransformChange)
    val smufl = fontProvider.smuflTypeface()
    val text = fontProvider.textTypeface()
    Canvas(
        modifier = modifier
            .fillMaxSize()
            .pointerInput(Unit) {
                detectTransformGestures { _, pan, zoom, _ ->
                    val t = currentTransform
                    currentOnTransformChange(
                        t.copy(
                            scale = (t.scale * zoom).coerceIn(0.25f, 8f),
                            panOffset = t.panOffset + pan,
                        )
                    )
                }
            }
    ) {
        val pxPerMM = (size.width / page.widthMM).toFloat()
        onPxPerMMChange(pxPerMM)
        withTransform({
            translate(transform.panOffset.x, transform.panOffset.y)
            scale(transform.scale, transform.scale, pivot = Offset.Zero)
        }) {
            drawPage(page, pxPerMM, smufl, text)
        }
    }
}

private fun DrawScope.drawPage(
    page: EncodablePage,
    pxPerMM: Float,
    smufl: android.graphics.Typeface,
    text: android.graphics.Typeface,
) {
    val path = Path()
    var strokeStarted = false
    var currentArgb: Int = android.graphics.Color.BLACK
    val glyphPaint = Paint().apply {
        isAntiAlias = true
        color = currentArgb
    }
    for (cmd in page.commands) {
        when (cmd) {
            is DrawCommand.MoveTo -> {
                val x = cmd.x.toFloat() * pxPerMM
                val y = cmd.y.toFloat() * pxPerMM
                if (strokeStarted) path.reset()
                path.moveTo(x, y)
                strokeStarted = true
            }
            is DrawCommand.LineTo -> {
                path.lineTo(cmd.x.toFloat() * pxPerMM, cmd.y.toFloat() * pxPerMM)
            }
            is DrawCommand.CubicTo -> {
                path.cubicTo(
                    cmd.cx1.toFloat() * pxPerMM,
                    cmd.cy1.toFloat() * pxPerMM,
                    cmd.cx2.toFloat() * pxPerMM,
                    cmd.cy2.toFloat() * pxPerMM,
                    cmd.x.toFloat() * pxPerMM,
                    cmd.y.toFloat() * pxPerMM,
                )
            }
            is DrawCommand.Stroke -> {
                val widthPx = (cmd.width.toFloat() * pxPerMM).coerceAtLeast(1.5f)
                drawPath(path = path, color = Color(currentArgb), style = Stroke(width = widthPx))
                path.reset()
                strokeStarted = false
            }
            is DrawCommand.FillRect -> {
                drawRect(
                    color = Color(currentArgb),
                    topLeft = Offset(cmd.x.toFloat() * pxPerMM, cmd.y.toFloat() * pxPerMM),
                    size = Size(cmd.w.toFloat() * pxPerMM, cmd.h.toFloat() * pxPerMM),
                )
            }
            is DrawCommand.Glyph -> {
                glyphPaint.typeface = if (cmd.fontId == FontID.SMUFL) smufl else text
                glyphPaint.textSize = cmd.size.toFloat() * pxPerMM
                glyphPaint.color = currentArgb
                val s = String(intArrayOf(cmd.codepoint.toInt()), 0, 1)
                drawIntoCanvas { canvas ->
                    canvas.nativeCanvas.drawText(
                        s, cmd.x.toFloat() * pxPerMM, cmd.y.toFloat() * pxPerMM, glyphPaint,
                    )
                }
            }
            is DrawCommand.Text -> {
                glyphPaint.typeface = if (cmd.fontId == FontID.SMUFL) smufl else text
                glyphPaint.textSize = cmd.size.toFloat() * pxPerMM
                glyphPaint.color = currentArgb
                drawIntoCanvas { canvas ->
                    canvas.nativeCanvas.drawText(
                        cmd.text, cmd.x.toFloat() * pxPerMM, cmd.y.toFloat() * pxPerMM, glyphPaint,
                    )
                }
            }
            is DrawCommand.SetColor -> {
                currentArgb = cmd.argb.toInt()
            }
        }
    }
}
```

> If the example's `DrawCommand` field names differ from those used above (`cx1`, `cy1`, `cx2`, `cy2`, `x`, `y`, `w`, `h`, `width`, `size`, `codepoint`, `fontId`, `argb`, `text`), match the moved model from Task A2 — they are copied from the same source, so they will agree.

- [ ] **Step 2: Verify compile**

From `Android/`: `./gradlew :SheetMusicComposeAndroid:compileReleaseKotlin --no-daemon`
Expected: `BUILD SUCCESSFUL`.

- [ ] **Step 3: Commit**

```bash
git -C /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music add Android/SheetMusicComposeAndroid/src/main/kotlin/io/github/jiyimeta/sheetmusic/compose/render/ScoreCanvas.kt
git -C /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music commit -m "feat(android): move ScoreCanvas into compose lib behind FontProvider"
```

---

### Task A5: Move the cursor + loop overlays into the library

**Files:**
- Create (move): `Android/SheetMusicComposeAndroid/src/main/kotlin/io/github/jiyimeta/sheetmusic/compose/cursor/{CursorFrame,LoopHighlightFrame,PlaybackCursorOverlay,LoopHighlightOverlay}.kt`

Sources: `Examples/Android/app/src/main/java/com/example/sheetmusic/cursor/`.

- [ ] **Step 1: Move the four files**

Copy `CursorFrame.kt`, `LoopHighlightFrame.kt`, `PlaybackCursorOverlay.kt`, `LoopHighlightOverlay.kt` verbatim. Change their `package` to `io.github.jiyimeta.sheetmusic.compose.cursor`. Their imports of `io.github.jiyimeta.sheetmusic.*` (JNI, audio model, codecs) are unchanged — those come from the `:SheetMusicAudioAndroid` `api` dependency. The colors are already constructor parameters with defaults (MuseScore blue / amber); leave them as-is.

- [ ] **Step 2: Verify compile**

From `Android/`: `./gradlew :SheetMusicComposeAndroid:compileReleaseKotlin --no-daemon`
Expected: `BUILD SUCCESSFUL`.

- [ ] **Step 3: Commit**

```bash
git -C /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music add Android/SheetMusicComposeAndroid/src/main/kotlin/io/github/jiyimeta/sheetmusic/compose/cursor
git -C /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music commit -m "feat(android): move playback/loop overlays into compose lib"
```

---

### Task A6: Stage `.so`, publish all three modules to mavenLocal

**Files:** none new (build + publish).

- [ ] **Step 1: Stage the JNI + audio native libs (Swift cross-compile)**

Run the dev clone's documented Android lib build script with the cross-compile toolchain on PATH (per `project_android_build_toolchain`). From the clone root:
`PATH=/Library/Developer/Toolchains/swift-6.3.2-RELEASE.xctoolchain/usr/bin:$PATH ./Scripts/android-build-libs.sh`
Expected: `.so` files staged under `Android/SheetMusicAndroid/src/main/jniLibs/<abi>/` and `Android/SheetMusicAudioAndroid/.../jniLibs/`, and swift-java bindings under `src/main/java-generated/`. (If the script name/flags differ in this revision, use the script referenced by the existing allowlist entry `android-build-library-libs.sh` analog for sheet-music; confirm by `ls Scripts/`.)

- [ ] **Step 2: Publish swiftkit-core to mavenLocal (transitive dep, not on Maven Central)**

From the clone: `./gradlew -p .build/checkouts/swift-java :SwiftKitCore:publishToMavenLocal --no-daemon`
Expected: `BUILD SUCCESSFUL`; `~/.m2/repository/org/swift/swiftkit/swiftkit-core/1.0-SNAPSHOT/` exists.

- [ ] **Step 3: Publish the three Android modules to mavenLocal**

From `Android/`:
`./gradlew :SheetMusicAndroid:publishToMavenLocal :SheetMusicAudioAndroid:publishToMavenLocal :SheetMusicComposeAndroid:publishToMavenLocal --no-daemon`
Expected: `BUILD SUCCESSFUL`.

- [ ] **Step 4: Verify the artifacts landed**

Run: `ls ~/.m2/repository/io/github/jiyimeta/sheet-music-compose-android/0.0.0-SNAPSHOT/`
Expected: an `.aar` and a `.pom`. Repeat for `sheet-music-android` and `sheet-music-audio-android`.

- [ ] **Step 5: No commit** (publishing produces no tracked changes). If `git status` shows staged `.so`/`java-generated` (they are gitignored per the existing module config), confirm they are ignored and move on.

---

### Task A7: Validate Phase A — repoint the example app at the library

**Files:**
- Modify: `Examples/Android/app/build.gradle.kts`
- Modify/Delete: example sources that duplicated the now-extracted code.

This is the Phase A acceptance gate: the example must still render + play after consuming the library instead of its local copy.

- [ ] **Step 1: Add the library dependency to the example**

In `Examples/Android/app/build.gradle.kts` `dependencies { }`, add:
```kotlin
implementation("io.github.jiyimeta:sheet-music-compose-android:0.0.0-SNAPSHOT")
```
And in `Examples/Android/settings.gradle.kts`, add the composite-build substitution alongside the existing two:
```kotlin
substitute(module("io.github.jiyimeta:sheet-music-compose-android"))
    .using(project(":SheetMusicComposeAndroid"))
```

- [ ] **Step 2: Delete the example's now-duplicated sources**

Delete from `Examples/Android/app/src/main/java/com/example/sheetmusic/`:
`draw/` (model + reader), `cursor/`, `ScoreCanvas.kt`. Also remove the example's `wirelet { }` block from its `build.gradle.kts` (the Draw codec now lives in the library) and the example's `fonts/` assets if no longer referenced.

- [ ] **Step 3: Update example imports + call sites**

In `ScoreView.kt`, `ScoreViewModel.kt`, and any file importing `com.example.sheetmusic.draw.*` / `com.example.sheetmusic.cursor.*` / `ScoreCanvas`, switch imports to `io.github.jiyimeta.sheetmusic.compose.{draw,cursor,render}.*`. Update the `ScoreCanvas(...)` call to the new signature: pass `page = state.program.pages[state.currentPage]` and `fontProvider = bundledFontProvider(LocalContext.current)` instead of `state = state`.

- [ ] **Step 4: Build + launch the example**

From `Examples/Android/`: `./gradlew :app:installDebug --no-daemon`
Then launch via `adb shell am start -n com.example.sheetmusic/.MainActivity`.
Expected: the example renders the bundled `test.mscz` (single page, pan/zoom works) and plays with a following cursor — no visual regression vs. before.

- [ ] **Step 5: Commit**

```bash
git -C /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music add Examples/Android
git -C /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music commit -m "refactor(android): example consumes sheet-music-compose-android library"
```

> **Phase A is complete** once the example renders + plays through the library and all three artifacts are in mavenLocal. **Checkpoint with the reviewer before starting Phase B.**

---

## PHASE B — Folino `:FolinoReaderAndroid`

All paths below are under the Folino worktree `/Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/reader-android`.

### Task B1: Scaffold the `FolinoReaderAndroid` library module

**Files:**
- Create: `Android/FolinoReaderAndroid/build.gradle.kts`
- Create: `Android/FolinoReaderAndroid/src/main/AndroidManifest.xml`
- Modify: `Android/settings.gradle.kts`
- Modify: `Android/app/build.gradle.kts`

- [ ] **Step 1: Confirm Folino's Android repos already include mavenLocal**

`Android/settings.gradle.kts` `dependencyResolutionManagement.repositories` already lists `mavenLocal()` and the jiyimeta GitHub Packages maven (verified in the design phase). No change needed there beyond the `include` in Step 3.

- [ ] **Step 2: Create the AndroidManifest with the playback service**

`Android/FolinoReaderAndroid/src/main/AndroidManifest.xml`:
```xml
<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android">

    <uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK" />

    <application>
        <service
            android:name="com.keynumber.folino.reader.ReaderPlaybackService"
            android:exported="false"
            android:foregroundServiceType="mediaPlayback">
            <intent-filter>
                <action android:name="androidx.media3.session.MediaSessionService" />
            </intent-filter>
        </service>
    </application>
</manifest>
```

- [ ] **Step 3: Create build.gradle.kts**

`Android/FolinoReaderAndroid/build.gradle.kts`:
```kotlin
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
```

- [ ] **Step 4: Register the module + add the app dependency**

In `Android/settings.gradle.kts`, after `include(":FolinoLibraryAndroid")`:
```kotlin
include(":FolinoReaderAndroid")
```
In `Android/app/build.gradle.kts` `dependencies { }`, after the `FolinoLibraryAndroid` line:
```kotlin
implementation(project(":FolinoReaderAndroid"))
```

- [ ] **Step 5: Verify the empty module configures**

From `Android/`: `PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH ./gradlew :FolinoReaderAndroid:help --no-daemon`
Expected: `BUILD SUCCESSFUL`.

- [ ] **Step 6: Commit**

```bash
git -C <worktree> add Android/FolinoReaderAndroid Android/settings.gradle.kts Android/app/build.gradle.kts
git -C <worktree> commit -m "feat(android): scaffold :FolinoReaderAndroid module"
```
(Replace `<worktree>` with the worktree root path in every Phase B commit.)

---

### Task B2: Soundfont resolver + bundled SF2 + play icon

**Files:**
- Create: `Android/FolinoReaderAndroid/src/main/assets/GeneralUser-GS.sf2` (copy from `App/Resources/Soundfonts/GeneralUser-GS.sf2`)
- Create: `Android/FolinoReaderAndroid/src/main/res/drawable/ic_play_arrow.xml`
- Create: `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/FolinoSoundfontResolver.kt`

- [ ] **Step 1: Bundle the soundfont**

Copy `App/Resources/Soundfonts/GeneralUser-GS.sf2` to `Android/FolinoReaderAndroid/src/main/assets/GeneralUser-GS.sf2`.

- [ ] **Step 2: Add the notification play icon**

`Android/FolinoReaderAndroid/src/main/res/drawable/ic_play_arrow.xml`:
```xml
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="24dp"
    android:height="24dp"
    android:viewportWidth="24"
    android:viewportHeight="24"
    android:tint="?attr/colorControlNormal">
    <path
        android:fillColor="@android:color/white"
        android:pathData="M8,5v14l11,-7z" />
</vector>
```

- [ ] **Step 3: Write FolinoSoundfontResolver**

`Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/FolinoSoundfontResolver.kt`:
```kotlin
package com.keynumber.folino.reader

import android.content.Context
import android.net.Uri
import androidx.core.net.toUri
import io.github.jiyimeta.sheetmusic.audio.SoundfontResolver
import java.io.File

/**
 * Resolves the SoundFont URI from the bundled General MIDI SoundFont
 * (`GeneralUser-GS.sf2`), materialized from assets to the cache dir on
 * first use. Both melodic and drum lookups return the same GM SF2 for
 * the MVP. The MuseScoreGeneral high-quality download is out of scope.
 */
class FolinoSoundfontResolver(private val context: Context) : SoundfontResolver {

    private val cachedUri: Uri? by lazy {
        try {
            val out = File(context.cacheDir, "GeneralUser-GS.sf2")
            if (!out.exists()) {
                context.assets.open("GeneralUser-GS.sf2").use { input ->
                    out.outputStream().use { input.copyTo(it) }
                }
            }
            out.absoluteFile.toUri()
        } catch (e: Exception) {
            android.util.Log.w("FolinoSoundfont", "GeneralUser-GS.sf2 missing — audio silent", e)
            null
        }
    }

    override fun soundfontUriFor(bank: Int, program: Int, isDrums: Boolean): Uri? = cachedUri
    override val defaultGmSoundfontUri: Uri? get() = cachedUri
}
```

- [ ] **Step 4: Verify compile**

From `Android/`: `PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH ./gradlew :FolinoReaderAndroid:compileDebugKotlin --no-daemon`
Expected: `BUILD SUCCESSFUL`. (Confirms the mavenLocal `sheet-music-audio-android` artifact resolves and `SoundfontResolver` is on the classpath.)

- [ ] **Step 5: Commit**

```bash
git -C <worktree> add Android/FolinoReaderAndroid/src/main
git -C <worktree> commit -m "feat(android): bundle GM soundfont + FolinoSoundfontResolver"
```

---

### Task B3: Audio glue — EnginePlayer, ReaderPlaybackService, ReaderAudioViewModel

**Files:**
- Create: `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/EnginePlayer.kt`
- Create: `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderPlaybackService.kt`
- Create: `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderAudioViewModel.kt`

- [ ] **Step 1: Copy EnginePlayer verbatim**

Copy `Examples/Android/app/src/main/java/com/example/sheetmusic/audio/EnginePlayer.kt` (from the dev clone) into the target path. Change its `package` to `com.keynumber.folino.reader`. It is a pure Media3 `SimpleBasePlayer` adapter with no app coupling, so no other edits are required.

- [ ] **Step 2: Write ReaderPlaybackService**

Adapted from the example `PlaybackService.kt`, but: package `com.keynumber.folino.reader`; uses `FolinoSoundfontResolver`; uses the GM drum-kit metronome (no bundled click WAVs for the MVP); references this module's `R.drawable.ic_play_arrow`; and the session activity points at Folino's `MainActivity` resolved by name (the Reader module can't reference `:app`'s `MainActivity` type, so build the intent via the launch intent).

`Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderPlaybackService.kt`:
```kotlin
package com.keynumber.folino.reader

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Binder
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.media.app.NotificationCompat.MediaStyle
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.session.MediaSession
import androidx.media3.session.MediaSessionService
import io.github.jiyimeta.sheetmusic.audio.AndroidPlaybackEngine
import io.github.jiyimeta.sheetmusic.audio.MetronomeClickProvider
import io.github.jiyimeta.sheetmusic.audio.MetronomeClickSource
import io.github.jiyimeta.sheetmusic.audio.model.PlaybackState
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.launch

private const val NOTIFICATION_ID = 1001
private const val CHANNEL_ID = "folino_playback"
private const val CHANNEL_NAME = "Playback"

class ReaderPlaybackService : MediaSessionService() {

    private lateinit var engine: AndroidPlaybackEngine
    private var session: MediaSession? = null
    private val serviceScope = CoroutineScope(Dispatchers.Main + SupervisorJob())
    private val mediaItemFlow = MutableStateFlow(buildMediaItem(title = "folino", artist = ""))

    private fun buildMediaItem(title: String, artist: String): MediaItem =
        MediaItem.Builder()
            .setMediaId("score")
            .setMediaMetadata(
                MediaMetadata.Builder().setTitle(title).setArtist(artist).build(),
            )
            .build()

    inner class LocalBinder : Binder() {
        val engine: AndroidPlaybackEngine get() = this@ReaderPlaybackService.engine

        fun updateMetadata(title: String, composer: String) {
            mediaItemFlow.value = buildMediaItem(
                title = title.ifBlank { "folino" },
                artist = composer,
            )
        }
    }

    private val localBinder = LocalBinder()

    override fun onBind(intent: Intent?): IBinder? = when (intent?.action) {
        MediaSessionService.SERVICE_INTERFACE -> super.onBind(intent)
        else -> localBinder
    }

    override fun onCreate() {
        super.onCreate()
        engine = AndroidPlaybackEngine(
            context = applicationContext,
            soundfontResolver = FolinoSoundfontResolver(applicationContext),
            // MVP: no bundled click samples → GM drum-kit metronome.
            metronomeClickProvider = MetronomeClickProvider { MetronomeClickSource.DefaultGm },
        )
        val player = EnginePlayer(engine, serviceScope, mediaItemFlow)
        // Re-launch Folino's launcher activity from the notification, resolved
        // by package (the Reader module does not depend on :app's MainActivity).
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
        val sessionActivity = PendingIntent.getActivity(
            this, 0, launchIntent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        session = MediaSession.Builder(this, player)
            .setSessionActivity(sessionActivity)
            .build()
        ensureNotificationChannel()
        observeEngineForForegroundNotification()
    }

    private fun ensureNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val mgr = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (mgr.getNotificationChannel(CHANNEL_ID) != null) return
        mgr.createNotificationChannel(
            NotificationChannel(CHANNEL_ID, CHANNEL_NAME, NotificationManager.IMPORTANCE_LOW)
                .apply { setShowBadge(false) },
        )
    }

    private fun observeEngineForForegroundNotification() {
        serviceScope.launch {
            combine(engine.state, mediaItemFlow) { state, _ -> state }.collect { state ->
                when (state) {
                    PlaybackState.PLAYING, PlaybackState.PAUSED -> postOrUpdateNotification()
                    PlaybackState.STOPPED, PlaybackState.PREPARED, PlaybackState.EXPORTING ->
                        stopForeground(STOP_FOREGROUND_REMOVE)
                }
            }
        }
    }

    private fun postOrUpdateNotification() {
        val s = session ?: return
        val meta = mediaItemFlow.value.mediaMetadata
        val notification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_play_arrow)
            .setContentTitle(meta.title ?: "folino")
            .setContentText(meta.artist ?: "")
            .setStyle(MediaStyle().setMediaSession(s.sessionCompatToken))
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setOngoing(true)
            .build()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    override fun onGetSession(controllerInfo: MediaSession.ControllerInfo): MediaSession? = session

    override fun onTaskRemoved(rootIntent: Intent?) {
        if (session?.player?.playWhenReady != true) stopSelf()
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        session?.run { player.release(); release() }
        session = null
        if (::engine.isInitialized) engine.teardown()
        serviceScope.cancel()
        super.onDestroy()
    }
}
```

- [ ] **Step 3: Write ReaderAudioViewModel**

Adapted from the example `AudioViewModel.kt`: package `com.keynumber.folino.reader`; binds `ReaderPlaybackService` instead of `PlaybackService`. The body is otherwise identical (engine flow flattening, `preparePlayback`).

`Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderAudioViewModel.kt`:
```kotlin
package com.keynumber.folino.reader

import android.app.Application
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.IBinder
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import io.github.jiyimeta.sheetmusic.ScoreMetadata
import io.github.jiyimeta.sheetmusic.audio.AndroidPlaybackEngine
import io.github.jiyimeta.sheetmusic.audio.model.LoopRange
import io.github.jiyimeta.sheetmusic.audio.model.MixerChannel
import io.github.jiyimeta.sheetmusic.audio.model.PlaybackState
import io.github.jiyimeta.sheetmusic.audio.model.ScoreCursor
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.emptyFlow
import kotlinx.coroutines.flow.filterNotNull
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch

@OptIn(ExperimentalCoroutinesApi::class)
class ReaderAudioViewModel(application: Application) : AndroidViewModel(application) {

    private val _engine = MutableStateFlow<AndroidPlaybackEngine?>(null)
    val engine: StateFlow<AndroidPlaybackEngine?> = _engine.asStateFlow()

    @Volatile
    private var serviceBinder: ReaderPlaybackService.LocalBinder? = null

    private val connection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName, binder: IBinder) {
            val local = binder as ReaderPlaybackService.LocalBinder
            serviceBinder = local
            _engine.value = local.engine
        }
        override fun onServiceDisconnected(name: ComponentName) {
            serviceBinder = null
            _engine.value = null
        }
    }

    init {
        val intent = Intent(application, ReaderPlaybackService::class.java)
        application.startService(intent)
        application.bindService(intent, connection, Context.BIND_AUTO_CREATE)
    }

    val state: StateFlow<PlaybackState> = _engine
        .flatMapLatest { it?.state ?: emptyFlow() }
        .stateIn(viewModelScope, SharingStarted.Eagerly, PlaybackState.STOPPED)

    val currentCursor: StateFlow<ScoreCursor?> = _engine
        .flatMapLatest { it?.currentCursor ?: emptyFlow() }
        .stateIn(viewModelScope, SharingStarted.Eagerly, null)

    val currentTimeSeconds: StateFlow<Double> = _engine
        .flatMapLatest { it?.currentTimeSeconds ?: emptyFlow() }
        .stateIn(viewModelScope, SharingStarted.Eagerly, 0.0)

    val totalTimeSeconds: StateFlow<Double> = _engine
        .flatMapLatest { it?.totalTimeSeconds ?: emptyFlow() }
        .stateIn(viewModelScope, SharingStarted.Eagerly, 0.0)

    val mixerChannels: StateFlow<List<MixerChannel>> = _engine
        .flatMapLatest { it?.mixerChannels ?: emptyFlow() }
        .stateIn(viewModelScope, SharingStarted.Eagerly, emptyList())

    val currentRate: StateFlow<Float> = _engine
        .flatMapLatest { it?.currentRate ?: emptyFlow() }
        .stateIn(viewModelScope, SharingStarted.Eagerly, 1.0f)

    val loopRange: StateFlow<LoopRange?> = _engine
        .flatMapLatest { it?.loopRange ?: emptyFlow() }
        .stateIn(viewModelScope, SharingStarted.Eagerly, null)

    fun preparePlayback(scoreHandle: Long) {
        viewModelScope.launch {
            val e = engine.filterNotNull().first()
            ScoreMetadata.fetch(scoreHandle)?.let { meta ->
                serviceBinder?.updateMetadata(title = meta.title, composer = meta.composer)
            }
            if (e.state.value != PlaybackState.STOPPED) return@launch
            try {
                e.prepare(scoreHandle)
            } catch (ex: Exception) {
                android.util.Log.e("ReaderAudioVM", "prepare failed: ${ex.message}", ex)
            }
        }
    }

    override fun onCleared() {
        getApplication<Application>().unbindService(connection)
        super.onCleared()
    }
}
```

- [ ] **Step 4: Verify compile**

From `Android/`: `PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH ./gradlew :FolinoReaderAndroid:compileDebugKotlin --no-daemon`
Expected: `BUILD SUCCESSFUL`.

- [ ] **Step 5: Commit**

```bash
git -C <worktree> add Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader
git -C <worktree> commit -m "feat(android): Reader audio service + viewmodel glue"
```

---

### Task B4: ReaderState + ReaderViewModel (load score → layout → DrawProgram)

**Files:**
- Create: `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderState.kt`
- Create: `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderViewModel.kt`

- [ ] **Step 1: Write ReaderState**

`Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderState.kt`:
```kotlin
package com.keynumber.folino.reader

import io.github.jiyimeta.sheetmusic.compose.draw.model.DrawProgram

sealed interface ReaderState {
    data object Loading : ReaderState
    data class Error(val message: String) : ReaderState
    data class Ready(val program: DrawProgram) : ReaderState
}
```

- [ ] **Step 2: Write ReaderViewModel**

Loads the `.mscz` bytes from `filesDir/Scores/<id>.mscz` (the Library's storage), installs SMuFL metrics once, parses to a score handle, computes the single-page layout, and decodes the `DrawProgram`. Exposes the handle for the audio + overlay path. Mirrors the example `ScoreViewModel` but sources bytes from a file id instead of a bundled asset, and surfaces a missing-file error.

`Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderViewModel.kt`:
```kotlin
package com.keynumber.folino.reader

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import io.github.jiyimeta.sheetmusic.BravuraMetricsBuilder
import io.github.jiyimeta.sheetmusic.ScoreHandle
import io.github.jiyimeta.sheetmusic.SheetMusicJNI
import io.github.jiyimeta.sheetmusic.compose.draw.DrawProgramReader
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File

// A4 page in millimetres (matches the example's single-page layout).
private const val PAGE_WIDTH_MM = 210.0
private const val PAGE_HEIGHT_MM = 297.0

class ReaderViewModel(app: Application) : AndroidViewModel(app) {

    private val _state = MutableStateFlow<ReaderState>(ReaderState.Loading)
    val state: StateFlow<ReaderState> = _state.asStateFlow()

    private val _scoreHandle = MutableStateFlow<Long?>(null)
    val scoreHandle: StateFlow<Long?> = _scoreHandle.asStateFlow()

    private var handle: ScoreHandle? = null

    /** Resolve the Library's on-disk score file: filesDir/Scores/<id>.mscz */
    private fun scoreFile(scoreId: String): File =
        File(File(getApplication<Application>().filesDir, "Scores"), "$scoreId.mscz")

    fun load(scoreId: String) {
        if (_state.value !is ReaderState.Loading && handle != null) return
        viewModelScope.launch {
            val app = getApplication<Application>()

            withContext(Dispatchers.Default) {
                val table = BravuraMetricsBuilder.buildTable(app.assets)
                SheetMusicJNI.nativeInstallSMuFLMetrics(table)
            }

            val file = scoreFile(scoreId)
            val bytes = withContext(Dispatchers.IO) {
                if (file.exists()) file.readBytes() else null
            }
            if (bytes == null) {
                _state.value = ReaderState.Error("Score file not found")
                return@launch
            }

            val h = withContext(Dispatchers.Default) { ScoreHandle.load(bytes) }
            if (h == null) {
                _state.value = ReaderState.Error("Could not open score")
                return@launch
            }
            handle = h
            _scoreHandle.value = h.raw

            val programBytes = withContext(Dispatchers.Default) {
                SheetMusicJNI.nativeComputeLayout(h.raw, PAGE_WIDTH_MM, PAGE_HEIGHT_MM)
            }
            if (programBytes.isEmpty()) {
                _state.value = ReaderState.Error("Layout produced no output")
                return@launch
            }

            val program = try {
                DrawProgramReader.decode(programBytes)
            } catch (e: Exception) {
                _state.value = ReaderState.Error("Could not render score: ${e.message}")
                return@launch
            }
            _state.value = ReaderState.Ready(program)
        }
    }

    override fun onCleared() {
        // Do NOT close `handle`: the same raw Long is used by the playback
        // engine (which outlives this ViewModel via the bound service).
        // Mirrors the example ScoreViewModel.onCleared rationale.
        super.onCleared()
    }
}
```

> **Note re: `BravuraMetricsBuilder.buildTable(app.assets)`** — this reads `bravura_glyphs.json` from `sheet-music-android`'s own bundled assets (the metrics table, distinct from the rendering `.otf` fonts), so no extra asset bundling is needed in Folino. If the build reports the metrics JSON missing at runtime, confirm `sheet-music-android` ships it (it does in the example); do not duplicate it into Folino.

- [ ] **Step 3: Verify compile**

From `Android/`: `PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH ./gradlew :FolinoReaderAndroid:compileDebugKotlin --no-daemon`
Expected: `BUILD SUCCESSFUL`.

- [ ] **Step 4: Commit**

```bash
git -C <worktree> add Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderState.kt Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderViewModel.kt
git -C <worktree> commit -m "feat(android): ReaderViewModel loads library score → DrawProgram"
```

---

### Task B5: ReaderScreen (scroll canvas + cursor overlay + transport)

**Files:**
- Create: `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderScreen.kt`

The screen follows Android idioms: a Material `Scaffold` with a back arrow, the score canvas filling the body inside a vertically scrollable Box, the playback-cursor overlay on top, and a bottom transport bar (play/pause + a seek slider bound to current/total time via `engine.seek(seconds)`).

- [ ] **Step 1: Write ReaderScreen**

`Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderScreen.kt`:
```kotlin
package com.keynumber.folino.reader

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Slider
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import io.github.jiyimeta.sheetmusic.audio.model.PlaybackState
import io.github.jiyimeta.sheetmusic.compose.cursor.PlaybackCursorOverlay
import io.github.jiyimeta.sheetmusic.compose.render.ScoreCanvas
import io.github.jiyimeta.sheetmusic.compose.render.ScoreTransform
import io.github.jiyimeta.sheetmusic.compose.render.bundledFontProvider
import kotlin.math.floor

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ReaderScreen(
    scoreId: String,
    title: String,
    onBack: () -> Unit,
    readerVm: ReaderViewModel = viewModel(),
    audioVm: ReaderAudioViewModel = viewModel(),
) {
    val context = LocalContext.current
    val fontProvider = remember(context) { bundledFontProvider(context) }

    val state by readerVm.state.collectAsStateWithLifecycle()
    val scoreHandle by readerVm.scoreHandle.collectAsStateWithLifecycle()

    // Kick off load once.
    remember(scoreId) { readerVm.load(scoreId); scoreId }

    // Prepare the audio engine once the score handle is available.
    remember(scoreHandle) {
        scoreHandle?.let { audioVm.preparePlayback(it) }
        scoreHandle
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(title.ifEmpty { "folino" }) },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                    }
                },
            )
        },
        bottomBar = { TransportBar(audioVm) },
    ) { padding ->
        Box(
            Modifier
                .padding(padding)
                .fillMaxSize(),
            contentAlignment = Alignment.Center,
        ) {
            when (val s = state) {
                is ReaderState.Loading -> Text("Loading…")
                is ReaderState.Error -> Text(s.message, style = MaterialTheme.typography.bodyLarge)
                is ReaderState.Ready -> {
                    var transform by remember { mutableStateOf(ScoreTransform()) }
                    var pxPerMM by remember { mutableFloatStateOf(1f) }
                    Box(Modifier.fillMaxSize()) {
                        ScoreCanvas(
                            page = s.program.pages.first(),
                            fontProvider = fontProvider,
                            transform = transform,
                            onTransformChange = { transform = it },
                            onPxPerMMChange = { pxPerMM = it },
                            modifier = Modifier.fillMaxSize(),
                        )
                        scoreHandle?.let { handle ->
                            PlaybackCursorOverlay(
                                scoreHandle = handle,
                                cursorFlow = audioVm.currentCursor,
                                pxPerMM = pxPerMM,
                                scale = transform.scale,
                                panOffset = transform.panOffset,
                                modifier = Modifier.fillMaxSize(),
                            )
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun TransportBar(audioVm: ReaderAudioViewModel) {
    val playback by audioVm.state.collectAsStateWithLifecycle()
    val currentSecs by audioVm.currentTimeSeconds.collectAsStateWithLifecycle()
    val totalSecs by audioVm.totalTimeSeconds.collectAsStateWithLifecycle()
    val engine by audioVm.engine.collectAsStateWithLifecycle()

    val isPrepared = playback != PlaybackState.STOPPED && playback != PlaybackState.EXPORTING

    Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp)) {
        Row(
            Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            IconButton(
                onClick = {
                    if (playback == PlaybackState.PLAYING) engine?.pause() else engine?.play()
                },
                enabled = isPrepared,
            ) {
                if (playback == PlaybackState.PLAYING) {
                    Icon(Icons.Default.Pause, contentDescription = "Pause")
                } else {
                    Icon(Icons.Default.PlayArrow, contentDescription = "Play")
                }
            }
            Text(
                text = "${formatTime(currentSecs)} / ${formatTime(totalSecs)}",
                style = MaterialTheme.typography.bodySmall,
            )
            Slider(
                value = if (totalSecs > 0) (currentSecs / totalSecs).toFloat().coerceIn(0f, 1f) else 0f,
                onValueChange = { fraction ->
                    if (totalSecs > 0) engine?.seek(fraction * totalSecs)
                },
                enabled = isPrepared,
                modifier = Modifier.fillMaxWidth(),
            )
        }
    }
}

private fun formatTime(seconds: Double): String {
    val s = seconds.coerceAtLeast(0.0)
    val minutes = floor(s / 60).toLong()
    val secs = floor(s % 60).toLong()
    return "%02d:%02d".format(minutes, secs)
}
```

- [ ] **Step 2: Verify compile**

From `Android/`: `PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH ./gradlew :FolinoReaderAndroid:compileDebugKotlin --no-daemon`
Expected: `BUILD SUCCESSFUL`.

- [ ] **Step 3: Commit**

```bash
git -C <worktree> add Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderScreen.kt
git -C <worktree> commit -m "feat(android): ReaderScreen with cursor overlay + transport bar"
```

---

### Task B6: Wire navigation — pass score id, replace the stub

**Files:**
- Modify: `Android/app/src/main/kotlin/com/keynumber/folino/MainActivity.kt`
- Delete: `Android/app/src/main/kotlin/com/keynumber/folino/ui/library/ReaderStubScreen.kt`

- [ ] **Step 1: Update the Library nav graph route to carry the score id**

In `MainActivity.kt`, in `LibraryNavGraph`, replace the `onOpenScore` lambda and the `reader/...` composable. The current code navigates with only the title; change it to pass the id (path arg) and title (query-style path arg). Replace:
```kotlin
                onOpenScore = { row ->
                    nav.navigate("reader/${URLEncoder.encode(row.title, "UTF-8")}")
                },
```
with:
```kotlin
                onOpenScore = { row ->
                    val t = URLEncoder.encode(row.title, "UTF-8")
                    nav.navigate("reader/${row.id}/$t")
                },
```
and replace the `composable("reader/{title}", ...) { ... ReaderStubScreen(...) }` block with:
```kotlin
        composable(
            "reader/{id}/{title}",
            arguments = listOf(
                navArgument("id") { type = NavType.StringType },
                navArgument("title") { type = NavType.StringType },
            ),
        ) { entry ->
            val id = entry.arguments?.getString("id") ?: ""
            val title = URLDecoder.decode(entry.arguments?.getString("title") ?: "", "UTF-8")
            ReaderScreen(scoreId = id, title = title, onBack = { nav.popBackStack() })
        }
```

- [ ] **Step 2: Fix imports in MainActivity**

Remove `import com.keynumber.folino.ui.library.ReaderStubScreen`. Add `import com.keynumber.folino.reader.ReaderScreen`. Keep the existing `NavType` / `navArgument` / `URLEncoder` / `URLDecoder` imports.

> `row.id` is a field of `ScoreRowWire` (confirmed: `LibraryScreen`'s `items(scores, key = { it.id })` already uses it). Score ids are UUID-like strings safe in a path segment.

- [ ] **Step 3: Delete the stub**

Delete `Android/app/src/main/kotlin/com/keynumber/folino/ui/library/ReaderStubScreen.kt`.

- [ ] **Step 4: Verify the app compiles**

From `Android/`: `PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH ./gradlew :app:compileDebugKotlin --no-daemon`
Expected: `BUILD SUCCESSFUL`.

- [ ] **Step 5: Commit**

```bash
git -C <worktree> add Android/app/src/main/kotlin/com/keynumber/folino/MainActivity.kt
git -C <worktree> rm Android/app/src/main/kotlin/com/keynumber/folino/ui/library/ReaderStubScreen.kt
git -C <worktree> commit -m "feat(android): route Library → real ReaderScreen with score id"
```

---

### Task B7: Full build, install, and manual verification

**Files:** none.

- [ ] **Step 1: Assemble + install the debug app**

From `Android/`: `PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH ./gradlew :app:installDebug --no-daemon`
Expected: `BUILD SUCCESSFUL`; APK installed on the connected device/emulator.

- [ ] **Step 2: Launch the app**

Run: `adb shell am start -n com.keynumber.folino/.MainActivity`
Expected: Folino launches to the Library list.

- [ ] **Step 3: Manual verification checklist** (Android changes are install+launch-complete by project rule)

Import a score if the Library is empty (FAB → pick a `.mscz`), then tap a row and confirm:
  - The score renders (single vertically scrolling page); pan and pinch-zoom work.
  - Play starts audio; the playback-cursor highlight follows the notes.
  - The seek slider scrubs and the time readout updates; releasing seeks audio + cursor.
  - Pause/resume works; back returns to the Library.

Capture any failure with `adb logcat` (filter tags `ReaderAudioVM`, `ReaderViewModel`, `FolinoSoundfont`, `AndroidRuntime`) and debug before declaring done.

- [ ] **Step 4: Final commit (if any fixups were needed)**

```bash
git -C <worktree> add -A
git -C <worktree> commit -m "fix(android): Reader MVP verification fixups"
```
(Skip if nothing changed.)

---

## Self-review against the spec

- **Render + scroll + zoom** → Task A4 (ScoreCanvas), B5 (ReaderScreen body). ✓
- **Play / pause** → B3 (service/viewmodel/engine), B5 (transport bar). ✓
- **Cursor follow** → A5 (overlay), B5 (overlay wired to `audioVm.currentCursor`). ✓
- **Seek slider** → B5 (`engine.seek(seconds)` bound to current/total). ✓
- **Open Library score from disk** → B4 (`filesDir/Scores/<id>.mscz`), B6 (nav passes id). ✓
- **Promote rendering to a reusable lib (not fork)** → Phase A (A1–A5). ✓
- **mavenLocal dependency source** → A6 (publishToMavenLocal), B1/B3 (`implementation("io.github.jiyimeta:…")`). ✓
- **Kotlin-only `:FolinoReaderAndroid`, no FolinoReaderJNI** → B1 (no wirelet/JNI plugins). ✓
- **FontProvider abstraction + bundled fonts** → A3. ✓
- **Out-of-scope items** (inspectors, mixer, A-B, clef, PiP, preferences, MuseScoreGeneral DL, multi-page, other layout modes) — none introduced; loop overlay is moved into the lib but not wired into ReaderScreen. ✓
- **Error handling** (missing file, parse failure, decode mismatch, silent engine) → B4 (Error states), B2 (resolver returns null → engine silent). ✓
- **Version coherence / toolchain risk** → A0 (revision check), A6 (toolchain build). ✓
- **Parity** (no iOS logic reimplemented; Android-only glue; Android UI idioms) → audio-glue note + B5 idiomatic transport. ✓

**Placeholder scan:** no TBD/TODO; every code step shows complete code; moved-file steps name exact source + target + the single package edit. **Type consistency:** `ReaderState.Ready(program)`, `DrawProgram.pages`, `EncodablePage.{widthMM,commands}`, `ScoreCanvas(page, fontProvider, transform, onTransformChange, onPxPerMMChange)`, `PlaybackCursorOverlay(scoreHandle, cursorFlow, pxPerMM, scale, panOffset)`, engine `play()/pause()/seek(Double)`, `ReaderPlaybackService.LocalBinder.engine`, `FolinoSoundfontResolver` implementing `SoundfontResolver` — all consistent across tasks.
