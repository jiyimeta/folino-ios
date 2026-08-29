# SP3 — Android session plumbing (Implementation Plan)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give Android a working edit session with no UI — Folino's own `.so` holds the authoritative
`EditorSessionCore`, every applied intent is relayed to the mirror behind ssm's score handle through exactly one
Kotlin funnel, and the two copies are proven byte-identical on a physical device.

**Architecture:** Spec §4's relay, built end to end. A new Android-gated dynamic library `FolinoEditorJNI` (in the
Editor package, shaped exactly like `FolinoReaderJNI`) wraps one `EditorSessionCore` as a `@WireletObservable`
`EditorBridge`. Every op it exposes leaves behind the intent bytes it applied; a new Gradle module
`:FolinoEditorAndroid` owns the generated Kotlin and one class, `EditSessionRelay`, whose single `perform` method is
the only path from a user action to the score: local apply → drain intent frames → `nativeApplyEditIntent` per frame
→ sampled fingerprint compare → relayout. The §8.1 version gate runs once before a session opens; the §8.3 resync
runs whenever a relayed call answers `false` or a fingerprint disagrees.

**Tech Stack:** Swift 6.3 (Android SDK cross-compile), swift-sheet-music 1.13.0 (`SheetMusicCore`,
`SheetMusicMSCX`, `SheetMusicEditWire`), swift-wirelet 0.3.2 (`@WireletObservable` / `@WireletProvided` /
`@WireFormat`), swift-java 0.4.0 (jextract), Kotlin / Gradle / AndroidJUnit4.

## Global Constraints

- **Nothing in this plan may change iOS behavior.** Task 1 is the only edit to shared code; the existing
  `EditorTests` + `EditorCoreTests` suites are its gate.
- **swift-sheet-music is pinned at `exact: "1.13.0")`** in `Packages/Features/Editor/Package.swift` and under
  `packages:` in `project.yml`. SP3 needs no ssm change; if one turns out to be needed, it lands and tags on the ssm
  side first ([[feedback_ssm_side_land_independently]]) and Folino re-pins **on `main`**, then merges down.
- **The intent wire is linked, never re-declared** (spec §5.4, user ruling 2026-08-06). `FolinoEditorJNI` links ssm's
  `SheetMusicEditWire` product and calls `EditIntentCodec.encode`. Declaring a second `@WireFormat` projection of
  `EditIntent` anywhere in Folino is a plan violation.
- **Kotlin is a courier.** It never encodes, decodes or inspects an intent. Anything Kotlin would have to understand
  about an edit is a signal the seam is in the wrong place (SP0 finding: "Kotlin should never have been encoding
  intents at all").
- **No `Task { @MainActor in … }` in the JNI target.** An Android JNI process pumps no main runloop; a MainActor hop
  is created and never scheduled. Where a synchronous answer is needed across an `actor`, use the
  `DispatchSemaphore` idiom `AnnotationSaveBridge.open(scoreId:)` already uses.
- **`EditorCore` keeps owning no concurrency.** SP2 deliberately left `Task {}` out of the core; SP3 does not put one
  back.
- **Android UI placement follows Android idioms; behavior and logic are shared Swift.** SP3 ships no UI, but every
  decision it makes about *what* an op does belongs in `EditorCore`, not in Kotlin.
- **Access modifiers stay minimal.** `public` only where the Android bridge or the app module actually reaches it.
- **Comments reflow at 120 columns**, per the repo's comment style.

## Commands

```sh
# iOS-side gate for Task 1 (run from the package dir)
cd Packages/Features/Editor
xcodebuild test -scheme Editor-Package \
    -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation

# one suite only
xcodebuild test -scheme Editor-Package \
    -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation \
    -only-testing:Editor-Package/EditorRelayRecordingTests

# Android: manifest sanity after editing Package.swift (both shapes must resolve)
swift package describe --package-path Packages/Features/Editor >/dev/null
FOLINO_ANDROID=1 swift package describe --package-path Packages/Features/Editor >/dev/null

# Android: cross-compile + stage the .so and the jextract bindings
FOLINO_ANDROID_ABIS=arm64-v8a Scripts/android-build-editor-libs.sh

# Android: Kotlin
Android/gradlew -p Android :FolinoEditorAndroid:testDebugUnitTest
Android/gradlew -p Android :FolinoEditorAndroid:connectedDebugAndroidTest
```

**The mavenLocal ssm AARs must match the pinned 1.13.0 before any Gradle task runs.** `Android/gradle.properties`
consumes `ssmVersion=0.0.0-SNAPSHOT`, and tags publish only to GitHub Packages — so an ssm clone at the `1.13.0` tag
has to run `Scripts/android-build-libs.sh` and then publish **all three** modules to mavenLocal in one go
(engine / audio / compose at the same revision — publishing one alone is the version-skew trap in
`project_android_sheetmusic_aar_version_skew`). Task 6 makes this a checked step, because every Kotlin task in Part B
and C depends on it.

## Prior art you must read first

1. **SP0's Findings** — `docs/superpowers/plans/2026-08-06-android-note-editing-sp0.md`, especially "What SP3 must
   carry". Four of its five bullets are tasks below; the fifth (the stale-layout race) is deliberately *not* fixed
   here — see the Notes at the end.
2. **SP2's "Notes for whoever executes this"** — `…-sp2.md`, for the three user rulings and the three deferrals.
3. **Spec §4, §5.3, §5.4, §6.2, §8** — `docs/superpowers/specs/2026-08-06-android-note-editing-design.md`.
4. **`Packages/Features/Reader/Sources/FolinoReaderJNI/AnnotationSaveBridge.swift`** — the shape every file in Part A
   copies: `@WireletObservable @Observable final class`, `@WireletExpose` methods, `@WireletProvided` seams, and the
   two traps its doc comments record (no MainActor executor; `WireArray.kt` framing).
5. **`Android/FolinoReaderAndroid/build.gradle.kts`** — the codegen wiring Task 6 mirrors.
6. **`Packages/Features/Editor/Sources/Editor/EditorViewModel.swift`** — the iOS adapter. `syncFromCore()` is
   precisely what Task 3's projection does on the other platform; keep them recognizably the same shape.

## File Structure

**Created**

| Path | Responsibility |
| --- | --- |
| `Packages/Features/Editor/Sources/FolinoEditorJNI/EditorBridge.swift` | The `@WireletObservable` class: one `EditorSessionCore`, the session lifecycle, the projection Compose reads. |
| ~~`…/FolinoEditorJNI/EditorBridge+Ops.swift`~~ | **Does not exist — see the amendment note below.** swift-wirelet's `ObservableSchemaParser` visits only a class's own member list, never an extension, so `@WireletExpose` methods in a separate extension file are silently absent from the generated Kotlin. The op vocabulary lives in `EditorBridge.swift`'s class body, under its own `// MARK:` sections. |
| `Packages/Features/Editor/Sources/FolinoEditorJNI/EditorBridgeWires.swift` | The two `@WireFormat` types this bridge declares: `EditBytesWire` (opaque frames, both directions) and nothing else that duplicates ssm. |
| `Packages/Features/Editor/Sources/FolinoEditorJNI/EditorAndroidSeams.swift` | `@WireletProvided EditorHostFiles` (SHA-256 + Room row refresh) and the `FileFactsProviding` / `ScoreFileWriting` adapters over it. |
| `Packages/Features/Editor/Sources/FolinoEditorJNI/swift-java.config` | jextract config, copied from `FolinoReaderJNI`'s. |
| `Scripts/android-build-editor-libs.sh` | Cross-compiles `FolinoEditorJNI` per ABI and stages `.so` + jextract bindings into the new Gradle module. |
| `Android/FolinoEditorAndroid/build.gradle.kts` | The Gradle module: wirelet codegen (codecs / observable / provided), jniLibs + java-generated source dirs. |
| `Android/FolinoEditorAndroid/src/main/kotlin/com/keynumber/folino/editor/EditSessionRelay.kt` | **The one funnel.** `perform`, the version gate, fingerprint sampling, resync. |
| `Android/FolinoEditorAndroid/src/main/kotlin/com/keynumber/folino/editor/EditSessionHost.kt` | The three things the relay needs from whoever owns the score handle — kept an interface so SP4 can hand it the Reader and Task 9 can hand it a test double. |
| `Android/FolinoEditorAndroid/src/main/kotlin/com/keynumber/folino/editor/EditorRoomFiles.kt` | The Kotlin side of the `@WireletProvided` seam (SHA-256 today; the Room row refresh is SP5's). |
| `Android/FolinoEditorAndroid/src/test/kotlin/com/keynumber/folino/editor/EditSessionRelayTest.kt` | JVM tests for the relay's policy against a fake native surface. |
| `Android/FolinoEditorAndroid/src/androidTest/kotlin/com/keynumber/folino/editor/EditSessionParityTest.kt` | The device gate: scripted ops, fingerprint equality after every step. |
| `Android/FolinoEditorAndroid/src/androidTest/assets/parity.mscz` | The fixture the device test edits (copied from the repo's test resources). |

**Modified**

| Path | Change |
| --- | --- |
| `Packages/Features/Editor/Sources/EditorCore/EditorSessionCore.swift` | Task 1: opt-in recording of applied intents. |
| `Packages/Features/Editor/Package.swift` | Task 2: the `FOLINO_ANDROID` block — `FolinoEditorJNI` product + target + plugins. |
| `Android/settings.gradle.kts` | Task 6: `include(":FolinoEditorAndroid")`. |
| `Packages/Features/Editor/Tests/EditorCoreTests/` | Task 1's new suite. |
| `docs/engineering/ios-android-parity.md` | Task 10: regenerated from the marker Task 10 adds. |

**Deliberately NOT touched by SP3**: `Android/FolinoReaderAndroid/**` (SP4 wires the relay into the Reader),
`Packages/Features/Editor/Sources/Editor/**` (iOS UI), and the save path (SP5).

---

# Part A — Folino Swift: the bridge (Tasks 1–5)

### Task 1: Record applied intents, opt-in

The core applies intents; only an Android host needs to know *which* ones, and it needs them as a list it can drain
because one op can apply more than one intent (`writeRest` over a note falls back to `deleteSelection`, and a future
op may bundle). A closure seam was rejected: the bridge calls the op and then reads state, so a pull is the shape
that matches, and a stored array is trivially testable. Recording is off by default so iOS — which never drains —
cannot accumulate.

**Files:**
- Modify: `Packages/Features/Editor/Sources/EditorCore/EditorSessionCore.swift`
- Test: `Packages/Features/Editor/Tests/EditorCoreTests/EditorRelayRecordingTests.swift`

**Interfaces:**
- Consumes: `EditorSessionCore.apply(_:) -> EditIntent?` (SP2's choke point), `beginSession(score:)`.
- Produces:
  - `EditorSessionCore.init(scoreItem:scoresDirectory:fileFacts:writer:recordsRelayIntents:)` — the new parameter
    defaults to `false`.
  - `EditorSessionCore.takeRelayIntents() -> [EditIntent]` — drains and returns; empty when recording is off.

- [ ] **Step 1: Write the failing test**

`Packages/Features/Editor/Tests/EditorCoreTests/EditorRelayRecordingTests.swift`:

```swift
import Domain
import Foundation
import SheetMusicCore
import Testing

@testable import EditorCore

/// The Android relay's contract on the core: it must be able to learn exactly which intents landed, in order, and
/// nothing else — a refused edit relays nothing (or the mirror diverges), and undo/redo relay as their own native
/// calls rather than as intents.
@Suite struct EditorRelayRecordingTests {
    @Test func recordingIsOffByDefault() {
        let core = EditorCoreFixtures.makeCore()
        core.beginSession(score: EditorCoreFixtures.twoBarScore())
        core.select(EditorCoreFixtures.firstRestItem(in: core.score!))
        core.setDuration(.quarter)
        core.inputPitch(letter: "C")
        #expect(core.takeRelayIntents().isEmpty)
    }

    @Test func anAppliedIntentIsRecordedOnce() {
        let core = EditorCoreFixtures.makeCore(recordsRelayIntents: true)
        core.beginSession(score: EditorCoreFixtures.twoBarScore())
        core.select(EditorCoreFixtures.firstRestItem(in: core.score!))
        core.setDuration(.quarter)
        core.inputPitch(letter: "C")
        let drained = core.takeRelayIntents()
        #expect(drained.count == 1)
        if case .inputNote = drained[0] {} else { Issue.record("expected .inputNote, got \(drained[0])") }
    }

    @Test func drainingLeavesNothingBehind() {
        let core = EditorCoreFixtures.makeCore(recordsRelayIntents: true)
        core.beginSession(score: EditorCoreFixtures.twoBarScore())
        core.select(EditorCoreFixtures.firstRestItem(in: core.score!))
        core.setDuration(.quarter)
        core.inputPitch(letter: "C")
        _ = core.takeRelayIntents()
        #expect(core.takeRelayIntents().isEmpty)
    }

    @Test func aRefusedIntentIsNotRecorded() {
        let core = EditorCoreFixtures.makeCore(recordsRelayIntents: true)
        core.beginSession(score: EditorCoreFixtures.twoBarScore())
        // No selection and no caret: every op is inert, so nothing may be relayed.
        core.inputPitch(letter: "C")
        core.deleteSelection()
        #expect(core.takeRelayIntents().isEmpty)
    }

    @Test func undoAndRedoRecordNothing() {
        let core = EditorCoreFixtures.makeCore(recordsRelayIntents: true)
        core.beginSession(score: EditorCoreFixtures.twoBarScore())
        core.select(EditorCoreFixtures.firstRestItem(in: core.score!))
        core.setDuration(.quarter)
        core.inputPitch(letter: "C")
        _ = core.takeRelayIntents()
        core.undo()
        core.redo()
        #expect(core.takeRelayIntents().isEmpty)
    }

    @Test func beginningASessionClearsWhatTheLastOneLeft() {
        let core = EditorCoreFixtures.makeCore(recordsRelayIntents: true)
        core.beginSession(score: EditorCoreFixtures.twoBarScore())
        core.select(EditorCoreFixtures.firstRestItem(in: core.score!))
        core.setDuration(.quarter)
        core.inputPitch(letter: "C")
        core.beginSession(score: EditorCoreFixtures.twoBarScore())
        #expect(core.takeRelayIntents().isEmpty)
    }
}
```

If `EditorCoreFixtures` does not already expose `makeCore(recordsRelayIntents:)`, `twoBarScore()` and
`firstRestItem(in:)`, add exactly those three to
`Packages/Features/Editor/Tests/EditorCoreTests/Support/EditorCoreFixtures.swift` in this step, reusing whatever the
existing `SelectionRederivationTests` fixtures already build rather than inventing a second score.

- [ ] **Step 2: Run it and watch it fail**

```sh
cd Packages/Features/Editor
xcodebuild test -scheme Editor-Package \
    -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation \
    -only-testing:Editor-Package/EditorRelayRecordingTests
```

Expected: compile failure — `extra argument 'recordsRelayIntents' in call`, `value of type 'EditorSessionCore' has no
member 'takeRelayIntents'`.

- [ ] **Step 3: Implement**

In `EditorSessionCore.swift`, beside `pendingAudition` (they are the same kind of thing — a request the host drains):

```swift
    /// The intents applied since the host last drained them, in the order they landed.
    ///
    /// Android only, and off unless asked for. An Android host is authoritative for the score and must replay every
    /// landed intent into the mirror session behind ssm's score handle; iOS has no mirror and never drains, so
    /// recording unconditionally would grow this array for the life of a session. Refused intents are absent by
    /// construction — `apply` records only on the success path — which is the property the relay depends on: a
    /// refusal that reached the mirror would diverge the two copies.
    ///
    /// Undo and redo are deliberately NOT recorded. The mirror keeps its own stacks (it was fed identical intents),
    /// so they relay as `nativeEditUndo` / `nativeEditRedo`, not as replayed edits.
    private var relayIntents: [EditIntent] = []

    /// Whether this core records what it applies. Set once at construction by the Android bridge.
    private let recordsRelayIntents: Bool
```

Extend the initializer (keep the existing parameter order; append the new one with its default so no iOS call site
changes):

```swift
    public init(
        scoreItem: ScoreItem,
        scoresDirectory: URL,
        fileFacts: any FileFactsProviding,
        writer: any ScoreFileWriting,
        recordsRelayIntents: Bool = false,
    ) {
        self.scoreItem = scoreItem
        self.scoresDirectory = scoresDirectory
        self.fileFacts = fileFacts
        self.writer = writer
        self.recordsRelayIntents = recordsRelayIntents
    }
```

In `apply`, record on the success path only:

```swift
    @discardableResult
    public func apply(_ intent: EditIntent) -> EditIntent? {
        guard let session, session.apply(intent) else { return nil }
        revision += 1
        appliedIntentCount += 1
        if recordsRelayIntents { relayIntents.append(intent) }
        rederiveSelection()
        isDirty = true
        return intent
    }
```

In `beginSession`, beside the other resets:

```swift
        relayIntents.removeAll()
```

And the drain, next to `takePendingAudition()`:

```swift
    /// Takes the intents applied since the last call, leaving none behind. The Android bridge calls this after every
    /// op and hands the frames to Kotlin to relay; see `EditorBridge.sync()`.
    public func takeRelayIntents() -> [EditIntent] {
        defer { relayIntents.removeAll() }
        return relayIntents
    }
```

- [ ] **Step 4: Run the new suite, then the whole package**

```sh
cd Packages/Features/Editor
xcodebuild test -scheme Editor-Package \
    -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation
```

Expected: the new suite passes and **every pre-existing `EditorTests` / `EditorCoreTests` test still passes** — this
task must be invisible to iOS.

- [ ] **Step 5: Commit**

```sh
git add Packages/Features/Editor/Sources/EditorCore/EditorSessionCore.swift \
        Packages/Features/Editor/Tests/EditorCoreTests
git commit -m "feat(editor): let a host learn which intents landed, opt-in"
```

---

### Task 2: `FolinoEditorJNI` — the target, and a session that opens and closes

The bridge before it has any ops: the manifest entry, the two seams, and a lifecycle that can be gated. Splitting the
lifecycle out from the ops keeps the first cross-compile — which is where the toolchain, the plugins and the linker
have their say — small enough to debug.

**Files:**
- Modify: `Packages/Features/Editor/Package.swift`
- Create: `Packages/Features/Editor/Sources/FolinoEditorJNI/EditorBridge.swift`
- Create: `Packages/Features/Editor/Sources/FolinoEditorJNI/EditorBridgeWires.swift`
- Create: `Packages/Features/Editor/Sources/FolinoEditorJNI/EditorAndroidSeams.swift`
- Create: `Packages/Features/Editor/Sources/FolinoEditorJNI/swift-java.config`

**Interfaces:**
- Consumes: `EditorSessionCore.init(…recordsRelayIntents:)` and `takeRelayIntents()` (Task 1);
  `SheetMusicCore.SheetMusicEngine.versionStamp`; `SheetMusicCore.Score.stableFingerprint`;
  `SheetMusicMSCX` for parse/encode; `SheetMusicEditWire.EditIntentCodec` / `ScoreItemIDCodec`.
- Produces (Task 3, 4, 6, 7 all build on these names):
  - `@WireFormat EditBytesWire { var bytes: Data }`
  - `@WireletProvided protocol EditorHostFiles` with `func sha256Hex(path: String) -> String` and
    `func fileSize(path: String) -> Int64`
  - `@WireletObservable final class EditorBridge`, `init(files: EditorHostFiles)`
  - `@WireletExpose func engineVersionStamp() -> Int64`
  - `@WireletExpose func beginSession(scorePath: String, scoresDirectory: String, scoreId: String) -> Bool`
  - `@WireletExpose func endSession()`
  - `@WireletExpose func scoreFingerprint() -> Int64`
  - `@WireletExpose func encodeScore() -> EditBytesWire`
  - observable `isSessionActive: Bool`

- [ ] **Step 1: Add the target to the manifest**

In `Packages/Features/Editor/Package.swift`, wrap the existing `let package = Package(…)` in the same
`isAndroid` shape `Packages/Features/Reader/Package.swift` uses. Read that file and mirror it exactly — the
`FOLINO_ANDROID` env read, the `var packageDependencies / products / targets` build-up, and the `if isAndroid` block.
The Editor-specific parts:

```swift
if isAndroid {
    packageDependencies += [
        .package(url: "https://github.com/swiftlang/swift-java.git", exact: "0.4.0"),
        // swift-java 0.4.0's SwiftJavaTool is written against swift-subprocess 0.4.x; 0.5.0 removed APIs the
        // jextract tool needs under swift-6.3.3. Pin to 0.4.0 (matches Reader / Settings / Library).
        .package(url: "https://github.com/swiftlang/swift-subprocess.git", exact: "0.4.0"),
        .package(
            url: "https://github.com/jiyimeta/swift-wirelet.git",
            revision: "ba1b8e337a508079c5213656e4c01e9edbedc8b4",
        ),
    ]
    products += [
        .library(
            name: "FolinoEditorJNI",
            type: .dynamic,
            targets: ["FolinoEditorJNI"],
        ),
    ]
    targets += [
        .target(
            name: "FolinoEditorJNI",
            dependencies: [
                "Domain",
                "EditorCore",
                // The score this session edits is parsed and re-encoded inside THIS image: spec §3 — a `Score`
                // cannot cross between the two `SheetMusicCore` copies in the process, only bytes can.
                .product(name: "SheetMusicMSCX", package: "swift-sheet-music"),
                // The intent wire has exactly one declaration, in ssm, and both `.so`s link it (spec §5.4).
                .product(name: "SheetMusicEditWire", package: "swift-sheet-music"),
                .product(name: "SwiftJava", package: "swift-java"),
                .product(name: "Wirelet", package: "swift-wirelet"),
                .product(name: "WireletObservable", package: "swift-wirelet"),
                .product(name: "WireletProvided", package: "swift-wirelet"),
            ],
            exclude: [
                "swift-java.config",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ],
            plugins: [
                .plugin(name: "JExtractSwiftPlugin", package: "swift-java"),
                .plugin(name: "WireletObservableBridges", package: "swift-wirelet"),
                .plugin(name: "WireletProvidedBridges", package: "swift-wirelet"),
            ],
        ),
    ]
}
```

Copy `Packages/Features/Reader/Sources/FolinoReaderJNI/swift-java.config` to
`Packages/Features/Editor/Sources/FolinoEditorJNI/swift-java.config`, changing only the `javaPackage` to
`com.keynumber.folino.editor.generated`.

- [ ] **Step 2: Check both manifest shapes still resolve**

```sh
swift package describe --package-path Packages/Features/Editor >/dev/null
FOLINO_ANDROID=1 swift package describe --package-path Packages/Features/Editor >/dev/null
```

Expected: both exit 0. (The Android shape needs `swift package resolve` to fetch swift-java / swift-wirelet the first
time; let it.) A failure here is a manifest error, not a code error — fix it before writing any Swift.

- [ ] **Step 3: The wire type**

`Packages/Features/Editor/Sources/FolinoEditorJNI/EditorBridgeWires.swift`:

```swift
import Foundation
import Wirelet

/// An opaque byte frame crossing the Kotlin boundary in either direction.
///
/// Two things travel this way and neither is Kotlin's business: the intent bytes an op produced (encoded by ssm's
/// `EditIntentCodec`, decoded by ssm's `.so`), and the `ScoreItemID` a tap resolved to (encoded by ssm's
/// `ScoreItemIDCodec` on the far side, decoded here). Kotlin relays them; it never looks inside. That is the whole
/// point of crossing an intent rather than a command — see spec §4.2 and SP0's finding that a Kotlin-side encoder
/// was the wrong shape from the start.
///
/// A wrapper struct rather than a bare `Data` parameter because swift-wirelet's `InvokeArgClassifier` has no `Data`
/// case: a bare `Data` classifies as a `@WireFormat` type named `Data` and fails to generate. `Data` as a *field* of
/// a `@WireFormat` struct is supported and already in use (`DrawingAnchorWire.encodedDrawing`).
@WireFormat
public struct EditBytesWire {
    public var bytes: Data

    public init(bytes: Data) {
        self.bytes = bytes
    }
}
```

- [ ] **Step 4: The host seam**

`Packages/Features/Editor/Sources/FolinoEditorJNI/EditorAndroidSeams.swift`:

```swift
import Domain
import EditorCore
import Foundation
import SheetMusicCore
import WireletProvided

/// What only Kotlin can do for this session.
///
/// `EditorFileFacts` on iOS is CryptoKit, which does not exist on Android, so the digest comes back over the wire
/// exactly as `LibraryAndroidStore` already sources it for import. **The hex format is load-bearing**: it has to
/// match what the importer wrote, or every save makes the library think it is looking at a new file.
@WireletProvided
public protocol EditorHostFiles {
    func sha256Hex(path: String) -> String
    func fileSize(path: String) -> Int64
}

/// Routes `FileFactsProviding` through the Kotlin seam.
///
/// `@unchecked Sendable` for the same reason `WireletBackedBlobStore` is: the wrapped `@WireletProvided` proxy is a
/// thin JNI forwarder that is not intrinsically `Sendable`, and the only holder is one `EditorSessionCore` driven
/// from one JNI call at a time.
struct HostFileFacts: FileFactsProviding, @unchecked Sendable {
    let files: EditorHostFiles

    func hashAndSize(of url: URL) throws -> (contentHash: String, sizeBytes: Int64) {
        (files.sha256Hex(path: url.path), files.fileSize(path: url.path))
    }
}

/// The writer seam, unimplemented in SP3 by design.
///
/// SP5 owns persistence: the MSCZ encode plus the POSIX write, and the Room row refresh behind a second
/// `@WireletProvided` method. Until then nothing calls it — the bridge never schedules a save and never flushes one.
///
/// **Android's `refreshRow` will be a partial update, and that is decided here rather than in SP5.** It writes
/// exactly the three columns a save derives — `localFileName`, `contentHash`, `sizeBytes` — keyed on the row's id,
/// which is what `ScoreFileWriting`'s own doc comment asks for ("so the list shows the new size and digest"). That
/// decision is what makes the stub row below permanently harmless, and it is the reason no `ScoreItem` wire
/// projection has to exist: a 20-field hand-maintained duplicate of a Domain type is exactly the drift §5.4 is
/// about. iOS keeps its whole-row repository write; the seam is per-platform by construction.
///
/// `preconditionFailure` rather than a thrown error, on purpose. `performSave` catches everything and keeps
/// `isDirty` true, so a thrown "unimplemented" is indistinguishable from a retriable save failure — it would just
/// mark the session permanently dirty and say nothing. A call here is a plan violation, not a runtime condition, and
/// a dev-time crash that names the plan beats a flag nobody reads. (`SheetMusicError.invalidEdit` in particular
/// would be the least honest spelling available: it is the one error this feature deliberately swallows as benign.)
struct UnimplementedScoreWriter: ScoreFileWriting, @unchecked Sendable {
    func write(_: Score, to _: URL, format _: ScoreFormat) async throws {
        preconditionFailure("persistence is SP5's; nothing may reach ScoreFileWriting before it lands")
    }

    func refreshRow(_: ScoreItem) async throws {
        preconditionFailure("persistence is SP5's; nothing may reach ScoreFileWriting before it lands")
    }
}
```

- [ ] **Step 5: The bridge, with lifecycle only**

`Packages/Features/Editor/Sources/FolinoEditorJNI/EditorBridge.swift`:

```swift
import Domain
import EditorCore
import Foundation
import Observation
import SheetMusicCore
import SheetMusicEditWire
import SheetMusicMSCX
import WireletObservable

/// Android's face of one editing session: the authoritative `EditorSessionCore`, plus the projection Compose reads
/// and the intent frames Kotlin relays to the mirror.
///
/// The Apple counterpart is `EditorViewModel`, and the two are deliberately the same shape — call an op, then
/// re-read everything the core owns in one `sync()`. What differs is only what "publish" means: `@Observable`
/// properties there, `@WireletObservable` StateFlows here, plus the one thing iOS has no need of — the relay queue.
///
/// **This class holds no concurrency.** No `Task`, no `MainActor`. An Android JNI process pumps no main runloop, so
/// a `Task { @MainActor in … }` here would be created and never run (the bug `AnnotationSaveBridge.open` records).
/// Every op is synchronous, and the two things that are not — auditioning and autosave — stay requests the host
/// drains, exactly as `EditorSessionCore` leaves them.
@WireletObservable
@Observable
public final class EditorBridge {
    @ObservationIgnored private var core: EditorSessionCore?
    @ObservationIgnored private let files: EditorHostFiles
    /// Frames produced by the last op, waiting for `takeRelayFrames()`. Held here rather than drained straight into
    /// a return value because `sync()` runs after every op, including the ones that return nothing.
    @ObservationIgnored private var relayFrames: [EditBytesWire] = []

    public private(set) var isSessionActive = false

    public init(files: EditorHostFiles) {
        self.files = files
    }

    // MARK: - Gates

    /// This image's build identity, for the §8.1 skew gate. The caller compares it with ssm's
    /// `nativeEngineVersionStamp()` and refuses to open a session on a mismatch: two different builds of
    /// `SheetMusicCore` cannot be trusted to plan an intent the same way, and every guarantee in this design rests
    /// on their doing so.
    @WireletExpose
    public func engineVersionStamp() -> Int64 {
        SheetMusicEngine.versionStamp
    }

    /// The authoritative score's digest, for the §8.3 divergence check. `0` outside a session — the caller treats
    /// that as a mismatch, which is correct: there is nothing to agree with.
    @WireletExpose
    public func scoreFingerprint() -> Int64 {
        core?.score?.stableFingerprint ?? 0
    }

    // MARK: - Lifecycle

    /// Opens a session over the score at `scorePath`, parsed in THIS image.
    ///
    /// Parsed rather than received: spec §3 — the two `SheetMusicCore` copies in the process cannot pass a `Score`
    /// between them. The invariant that makes the relay sound is that both sides start from the same score, and they
    /// do because both parse the same file with the same parser (§4).
    ///
    /// Returns `false` when the file cannot be read or parsed; the caller must not proceed to
    /// `nativeBeginEditSession` in that case — begin/end are paired across both sides, and a mirror opened against
    /// an authoritative session that never opened would answer `false` to the first relayed undo while the
    /// authoritative score had already moved (SP0's finding).
    @WireletExpose
    public func beginSession(scorePath: String, scoresDirectory: String, scoreId: String) -> Bool {
        guard let score = Self.parseScore(atPath: scorePath) else { return false }
        let item = Self.stubRowPendingSave(id: scoreId, localFileName: URL(fileURLWithPath: scorePath).lastPathComponent)
        let core = EditorSessionCore(
            scoreItem: item,
            scoresDirectory: URL(fileURLWithPath: scoresDirectory),
            fileFacts: HostFileFacts(files: files),
            writer: UnimplementedScoreWriter(),
            recordsRelayIntents: true,
        )
        core.beginSession(score: score)
        self.core = core
        relayFrames = []
        sync()
        return true
    }

    /// Drops the session. The host flushes any pending save first — SP5's job; there is nothing to flush yet.
    @WireletExpose
    public func endSession() {
        core?.endSession()
        core = nil
        relayFrames = []
        sync()
    }

    /// The authoritative score as `.mscz` bytes, for the §8.3 resync: the caller loads them into a fresh ssm handle
    /// and swaps. This is the recovery path the spec's rejected "re-encode and reload per edit" alternative is
    /// exactly right for — as a rare full resync rather than as the per-keystroke mechanism.
    @WireletExpose
    public func encodeScore() -> EditBytesWire {
        guard let score = core?.score, let data = try? MSCZWriter.data(from: score) else {
            return EditBytesWire(bytes: Data())
        }
        return EditBytesWire(bytes: data)
    }

    // MARK: - The mirror

    /// Re-reads everything the core owns and queues whatever it applied. The Android counterpart of
    /// `EditorViewModel.syncFromCore()`; Task 3 fills in the rest of the projection.
    func sync() {
        isSessionActive = core?.isSessionActive ?? false
        guard let core else { return }
        relayFrames.append(contentsOf: core.takeRelayIntents().map {
            EditBytesWire(bytes: EditIntentCodec.encode($0))
        })
    }

    private static func parseScore(atPath path: String) -> Score? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? ScoreFileParsing.parse(data: data, filename: URL(fileURLWithPath: path).lastPathComponent)
    }

    /// A deliberately partial library row, named so nobody mistakes it for a real one.
    ///
    /// Only two fields are real: the id, which keys the Room row, and the file name, which is what decides
    /// `.mscx`/`.mscz`-in-place versus a sibling `.mscz`. Every other field is a neutral placeholder.
    ///
    /// **That is safe only because Android's `refreshRow` is a partial update of the three save-derived columns**
    /// — see `UnimplementedScoreWriter`, which is where that decision is written down. Note that
    /// `EditorSessionCore.performSave` rebuilds the row from EVERY field of this value before calling
    /// `refreshRow`, so a whole-row Android writer would push these placeholders over the user's real title, tags
    /// and dates. The two halves are one safety; do not implement either without the other.
    private static func stubRowPendingSave(id: String, localFileName: String) -> ScoreItem { … }
}
```

Three blanks to fill from the actual APIs rather than from this plan:

1. **`ScoreFileParsing.parse(data:filename:)` is a placeholder name.** The real one is
   `MSCZReader.parse(contentsOf: URL)` from `SheetMusicMSCX` — it dispatches on the file's own format, which is why
   `LibraryAndroidStore` runs every pickable format through it
   (`Packages/Features/Library/Sources/FolinoLibraryJNI/LibraryAndroidStore.swift:309`, `:521`, `:1068`). Mirror that
   call; do not write a second format-dispatch ladder.
2. **`ScoreItem(…)`** — most fields have defaults; the ones you must pass are `title`, `composer`,
   `instrumentationSummary`, `localFileName`, `contentHash`, `sizeBytes`, `lengthBeats`, `defaultTempoBpm`,
   `primaryKey`, `addedAt`, `lastOpenedAt`, `tagIDs`, `isFavorite`
   (`Packages/Domain/Sources/Domain/Models/ScoreItem.swift:52`). Read the type before writing the call. `id` is a
   `ScoreItemID(rawValue: UUID)` — parse `scoreId`, and fall back to a fresh `UUID()` if it does not parse, exactly
   as `AnnotationSaveBridge.open(scoreId:)` does.
3. **`MSCZWriter.data(from:)` is a placeholder name.** The API Folino already uses is
   `MSCZWriter.write(score:options:to:)`, which writes to a URL rather than returning bytes
   (`LibraryAndroidStore.swift:566`, `Packages/Infrastructure/Sources/ScoreFiles/LiveScoreShareService.swift:135`).
   If `SheetMusicMSCX` exposes no data-returning variant, write to a temporary file under `FileManager`'s temp
   directory, read it back, and delete it — and say so in a comment, because a round trip through the disk for a
   resync is worth a reader knowing about. Use the same `MSCXEncoderOptions(targetVersion:)` the Library passes.

- [ ] **Step 6: Cross-compile just this much**

```sh
export PATH="/Library/Developer/Toolchains/swift-6.3.3-RELEASE.xctoolchain/usr/bin:$PATH"
FOLINO_ANDROID=1 swift build --package-path Packages/Features/Editor \
    --product FolinoEditorJNI --swift-sdk aarch64-unknown-linux-android28 -c release
```

Expected: builds. Common first failures and what they mean:
- `no such module 'SheetMusicUI'` → the `Editor` (Apple) target got pulled into the Android graph; the JNI target
  must depend on `EditorCore`, never on `Editor`.
- A wirelet plugin diagnostic about an unrepresentable type → a `@WireletExpose` signature used something outside
  `InvokeArgClassifier`'s vocabulary (primitives, `Bool`, `String`, `@WireFormat` structs, optionals of those,
  arrays of `@WireFormat`). `Data` is *not* in it — that is what `EditBytesWire` is for.
- `type 'ScoreItemID?' has no member 'rest'` (or similar, several lines from the real cause) → `Domain` has its own
  `ScoreItemID` and a bare `import Domain` wins. Write `SheetMusicCore.ScoreItemID` explicitly. This bit SP2 and it
  will bite here.

- [ ] **Step 7: Verify iOS is untouched**

```sh
cd Packages/Features/Editor
xcodebuild test -scheme Editor-Package \
    -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation
```

Expected: green, and the build log mentions no `FolinoEditorJNI` — `FOLINO_ANDROID` is unset, so the target does not
exist in that shape.

- [ ] **Step 8: Commit**

```sh
git add Packages/Features/Editor/Package.swift Packages/Features/Editor/Sources/FolinoEditorJNI
git commit -m "feat(editor): open an Android edit session over the score in this image"
```

---

### Task 3: The op vocabulary and the projection

Everything the pad, the callout and the app bar will call in SP4, plus everything they read. One method per op, each
one line of delegation and then `sync()` — the discipline that makes it impossible for an op to mutate the score
without queueing its relay frames.

**Files:**
- Create: `Packages/Features/Editor/Sources/FolinoEditorJNI/EditorBridge+Ops.swift`
- Modify: `Packages/Features/Editor/Sources/FolinoEditorJNI/EditorBridge.swift` (the projection properties + `sync`)

**Interfaces:**
- Consumes: `EditorSessionCore`'s public ops — `inputPitch(letter:)`, `deleteSelection()`, `writeRest()`,
  `setDuration(_:)`, `toggleArmedDot()`, `setArmedDots(_:)`, `setSelectionDuration(_:)`, `setSelectionDots(_:)`,
  `toggleSelectionDot()`, `shiftPitch(bySemitones:)`, `shiftOctave(by:)`, `setAccidental(_:)`,
  `toggleAddToChord()`, `removeSelectedNoteFromChord()`, `toggleTie()`, `appendTiedNote()`,
  `createTuplet(actualNotes:)`, `removeTuplet()`, `selectPreviousElement()`, `selectNextElement()`,
  `undo()`, `redo()`, `activeVoice`, `isPlaybackActive`.
- Produces: the observable projection Task 6's generated view model exposes as StateFlows, and Task 7 reads —
  `revision`, `appliedIntentCount`, `selectionRevision`, `canUndo`, `canRedo`, `hasEditTarget`, `isNoteSelected`,
  `hasSelectionCallout`, `armedDurationKind`, `armedDots`, `isAddToChordArmed`, `armedTuplet`,
  `calloutDurationKind`, `calloutDots`, `canTie`, `isSelectionTied`, `canAppendTiedNote`, `isCaretInTuplet`,
  `canWriteRest`, `activeVoice`; plus `@WireletExpose func takeRelayFrames() -> [EditBytesWire]`.

- [ ] **Step 1: The projection**

Add to `EditorBridge` (all `public private(set) var`, all primitives — swift-wirelet's observable property kinds are
primitives, `String`, `@WireFormat` types and optionals/arrays of those, and a primitive keeps the Kotlin side free
of a codec it would only have to keep in step):

```swift
    // MARK: - The projection Compose reads
    //
    // Counters first, for the same reason `EditorViewModel` keeps them: `revision` bumps on apply/undo/redo and is
    // what a relayout keys off; `appliedIntentCount` bumps ONLY on a genuine apply; `selectionRevision` bumps on
    // every placement, changed or not, so a repeat placement is not silently swallowed.
    public private(set) var revision: Int32 = 0
    public private(set) var appliedIntentCount: Int32 = 0
    public private(set) var selectionRevision: Int32 = 0

    public private(set) var canUndo = false
    public private(set) var canRedo = false

    public private(set) var hasEditTarget = false
    public private(set) var isNoteSelected = false
    public private(set) var hasSelectionCallout = false
    public private(set) var canWriteRest = false
    public private(set) var canTie = false
    public private(set) var isSelectionTied = false
    public private(set) var canAppendTiedNote = false
    public private(set) var isCaretInTuplet = false

    /// The armed length as `NoteDurationWire`'s discriminator (1 = whole … 9 = 256th, 10 = measure, 11 = fraction),
    /// or 0 for "nothing armed". Deliberately ssm's numbering rather than a second one of our own: the same integer
    /// already crosses this process inside every relayed intent, and two spellings of one enum is exactly the drift
    /// spec §5.4 exists to prevent.
    public private(set) var armedDurationKind: Int32 = 0
    public private(set) var armedDots: Int32 = 0
    public private(set) var isAddToChordArmed = false
    public private(set) var armedTuplet: Int32 = 3

    /// The SELECTED element's own length, in the same numbering — what the callout shows. Distinct from the armed
    /// length, which describes the next note rather than this one.
    public private(set) var calloutDurationKind: Int32 = 0
    public private(set) var calloutDots: Int32 = 0

    /// Mirrored both ways: Kotlin sets it from the voice selector, the core reads it when planning input.
    public private(set) var activeVoice: Int32 = 0
```

and the mapping helper, in `EditorBridge+Ops.swift`:

```swift
    /// `NoteDuration` → `NoteDurationWire`'s discriminator. Kept here rather than reaching into ssm's wire struct so
    /// the projection has no dependency on a type whose Kotlin model is not generated for this module; the numbering
    /// is the contract, and the tests in `EditIntentCodecTests` are what pin it.
    static func durationKind(_ duration: NoteDuration?) -> Int32 {
        switch duration {
        case .none: 0
        case .whole: 1
        case .half: 2
        case .quarter: 3
        case .eighth: 4
        case .sixteenth: 5
        case .thirtySecond: 6
        case .sixtyFourth: 7
        case .oneTwentyEighth: 8
        case .twoFiftySixth: 9
        case .measure: 10
        case .fraction: 11
        }
    }
```

Fill in the rest of `sync()`:

```swift
    func sync() {
        isSessionActive = core?.isSessionActive ?? false
        guard let core else {
            // Reset EVERYTHING the session owned. An asymmetric reset — clearing the booleans but leaving the armed
            // length and the counters behind — reads as a bug even where it is inert, and one of these is not inert:
            // Compose keeps collecting these StateFlows after a session ends, so a stale `armedDurationKind` lights
            // a pad key for a session that no longer exists. `armedTuplet` is the one exception and stays put: the
            // core deliberately survives `beginSession` with it, because it is a preference about how you are
            // writing rather than state about one score.
            revision = 0
            appliedIntentCount = 0
            selectionRevision = 0
            canUndo = false
            canRedo = false
            hasEditTarget = false
            isNoteSelected = false
            hasSelectionCallout = false
            canWriteRest = false
            canTie = false
            isSelectionTied = false
            canAppendTiedNote = false
            isCaretInTuplet = false
            armedDurationKind = 0
            armedDots = 0
            isAddToChordArmed = false
            calloutDurationKind = 0
            calloutDots = 0
            activeVoice = 0
            selectedItemFrame = nil
            caretItemFrame = nil
            return
        }
        revision = Int32(core.revision)
        appliedIntentCount = Int32(core.appliedIntentCount)
        selectionRevision = Int32(core.selectionRevision)
        canUndo = core.canUndo
        canRedo = core.canRedo
        hasEditTarget = core.hasEditTarget
        isNoteSelected = core.isNoteSelected
        hasSelectionCallout = core.hasSelectionCallout
        canWriteRest = core.canWriteRest
        canTie = core.canTie
        isSelectionTied = core.isSelectionTied
        canAppendTiedNote = core.canAppendTiedNote
        isCaretInTuplet = core.isCaretInTuplet
        armedDurationKind = Self.durationKind(core.armedDuration)
        armedDots = Int32(core.armedDots)
        isAddToChordArmed = core.isAddToChordArmed
        armedTuplet = Int32(core.armedTuplet)
        calloutDurationKind = Self.durationKind(core.selectedDuration?.base)
        calloutDots = Int32(core.selectedDuration?.dots ?? 0)
        activeVoice = Int32(core.activeVoice)
        selectedItemFrame = Self.frame(for: core.selectedItem)
        caretItemFrame = Self.frame(for: core.caretItem)
        relayFrames.append(contentsOf: core.takeRelayIntents().map {
            EditBytesWire(bytes: EditIntentCodec.encode($0))
        })
    }
```

(`selectedItemFrame` / `caretItemFrame` and `Self.frame(for:)` arrive in Task 4; add the two stored properties as
`public private(set) var … : EditBytesWire?` now so `sync` compiles, and let Task 4 fill the mapping.)

- [ ] **Step 2: The ops**

`Packages/Features/Editor/Sources/FolinoEditorJNI/EditorBridge+Ops.swift`. Every one has the same body shape — do
the thing, then `sync()` — and none of them decides anything:

```swift
import EditorCore
import Foundation
import SheetMusicCore
import WireletObservable

/// The op vocabulary Compose calls. One method per key, and every one of them is
/// "ask the core, then re-read the core" — the decisions all live in `EditorSessionCore`, shared with iOS.
///
/// **Nothing here may branch on score content.** A conditional in this file is a rule that exists on Android and not
/// on iOS, which is precisely what the repo's parity rule forbids; if a key needs to decide something, the decision
/// belongs in `EditorCore` where both platforms get it.
extension EditorBridge {
    // MARK: - Pad keys

    /// A letter key C…B. `letter` is a one-character string because the wire has no `Character`; a longer string
    /// takes its first character, and an empty one is inert.
    @WireletExpose
    public func inputPitch(letter: String) {
        guard let character = letter.first else { return }
        core?.inputPitch(letter: character)
        sync()
    }

    @WireletExpose
    public func deleteSelection() {
        core?.deleteSelection()
        sync()
    }

    @WireletExpose
    public func writeRest() {
        core?.writeRest()
        sync()
    }

    /// Arms a length by `NoteDurationWire`'s discriminator (see `durationKind`). Unknown values are ignored rather
    /// than defaulted — arming the wrong length silently is worse than not arming.
    @WireletExpose
    public func armDuration(kind: Int32) {
        guard let duration = Self.duration(fromKind: kind) else { return }
        core?.setDuration(duration)
        sync()
    }

    @WireletExpose
    public func toggleArmedDot() {
        core?.toggleArmedDot()
        sync()
    }

    @WireletExpose
    public func setArmedDots(_ dots: Int32) {
        core?.setArmedDots(Int(dots))
        sync()
    }

    // MARK: - Callout keys (the selected element's own length)

    @WireletExpose
    public func setSelectionDuration(kind: Int32) {
        guard let duration = Self.duration(fromKind: kind) else { return }
        core?.setSelectionDuration(duration)
        sync()
    }

    @WireletExpose
    public func setSelectionDots(_ dots: Int32) {
        core?.setSelectionDots(Int(dots))
        sync()
    }

    @WireletExpose
    public func toggleSelectionDot() {
        core?.toggleSelectionDot()
        sync()
    }

    // MARK: - Pitch

    @WireletExpose
    public func shiftPitch(bySemitones delta: Int32) {
        core?.shiftPitch(bySemitones: Int(delta))
        sync()
    }

    @WireletExpose
    public func shiftOctave(by octaves: Int32) {
        core?.shiftOctave(by: Int(octaves))
        sync()
    }

    /// `raw` is the accidental's raw value, or the empty string for "none" (natural is its own raw value, and is not
    /// the same thing as none — none removes the accidental, natural writes one).
    @WireletExpose
    public func setAccidental(raw: String) {
        core?.setAccidental(raw.isEmpty ? nil : Accidental(rawValue: raw))
        sync()
    }

    // MARK: - Chord, tie, tuplet (second pass in the UI; the ops exist from the start)

    @WireletExpose
    public func toggleAddToChord() {
        core?.toggleAddToChord()
        sync()
    }

    @WireletExpose
    public func removeSelectedNoteFromChord() {
        core?.removeSelectedNoteFromChord()
        sync()
    }

    @WireletExpose
    public func toggleTie() {
        core?.toggleTie()
        sync()
    }

    @WireletExpose
    public func appendTiedNote() {
        core?.appendTiedNote()
        sync()
    }

    @WireletExpose
    public func createTuplet(actualNotes: Int32) {
        core?.createTuplet(actualNotes: Int(actualNotes))
        sync()
    }

    @WireletExpose
    public func removeTuplet() {
        core?.removeTuplet()
        sync()
    }

    // MARK: - Navigation and voice

    @WireletExpose
    public func selectPreviousElement() {
        core?.selectPreviousElement()
        sync()
    }

    @WireletExpose
    public func selectNextElement() {
        core?.selectNextElement()
        sync()
    }

    @WireletExpose
    public func setActiveVoice(_ voice: Int32) {
        core?.activeVoice = Int(voice)
        sync()
    }

    /// Mirrored in from the transport. The core drops the selection when playback starts — the playhead, not the
    /// selection, is where the music is from that moment.
    @WireletExpose
    public func setPlaybackActive(_ active: Bool) {
        core?.isPlaybackActive = active
        sync()
    }

    // MARK: - Undo / redo
    //
    // These do NOT produce relay frames: the mirror keeps its own stacks, fed the same intents, so the host drives
    // them with `nativeEditUndo` / `nativeEditRedo`. Replaying an inverse as an intent would put the two stacks out
    // of step immediately.

    @WireletExpose
    public func undo() {
        core?.undo()
        sync()
    }

    @WireletExpose
    public func redo() {
        core?.redo()
        sync()
    }

    // MARK: - The relay queue

    /// Takes the intent frames produced since the last call, in order. The host relays each one to the mirror with
    /// `nativeApplyEditIntent`, in the same order, before anything reads the mirror's layout.
    @WireletExpose
    public func takeRelayFrames() -> [EditBytesWire] {
        defer { relayFrames.removeAll() }
        return relayFrames
    }

    static func duration(fromKind kind: Int32) -> NoteDuration? {
        switch kind {
        case 1: .whole
        case 2: .half
        case 3: .quarter
        case 4: .eighth
        case 5: .sixteenth
        case 6: .thirtySecond
        case 7: .sixtyFourth
        case 8: .oneTwentyEighth
        case 9: .twoFiftySixth
        case 10: .measure
        default: nil
        }
    }
}
```

`core` and `relayFrames` are `private` on the class; change them to `internal` (no access modifier) so this extension
in the same module can reach them — and no wider, per the repo's access-modifier preference.

- [ ] **Step 3: Cross-compile**

```sh
export PATH="/Library/Developer/Toolchains/swift-6.3.3-RELEASE.xctoolchain/usr/bin:$PATH"
FOLINO_ANDROID=1 swift build --package-path Packages/Features/Editor \
    --product FolinoEditorJNI --swift-sdk aarch64-unknown-linux-android28 -c release
```

Expected: builds. If a `@WireletExpose` signature is rejected, the fix is always the same — express the parameter as
a primitive, a `String`, or an `EditBytesWire`.

- [ ] **Step 4: Confirm the generated Kotlin surface is what SP4 will need**

```sh
ls Packages/Features/Editor/.build/plugins/outputs/editor/FolinoEditorJNI/destination/
```

Read the generated `EditorBridgeViewModel.kt` and check that every op above appears as a function and every
projection property as a StateFlow. A missing member here becomes a mystery in Task 7.

- [ ] **Step 5: Commit**

```sh
git add Packages/Features/Editor/Sources/FolinoEditorJNI
git commit -m "feat(editor): expose the op vocabulary and the state Compose will read"
```

---

### Task 4: Selection in, caret out

A tap is resolved by ssm (it owns the layout), applied by Folino (it owns the session), and drawn by Compose from a
rect ssm computes. All three legs move opaque `ScoreItemID` bytes, so this task is the codec plumbing at both ends.

**Files:**
- Modify: `Packages/Features/Editor/Sources/FolinoEditorJNI/EditorBridge.swift` (the only file — the ops extension
  this plan originally called for does not exist; a `@WireletExpose` method outside the class body is invisible to
  the Kotlin generator, so everything below goes in `EditorBridge.swift`, `selectItem` beside the other ops and the
  two stored properties beside the rest of the projection)

**Interfaces:**
- Consumes: `SheetMusicEditWire.ScoreItemIDCodec.encode/decode`, `EditorSessionCore.select(_:)`.
- Produces:
  - `@WireletExpose func selectItem(frame: EditBytesWire)` — empty bytes mean "tapped paper", i.e. deselect.
  - observable `selectedItemFrame: EditBytesWire?`, `caretItemFrame: EditBytesWire?`.

- [ ] **Step 1: The two mappings**

Task 3 already added `selectedItemFrame` / `caretItemFrame` as stored `EditBytesWire?` properties that `sync()` sets
to `nil`. Replace the doc comment and the assignment with the real mapping:

```swift
    /// The selected item and the caret, as the same `ScoreItemID` bytes ssm speaks.
    ///
    /// Bytes rather than fields because of what the host does with them: `nativeEditingCaretFrame(handle, itemBytes)`
    /// wants exactly this encoding back, and re-projecting the ID into integers here would mean Kotlin re-encoding
    /// it there — a second spelling of ssm's own schema, in Kotlin, which is what §5.4 rules out.
    public private(set) var selectedItemFrame: EditBytesWire?
    public private(set) var caretItemFrame: EditBytesWire?

    static func frame(for item: SheetMusicCore.ScoreItemID?) -> EditBytesWire? {
        item.map { EditBytesWire(bytes: ScoreItemIDCodec.encode($0)) }
    }
```

And beside the other ops, in the same class body:

```swift
    /// A tap, already resolved to an item by `nativeEditingHitTest` — which is also where the hidden-staff
    /// re-addressing happens, so the ID arriving here is in the SCORE's addressing, not the rendered document's.
    ///
    /// Empty bytes mean the tap landed on paper. That deselects, deliberately: the same "a tap off any staff band
    /// clears the selection" policy iOS has had since the hit-test ladder moved into ssm, and the reason
    /// `editingHitTest` answers "nothing" rather than rescuing every near miss.
    @WireletExpose
    public func selectItem(frame: EditBytesWire) {
        guard !frame.bytes.isEmpty else {
            core?.select(nil)
            sync()
            return
        }
        guard let item = try? ScoreItemIDCodec.decode(frame.bytes) else { return }
        core?.select(item)
        sync()
    }
```

Check `ScoreItemIDCodec`'s actual encode/decode signatures in
`Packages/Features/Editor/.build/checkouts/swift-sheet-music/Sources/SheetMusicEditWire/Path/ScoreItemIDCodec.swift`
before writing this — match them exactly rather than assuming `encode(_:) -> Data` / `decode(_:) throws`.

- [ ] **Step 2: Cross-compile**

Same command as Task 3 Step 3. Expected: builds.

- [ ] **Step 3: Commit**

```sh
git add Packages/Features/Editor/Sources/FolinoEditorJNI
git commit -m "feat(editor): carry the tapped item in, the caret out, as ssm's own bytes"
```

---

### Task 5: The build script, and proof the library loads

**Files:**
- Create: `Scripts/android-build-editor-libs.sh`

**Interfaces:**
- Produces: `Android/FolinoEditorAndroid/src/main/jniLibs/<abi>/libFolinoEditorJNI.so` (+ `libSwiftJava.so`, the
  Swift runtime, `libc++_shared.so`) and `Android/FolinoEditorAndroid/src/main/java-generated/`.

- [ ] **Step 1: Copy the Reader's script and re-aim it**

`cp Scripts/android-build-reader-libs.sh Scripts/android-build-editor-libs.sh`, then change exactly four things:
`PKG_PATH` → `Packages/Features/Editor`, `JNI_DIR` → `Android/FolinoEditorAndroid/src/main/jniLibs`, the product name
→ `FolinoEditorJNI`, and the `GEN_JAVA_*` paths → `.../editor/FolinoEditorJNI/...` and
`Android/FolinoEditorAndroid/src/main/java-generated`. Update the header comment to describe this target's
dependencies (`EditorCore` → the shared editing session; `SheetMusicEditWire` → the one intent schema). Keep the
`FOLINO_ANDROID_ABIS` filter and the toolchain PATH pin verbatim — both are load-bearing.

`chmod +x Scripts/android-build-editor-libs.sh`.

- [ ] **Step 2: Run it for one ABI**

```sh
FOLINO_ANDROID_ABIS=arm64-v8a Scripts/android-build-editor-libs.sh
```

Expected: `libFolinoEditorJNI.so` and the runtime land under
`Android/FolinoEditorAndroid/src/main/jniLibs/arm64-v8a/`, and the Java bindings under `src/main/java-generated/`.
(The directory does not exist as a Gradle module yet — that is Task 6, and the script creating the directories is
fine.)

- [ ] **Step 3: Check the symbols the loader will look for**

```sh
nm -D --defined-only Android/FolinoEditorAndroid/src/main/jniLibs/arm64-v8a/libFolinoEditorJNI.so | grep -i "JNI_OnLoad\|EditorBridge"
```

Expected: `JNI_OnLoad` is present, and the `@WireletObservable` bridge symbols for `EditorBridge` are there. SP0's
finding: ssm's `.so` has no `JNI_OnLoad` because swift-java puts it in `libSwiftJava.so`, but `@WireletObservable`'s
`RegisterNatives` is a different mechanism and does need one. **If `JNI_OnLoad` is absent, stop and find out why
before Task 6** — the failure mode downstream is a crash at first touch with an `UnsatisfiedLinkError` that names a
method rather than the missing hook.

- [ ] **Step 4: Commit**

```sh
git add Scripts/android-build-editor-libs.sh
git commit -m "build(android): cross-compile and stage the editor JNI library"
```

---

# Part B — Kotlin: one relay, three gates (Tasks 6–8)

### Task 6: `:FolinoEditorAndroid`

One Swift JNI target, one Gradle module — the shape `:FolinoSettingsAndroid`, `:FolinoLibraryAndroid`,
`:FolinoReaderAndroid` and `:FolinoSoundfontAndroid` all already have. It keeps wirelet's one-scan-dir-per-source-set
rule satisfied with the plain `main` registration the plugin auto-wires, instead of a second registration in the
Reader module that would need every generated directory hand-wired.

**Files:**
- Create: `Android/FolinoEditorAndroid/build.gradle.kts`
- Create: `Android/FolinoEditorAndroid/src/main/kotlin/com/keynumber/folino/editor/EditorRoomFiles.kt`
- Modify: `Android/settings.gradle.kts`

**Interfaces:**
- Consumes: the generated `EditorBridgeViewModel` (from Task 3) and the generated `EditorHostFiles` interface
  (from Task 2).
- Produces: `com.keynumber.folino.editor.EditorRoomFiles : EditorHostFiles`, and a module SP4 can depend on.

- [ ] **Step 1: Republish the ssm AARs at the pinned version**

The Folino pin is `1.13.0` and Gradle consumes `0.0.0-SNAPSHOT` from mavenLocal, so the two only agree if someone
publishes. From an ssm checkout at the `1.13.0` tag (a worktree under
`~/Developer/Personal/swift-packages/wt-<topic>/swift-sheet-music` if you need one — the SP2 worktrees were cleaned
up):

```sh
Scripts/android-build-libs.sh
Android/gradlew -p Android publishToMavenLocal
```

Publish **all three** modules from that one revision. Then confirm what landed:

```sh
ls ~/.m2/repository/io/github/jiyimeta/sheet-music-android/0.0.0-SNAPSHOT/
```

Expected: an AAR whose timestamp is from this run. Skipping this step produces a Kotlin build that compiles and then
fails at runtime with a draw-program version mismatch or a missing native method — the trap recorded in
`project_android_sheetmusic_aar_version_skew`.

- [ ] **Step 2: The module**

`Android/settings.gradle.kts`: add `include(":FolinoEditorAndroid")` beside the other modules.

`Android/FolinoEditorAndroid/build.gradle.kts` — copy `FolinoReaderAndroid/build.gradle.kts` and cut it down. Keep:
the `com.android.library` + kotlin.android + wirelet plugins (no Compose, no KSP, no Room — SP4 and SP5 add what they
need), `namespace = "com.keynumber.folino.editor"`, the same `compileSdk` / `minSdk` / `abiFilters`, the jniLibs and
java-generated source dirs, `wirelet-runtime` + `wirelet-observable-runtime`, `swiftkit-core`, the three
`sheet-music-*` mavenLocal dependencies with the `ssmVersion` property, `junit`, and the whole
`wirelet { … }` + manual-source-dir-wiring + `dependsOn` tail with every `packageRoot.resolve(...)` re-aimed at
`Packages/Features/Editor/Sources/FolinoEditorJNI` and every package set to `com.keynumber.folino.editor` /
`com.keynumber.folino.editor.generated`, and `libraryName.set("FolinoEditorJNI")`.

Add the instrumented-test dependencies Task 9 needs:

```kotlin
    androidTestImplementation("androidx.test.ext:junit:1.2.1")
    androidTestImplementation("androidx.test:runner:1.6.2")
```

and in `android { defaultConfig { … } }`:

```kotlin
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
```

- [ ] **Step 3: The file seam**

`Android/FolinoEditorAndroid/src/main/kotlin/com/keynumber/folino/editor/EditorRoomFiles.kt`:

```kotlin
package com.keynumber.folino.editor

import java.io.File
import java.security.MessageDigest

/**
 * The Kotlin half of the editor's file seam.
 *
 * The digest format is load-bearing: it has to be the same lowercase hex SHA-256 the importer wrote, or a save makes
 * the library think it is looking at a new file. That is why this mirrors the importer's digest rather than picking
 * its own encoding.
 *
 * The library-row refresh is deliberately absent — SP5 owns persistence, and until it lands nothing on the Swift
 * side calls a writer.
 */
class EditorRoomFiles : EditorHostFiles {
    override fun sha256Hex(path: String): String {
        val file = File(path)
        if (!file.isFile) return ""
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { stream ->
            val buffer = ByteArray(64 * 1024)
            while (true) {
                val read = stream.read(buffer)
                if (read <= 0) break
                digest.update(buffer, 0, read)
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }

    override fun fileSize(path: String): Long = File(path).let { if (it.isFile) it.length() else 0L }
}
```

Check the generated `EditorHostFiles` interface for the exact method names and nullability before writing this — the
generator, not this plan, is the authority on that signature.

- [ ] **Step 4: Compile**

```sh
Android/gradlew -p Android :FolinoEditorAndroid:compileDebugKotlin
```

Expected: green. `Unresolved reference 'EditorBridgeViewModel'` means the codegen task did not run — check the
`dependsOn` tail. `Unresolved reference` on a wire model means the schema path is pointing at the wrong directory.

- [ ] **Step 5: Commit**

```sh
git add Android/settings.gradle.kts Android/FolinoEditorAndroid
git commit -m "build(android): add the FolinoEditorAndroid module and its file seam"
```

---

### Task 7: `EditSessionRelay` — the funnel and the gates

The heart of SP3. Every editing action is a method on this class, and everything that must happen around an action
happens inside it, so no caller can do half of it. Spec §8's gates live here too — the version check before a
session opens, the fingerprint check when it opens, and the sampled fingerprint check as it runs — because all three
are about the relationship between the two images, and this class is the only thing that touches both.

**The relay is the only holder of the bridge.** An earlier draft took a `perform(op: () -> Unit)` lambda and left the
view model in the caller's hands too — which means SP4's Compose code can call `vm.inputPitch("C")` directly, strand
its intent frames in the queue, and have them relayed later against a mirror that a resync has meanwhile rebuilt from
a score already containing them. Double-application, divergence, and a resync loop, from a call that looks perfectly
reasonable at the call site. Named delegations cost about twenty-five one-line methods and delete the escape hatch,
which is what "one funnel that cannot be half-called" actually requires.

**Files:**
- Create: `Android/FolinoEditorAndroid/src/main/kotlin/com/keynumber/folino/editor/EditSessionHost.kt`
- Create: `Android/FolinoEditorAndroid/src/main/kotlin/com/keynumber/folino/editor/EditSessionRelay.kt`

**Interfaces:**
- Consumes: `EditorBridgeViewModel` (generated — `takeRelayFrames()`, `scoreFingerprint()`, `engineVersionStamp()`,
  `beginSession(...)`, `endSession()`, `encodeScore()`, `undo()`, `redo()`, every op from Task 3), and
  `io.github.jiyimeta.sheetmusic.SheetMusicJNI`.
- Produces:
  - `interface EditSessionHost { fun scoreHandle(): Long; fun replaceScoreHandle(handle: Long); fun requestRelayout() }`
  - `interface EditBridging` — the bridge surface the relay drives, plus `GeneratedEditBridging`, a pure delegation
    over the generated view model. (Task 8 tests the relay's policy on the JVM, where the generated final class over
    JNI cannot be constructed; the interface is what makes that possible, so it exists from the start rather than
    being retrofitted.)
  - `interface EditNatives` + `object RealEditNatives` — every ssm entry point the relay calls, likewise fakeable.
  - `enum class OpenResult { OPENED, VERSION_SKEW, NO_HANDLE, SCORE_UNREADABLE, MIRROR_REFUSED }`
  - `class EditSessionRelay(bridge: EditBridging, host: EditSessionHost, natives: EditNatives = RealEditNatives)`
    with `open(scorePath, scoresDirectory, scoreId): OpenResult`, `close()`, `undo()`, `redo()`, one method per
    editing op (SP4 calls these), the read-only projection SP4 collects, and `resyncCount` for the tests.

- [ ] **Step 1: The host seam**

`EditSessionHost.kt`:

```kotlin
package com.keynumber.folino.editor

/**
 * The three things the relay needs from whoever owns the ssm score handle.
 *
 * An interface rather than a direct `ReaderViewModel` reference for two reasons: it keeps this module independent of
 * `:FolinoReaderAndroid` (which will depend on THIS one when SP4 wires the UI), and it lets the device parity test
 * drive the relay with nothing but a handle and no Reader at all.
 */
interface EditSessionHost {
    /** The handle the mirror session lives beside. `0` when there is none. */
    fun scoreHandle(): Long

    /**
     * Swaps in a fresh handle after a resync. Everything downstream of the handle — MIDI render, timeline, cursor,
     * parts/staves — keys off it, so this is the one moment in a session when all of that re-fires. It is also why
     * a resync is the recovery path and not the mechanism.
     */
    fun replaceScoreHandle(handle: Long)

    /** Asks the host to recompute the layout and redraw. Called once per relayed op, after the mirror is current. */
    fun requestRelayout()
}
```

- [ ] **Step 2: The relay**

`EditSessionRelay.kt`:

```kotlin
package com.keynumber.folino.editor

import android.util.Log
import com.keynumber.folino.editor.generated.EditorBridgeViewModel
import io.github.jiyimeta.sheetmusic.SheetMusicJNI
import kotlinx.coroutines.flow.StateFlow

/**
 * The ssm entry points the relay uses, behind an interface so the JVM tests can drive the policy without a device.
 * The real implementation is a straight delegation — nothing may be added to it, or the tests stop covering what
 * ships.
 */
interface EditNatives {
    fun engineVersionStamp(): Long
    fun beginEditSession(handle: Long): Boolean
    fun applyEditIntent(handle: Long, bytes: ByteArray): Boolean
    fun editUndo(handle: Long): Boolean
    fun editRedo(handle: Long): Boolean
    fun endEditSession(handle: Long)
    fun scoreFingerprint(handle: Long): Long
    fun loadScore(bytes: ByteArray): Long
    fun releaseScore(handle: Long)
}

object RealEditNatives : EditNatives {
    override fun engineVersionStamp() = SheetMusicJNI.nativeEngineVersionStamp()
    override fun beginEditSession(handle: Long) = SheetMusicJNI.nativeBeginEditSession(handle)
    override fun applyEditIntent(handle: Long, bytes: ByteArray) = SheetMusicJNI.nativeApplyEditIntent(handle, bytes)
    override fun editUndo(handle: Long) = SheetMusicJNI.nativeEditUndo(handle)
    override fun editRedo(handle: Long) = SheetMusicJNI.nativeEditRedo(handle)
    override fun endEditSession(handle: Long) = SheetMusicJNI.nativeEndEditSession(handle)
    override fun scoreFingerprint(handle: Long) = SheetMusicJNI.nativeScoreFingerprint(handle)
    override fun loadScore(bytes: ByteArray) = SheetMusicJNI.nativeLoadScore(bytes)
    override fun releaseScore(handle: Long) = SheetMusicJNI.nativeReleaseScore(handle)
}

/**
 * The bridge surface the relay drives, behind an interface for the same reason `EditNatives` is one: the generated
 * `EditorBridgeViewModel` is a final class over JNI, so the relay's policy — the part actually worth being sure
 * about — would otherwise be testable only on a device. `GeneratedEditBridging` must stay a pure delegation.
 *
 * Ops are declared here as the relay needs them; add one per op the relay exposes.
 */
interface EditBridging {
    fun engineVersionStamp(): Long
    fun beginSession(path: String, dir: String, id: String): Boolean
    fun endSession()
    fun scoreFingerprint(): Long
    fun encodeScore(): ByteArray
    fun takeRelayFrames(): List<ByteArray>
    fun revision(): Int
    fun appliedIntentCount(): Int

    fun selectItem(bytes: ByteArray)
    fun inputPitch(letter: String)
    fun deleteSelection()
    fun writeRest()
    fun armDuration(kind: Int)
    fun toggleArmedDot()
    fun setArmedDots(dots: Int)
    fun setSelectionDuration(kind: Int)
    fun setSelectionDots(dots: Int)
    fun toggleSelectionDot()
    fun shiftPitch(semitones: Int)
    fun shiftOctave(octaves: Int)
    fun setAccidental(raw: String)
    fun toggleAddToChord()
    fun removeSelectedNoteFromChord()
    fun toggleTie()
    fun appendTiedNote()
    fun createTuplet(actualNotes: Int)
    fun removeTuplet()
    fun selectPreviousElement()
    fun selectNextElement()
    fun setActiveVoice(voice: Int)
    fun setPlaybackActive(active: Boolean)
    fun undo()
    fun redo()
}

/** Pure delegation over the generated view model. No policy, no branching — anything else belongs in the relay. */
class GeneratedEditBridging(val vm: EditorBridgeViewModel) : EditBridging { /* one line per member */ }

/** Why a session could not open. */
enum class OpenResult { OPENED, VERSION_SKEW, NO_HANDLE, SCORE_UNREADABLE, MIRROR_REFUSED }

/**
 * The single path from a user action to the score.
 *
 * Editing on Android has an authoritative score in Folino's `.so` and a rendering score behind ssm's handle
 * (spec §4). Keeping them identical is four steps that must always happen together and in order — apply locally,
 * relay every intent that landed, check the two agree, redraw — so they are one private method rather than four a
 * caller could get half right, and every editing op is a named entry point that runs it.
 *
 * **The relay owns the bridge.** `bridge` is private, and SP4 gets the ops through this class. A caller holding the
 * view model could apply an intent locally without relaying it: the frames would sit in the queue until the next
 * relayed op drained them — usually harmless, since order is preserved — but a resync in between re-encodes the
 * authoritative score with those edits already in it, and the stranded frames then apply a second time. There is no
 * way to make that safe from the outside, so there is no way in from the outside.
 *
 * ## Threading
 *
 * **Every method here must be called from one thread**, and on Android that thread is Compose's main thread.
 * ssm's side takes a lock across each of its entry points; Folino's bridge deliberately does not (it holds a
 * non-`Sendable` core, one per isolation domain), and an op followed by `takeRelayFrames()` is two separate JNI
 * calls that must not interleave with another op's pair. Do not move these onto a coroutine dispatcher without
 * giving the bridge a lock first.
 *
 * ## Why a `false` is never shrugged off
 *
 * The authoritative side only emits intents it has already applied, so a refusal downstream cannot be a benign
 * no-op: it means no session, corrupted bytes, a released handle, or two images that have already diverged. All four
 * call for a resync (SP0's finding, and the doc comment on `nativeApplyEditIntent` itself).
 */
class EditSessionRelay(
    private val bridge: EditBridging,
    private val host: EditSessionHost,
    private val natives: EditNatives = RealEditNatives,
) {
    /** Resyncs performed this session. Read by the tests, and by SP4's diagnostics. */
    var resyncCount: Int = 0
        private set

    private var appliedSinceCheck = 0
    private var isOpen = false

    // MARK: - Lifecycle

    /**
     * Opens both sessions, or neither.
     *
     * Three gates, in order.
     *
     * **The version gate (§8.1) is absolute.** Folino's compiled-in `SheetMusicCore` and the one behind the handle
     * must be the same build, because every guarantee here rests on both planning an intent identically. A stale
     * `.so` has bricked this app before, and the answer is to stay read-only rather than to edit and hope. Note what
     * it does *not* catch: the stamp hashes a version string, so a stale mavenLocal AAR rebuilt at the same
     * `0.0.0-SNAPSHOT` sails through. The gate protects shipped skew; keeping the local AARs republished protects
     * dev skew.
     *
     * **Begin/end are strictly paired across both sides.** If the mirror refuses, the authoritative session is
     * closed again before returning — an authoritative session outliving a mirror is how a later undo returns
     * `false` against a score that has already reverted.
     *
     * **The fingerprint check at open is not paranoia; it is the normal second session.** Ending a session does not
     * revert the mirror ("the score keeps whatever the session last wrote" — ssm's own words), and SP3/SP4 ship no
     * save at all. So: edit, close, reopen — and the mirror is seeded from the *edited* score behind the handle
     * while this side parses the *unedited* file. They diverge before the first keystroke, and nothing else would
     * notice for up to `FINGERPRINT_SAMPLE_EVERY` edits — during which taps resolve against one score and edits
     * apply to another, which is the "wrong element edited" failure, not a cosmetic one. Resyncing here pushes the
     * file-parsed score into the handle, which is also the correct semantics: unsaved edits were never persisted, so
     * the file is the truth. The same check covers a failed save, a double open, and a file replaced underneath us.
     */
    fun open(scorePath: String, scoresDirectory: String, scoreId: String): OpenResult {
        if (isOpen) close()
        val handle = host.scoreHandle()
        if (handle == 0L) return OpenResult.NO_HANDLE
        if (bridge.engineVersionStamp() != natives.engineVersionStamp()) return OpenResult.VERSION_SKEW
        if (!bridge.beginSession(scorePath, scoresDirectory, scoreId)) return OpenResult.SCORE_UNREADABLE
        if (!natives.beginEditSession(handle)) {
            bridge.endSession()
            return OpenResult.MIRROR_REFUSED
        }
        appliedSinceCheck = 0
        isOpen = true
        if (verifyOrResync()) host.requestRelayout()
        return OpenResult.OPENED
    }

    /** Ends both sides. Safe to call twice; `nativeEndEditSession` is a no-op for a handle with no session. */
    fun close() {
        if (!isOpen) return
        natives.endEditSession(host.scoreHandle())
        bridge.endSession()
        isOpen = false
    }

    // MARK: - The editing ops
    //
    // One named method per op, each `relay { … }`. They exist so that `bridge` can stay private — see the class
    // doc. Nothing here may branch: a decision in this file is a rule Android has and iOS does not.

    fun selectItem(bytes: ByteArray) = relay { bridge.selectItem(bytes) }
    fun inputPitch(letter: String) = relay { bridge.inputPitch(letter) }
    fun deleteSelection() = relay { bridge.deleteSelection() }
    fun writeRest() = relay { bridge.writeRest() }
    fun armDuration(kind: Int) = relay { bridge.armDuration(kind) }
    fun toggleArmedDot() = relay { bridge.toggleArmedDot() }
    fun setArmedDots(dots: Int) = relay { bridge.setArmedDots(dots) }
    fun setSelectionDuration(kind: Int) = relay { bridge.setSelectionDuration(kind) }
    fun setSelectionDots(dots: Int) = relay { bridge.setSelectionDots(dots) }
    fun toggleSelectionDot() = relay { bridge.toggleSelectionDot() }
    fun shiftPitch(semitones: Int) = relay { bridge.shiftPitch(semitones) }
    fun shiftOctave(octaves: Int) = relay { bridge.shiftOctave(octaves) }
    fun setAccidental(raw: String) = relay { bridge.setAccidental(raw) }
    fun toggleAddToChord() = relay { bridge.toggleAddToChord() }
    fun removeSelectedNoteFromChord() = relay { bridge.removeSelectedNoteFromChord() }
    fun toggleTie() = relay { bridge.toggleTie() }
    fun appendTiedNote() = relay { bridge.appendTiedNote() }
    fun createTuplet(actualNotes: Int) = relay { bridge.createTuplet(actualNotes) }
    fun removeTuplet() = relay { bridge.removeTuplet() }
    fun selectPreviousElement() = relay { bridge.selectPreviousElement() }
    fun selectNextElement() = relay { bridge.selectNextElement() }
    fun setActiveVoice(voice: Int) = relay { bridge.setActiveVoice(voice) }
    fun setPlaybackActive(active: Boolean) = relay { bridge.setPlaybackActive(active) }

    /**
     * Undo and redo drive the mirror's OWN stacks rather than replaying an inverse: it was fed identical intents, so
     * it has an identical stack. They are also always fingerprint-checked, because they are the two operations whose
     * effect on the mirror is inferred rather than transmitted.
     */
    fun undo() = replay(natives::editUndo) { bridge.undo() }

    fun redo() = replay(natives::editRedo) { bridge.redo() }

    // MARK: - The funnel

    /**
     * Performs one op and carries its consequences across.
     *
     * The op may apply no intents (an inert key), one, or several; the frame list is what actually happened, which
     * is why the count comes from the bridge rather than from the op.
     */
    private fun relay(op: () -> Unit) {
        if (!isOpen) return
        op()
        val frames = bridge.takeRelayFrames()
        if (frames.isEmpty()) return
        val handle = host.scoreHandle()
        for (frame in frames) {
            if (!natives.applyEditIntent(handle, frame)) {
                resync()
                host.requestRelayout()
                return
            }
        }
        appliedSinceCheck += frames.size
        if (appliedSinceCheck >= FINGERPRINT_SAMPLE_EVERY) {
            appliedSinceCheck = 0
            verifyOrResync()
        }
        host.requestRelayout()
    }

    private fun replay(mirror: (Long) -> Boolean, local: () -> Unit) {
        if (!isOpen) return
        val before = bridge.appliedIntentCount()
        val revisionBefore = bridge.revision()
        local()
        // A refused undo/redo leaves the local revision where it was, and must not touch the mirror.
        if (bridge.revision() == revisionBefore) return
        check(bridge.appliedIntentCount() == before) { "undo/redo must not count as an applied intent" }
        if (!mirror(host.scoreHandle())) {
            resync()
        } else {
            appliedSinceCheck = 0
            verifyOrResync()
        }
        host.requestRelayout()
    }

    // MARK: - The §8.3 gate

    /** Returns true when the two copies already agreed; false when they did not and a resync was attempted. */
    private fun verifyOrResync(): Boolean {
        if (bridge.scoreFingerprint() == natives.scoreFingerprint(host.scoreHandle())) return true
        resync()
        return false
    }

    /**
     * Rebuilds the mirror from the authoritative score.
     *
     * Encode → load → swap → reopen the mirror session. The mirror's undo stack is gone afterwards, which is exactly
     * why the authoritative session's stack is the one the UI reads: `canUndo` comes from Folino's side, and a
     * post-resync undo relays into a mirror that will refuse it — which resyncs again, from a score that is by then
     * correct. Divergence costs a redraw and a stack, never a file: saves always encode the authoritative copy.
     *
     * Queued frames are dropped first. The encode about to be loaded already contains every edit they describe, so
     * relaying them afterwards would apply each one twice — the one way a resync could make things worse than the
     * divergence it is repairing.
     *
     * A resync that cannot complete closes the session rather than leaving it open: with the two copies known to
     * disagree and no way to reconcile them, every further op would re-trigger a failing resync, and the taps in
     * between would edit whatever the stale layout resolved to. SP4 surfaces that as dropping back to read-only.
     */
    private fun resync() {
        resyncCount += 1
        Log.w(TAG, "edit session diverged; resyncing the mirror (resync #$resyncCount)")
        bridge.takeRelayFrames()
        val bytes = bridge.encodeScore()
        if (bytes.isEmpty()) {
            Log.e(TAG, "resync failed: the authoritative score would not encode; closing the session")
            close()
            return
        }
        val fresh = natives.loadScore(bytes)
        if (fresh == 0L) {
            Log.e(TAG, "resync failed: the re-encoded score would not load; closing the session")
            close()
            return
        }
        val stale = host.scoreHandle()
        host.replaceScoreHandle(fresh)
        natives.releaseScore(stale)
        natives.beginEditSession(fresh)
        appliedSinceCheck = 0
    }

    companion object {
        private const val TAG = "EditSessionRelay"

        /**
         * How many applied intents may pass between fingerprint checks.
         *
         * `stableFingerprint` walks the whole value tree, so it is the one thing here whose cost grows with the
         * score. Eight is the starting point the device test in Task 9 measures against: if one walk on the parity
         * fixture costs more than about two milliseconds, raise this until the amortized cost per edit is under half
         * a millisecond, and record the measurement in this comment. Session open, undo, redo and (from SP5) every
         * save check unconditionally regardless of this number.
         */
        const val FINGERPRINT_SAMPLE_EVERY = 8
    }
}
```

Three things to settle against the generator rather than against this plan:

- **`GeneratedEditBridging`'s body is left as a comment above on purpose** — write one delegating line per member,
  matching whatever the generated view model actually emits. Its ops may be plain methods or suspend functions, and
  its projection may be `StateFlow` properties or getters; `revision()` / `appliedIntentCount()` in `EditBridging`
  are declared as plain functions so the interface does not leak that choice into the relay.
- **`EditorBridgeViewModel` stays reachable through `GeneratedEditBridging.vm`** so SP4 can collect the projection
  StateFlows for the UI. Reading state is not the hazard the private `bridge` guards against — applying an op is.
  If the generated projection turns out to be inconvenient to expose that way, add read-only pass-throughs on the
  relay rather than handing SP4 the whole view model.
- **`Log`** is `android.util.Log`, which is unavailable in JVM unit tests unless the module sets
  `testOptions { unitTests.isReturnDefaultValues = true }`. Add that to `build.gradle.kts` if Task 8's tests fail
  with `Method w in android.util.Log not mocked`. Spec §8.3 asks for an analytics event here as well; SP4/SP5 wires
  the analytics bridge, and the log is what SP3 can honestly do.

- [ ] **Step 3: Compile**

```sh
Android/gradlew -p Android :FolinoEditorAndroid:compileDebugKotlin
```

Expected: green.

- [ ] **Step 4: Commit**

```sh
git add Android/FolinoEditorAndroid/src/main/kotlin
git commit -m "feat(android): relay every applied intent through one gated funnel"
```

---

### Task 8: The relay's policy, tested on the JVM

Everything in Task 7 that is a *decision* rather than a JNI call, tested where it is cheap: the three gates, the
sampling interval, and the ways a resync gets triggered.

**Files:**
- Create: `Android/FolinoEditorAndroid/src/test/kotlin/com/keynumber/folino/editor/EditSessionRelayTest.kt`

**Interfaces:**
- Consumes: `EditSessionRelay`, `EditBridging`, `EditNatives`, `EditSessionHost` (Task 7).
- Produces: nothing further; this is a leaf.

- [ ] **Step 1: Write the failing tests**

Both seams the fakes need — `EditBridging` and `EditNatives` — already exist from Task 7, so this task only writes
tests.

The cases below are the ones that must exist; write them in this shape, and add any others the relay's code makes
you want. `FakeBridge` implements `EditBridging`, `FakeNatives` implements `EditNatives`, `FakeHost` implements
`EditSessionHost`; the ops on `FakeBridge` that this file does not exercise can be empty bodies.

```kotlin
package com.keynumber.folino.editor

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

private class FakeBridge : EditBridging {
    var stamp = 7L
    var fingerprint = 100L
    var opened = false
    var revision = 0
    var appliedIntentCount = 0
    var encoded = byteArrayOf(1, 2, 3)
    var refuseUndo = false
    private val framesToEmit = mutableListOf<ByteArray>()

    override fun engineVersionStamp() = stamp
    override fun beginSession(path: String, dir: String, id: String) = true.also { opened = true }
    override fun endSession() { opened = false }
    override fun scoreFingerprint() = fingerprint
    override fun encodeScore() = encoded
    override fun takeRelayFrames(): List<ByteArray> = framesToEmit.toList().also { framesToEmit.clear() }
    override fun revision() = revision
    override fun appliedIntentCount() = appliedIntentCount
    override fun undo() { if (!refuseUndo) revision += 1 }
    override fun redo() { revision += 1 }

    /** Stands in for one op that applies `count` intents — what a pad key does through the bridge. */
    override fun inputPitch(letter: String) = willApply(1)
    override fun deleteSelection() = willApply(1)
    // …the remaining `EditBridging` members: empty bodies, or `willApply(n)` where a test needs them.

    private fun willApply(count: Int) {
        repeat(count) { framesToEmit.add(byteArrayOf(it.toByte())) }
        revision += count
        appliedIntentCount += count
    }
}
```

The cases:

1. **`a version mismatch refuses to open`** — `natives.stamp = 8L`; `open` returns `VERSION_SKEW`, `bridge.opened`
   is false, and `natives.begins == 0`. Neither side may open.
2. **`a missing handle refuses to open`** — `host.handle = 0L`; `open` returns `NO_HANDLE` and nothing is touched.
3. **`a mirror that refuses closes the local session again`** — `natives.beginAnswer = false`; `open` returns
   `MIRROR_REFUSED` and `bridge.opened` is false. This is the begin/end pairing rule.
4. **`opening onto a diverged handle resyncs before the first edit`** — the fingerprints disagree at `open` time;
   `open` still returns `OPENED`, `resyncCount == 1`, and the host was asked to redraw. This is the reopen-without-save
   case, and it is the single most important test in this file: it is the one that fails if someone deletes the
   fingerprint check from `open` as redundant.
5. **`an applied intent reaches the mirror once, in order`** — one op applying two intents; `natives.applied` has
   both, in the order the bridge emitted them.
6. **`an op that applies nothing relays nothing`** — an inert key; no native apply, no resync.
7. **`a refused relay resyncs immediately`** — `natives.applyAnswers` yields `false`; `resyncCount == 1`,
   `natives.loads == 1`, and `host.handle` is the fresh one.
8. **`fingerprints are compared on the sampling interval, not every edit`** — fingerprints permanently disagree;
   after `FINGERPRINT_SAMPLE_EVERY - 1` single-intent ops `resyncCount` is still 0 (the check at `open` saw them
   agreeing — set the disagreement after `open` returns), and the next op makes it 1.
9. **`undo checks the fingerprint unconditionally`** — one undo with disagreeing fingerprints resyncs, without
   waiting for the interval.
10. **`a refused undo on the local side leaves the mirror alone`** — `bridge.refuseUndo = true` so the local
    revision does not move; `natives.editUndo` is never called and no resync happens even with fingerprints
    disagreeing.
11. **`a resync drops the frames it is about to make redundant`** — queue frames, force a resync, and assert the
    next relayed op sends only its own frames. Without the purge in `resync()`, the stranded ones apply twice.
12. **`a resync that cannot encode closes the session`** — `bridge.encoded = ByteArray(0)`; after the resync the
    relay is closed, and a subsequent op relays nothing.
13. **`closing ends both sides`** — after `close()`, `bridge.opened` is false and `natives.ends == 1`.

- [ ] **Step 2: Run them and watch them fail**

```sh
Android/gradlew -p Android :FolinoEditorAndroid:testDebugUnitTest
```

Expected: they fail (or do not compile) only for reasons in the test file itself — the relay is already written. If
they fail with `Method w in android.util.Log not mocked`, add to `Android/FolinoEditorAndroid/build.gradle.kts`:

```kotlin
android {
    testOptions { unitTests.isReturnDefaultValues = true }
}
```

- [ ] **Step 3: Make them pass**

If a test fails because the relay's behavior is genuinely wrong, fix the relay — that is the point of writing them.
If it fails because the test is wrong, fix the test. Do not weaken a case to make it pass; case 4 and case 11 in
particular exist because of specific, argued failure modes, and a version of them that passes trivially is worse than
no test.

```sh
Android/gradlew -p Android :FolinoEditorAndroid:testDebugUnitTest
```

Expected: all pass.

- [ ] **Step 4: Commit**

```sh
git add Android/FolinoEditorAndroid/src Android/FolinoEditorAndroid/build.gradle.kts
git commit -m "test(android): pin the relay's gates and sampling policy"
```

---

# Part C — the gate (Tasks 9–10)

### Task 9: Two images, one score, on the device

SP0 proved that replaying intents across the boundary is deterministic, with Kotlin relaying committed byte assets.
This proves the thing SP3 actually built: that *Folino's own session* produces those bytes, that the funnel carries
them, and that the two scores agree after every step of a real editing sequence.

**Files:**
- Create: `Android/FolinoEditorAndroid/src/androidTest/kotlin/com/keynumber/folino/editor/EditSessionParityTest.kt`
- Create: `Android/FolinoEditorAndroid/src/androidTest/assets/parity.mscz`

**Interfaces:**
- Consumes: everything above.
- Produces: the measurement that fixes `FINGERPRINT_SAMPLE_EVERY`.

- [ ] **Step 1: Stage the fixture**

Copy a real multi-measure, multi-voice score into `src/androidTest/assets/parity.mscz`. **Not** `midi01.mscx`: SP0
recorded that it has one measure and no rests, and every task that assumed otherwise had to re-aim its indices. Use a
fixture with several bars and at least one rest to write into — the repo's own test resources under
`Packages/Features/Reader/Tests/ReaderTests/Resources/` or `App/` are the place to look. Check the licence of
whatever you pick: ssm's MuseScore-derived fixtures are GPL and must not leave its test target.

- [ ] **Step 2: Write the test**

```kotlin
package com.keynumber.folino.editor

import androidx.test.platform.app.InstrumentationRegistry
import io.github.jiyimeta.sheetmusic.SheetMusicJNI
import io.github.jiyimeta.sheetmusic.audio.model.RestID
import io.github.jiyimeta.sheetmusic.audio.model.ScoreItemID
import io.github.jiyimeta.sheetmusic.audio.serialization.ScoreItemIDCodec
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * The SP3 acceptance test: an editing session driven through the real funnel, with the two images' fingerprints
 * compared after EVERY step rather than on the sampling interval.
 *
 * The sampling interval is a shipping compromise about cost; this test is about correctness, so it checks
 * everything. A divergence that the shipped sampling would have caught eight edits later shows up here on the edit
 * that caused it.
 *
 * The test encodes a `ScoreItemID` itself to seed the first selection. That is the one place Kotlin is allowed to
 * speak this schema: `EditorSessionCore.selectNextElement()` is a no-op with nothing selected, so a cold session has
 * no target, and here the test is standing in for SP4's tap. The shipping path still gets its bytes from
 * `nativeEditingHitTest` and relays them without looking.
 */
class EditSessionParityTest {
    private class TestHost(var handle: Long) : EditSessionHost {
        var relayouts = 0
        override fun scoreHandle() = handle
        override fun replaceScoreHandle(handle: Long) { this.handle = handle }
        override fun requestRelayout() { relayouts += 1 }
    }

    private class Rig(val bridge: EditBridging, val host: TestHost, val relay: EditSessionRelay)

    private fun openRig(file: File, scoresDir: File): Rig {
        val handle = SheetMusicJNI.nativeLoadScore(file.readBytes())
        assertNotEquals(0L, handle)
        val bridge = GeneratedEditBridging(EditorBridgeViewModel(EditorRoomFiles()))
        val host = TestHost(handle)
        val relay = EditSessionRelay(bridge, host, RealEditNatives)
        assertEquals(OpenResult.OPENED, relay.open(file.path, scoresDir.path, "parity"))
        return Rig(bridge, host, relay)
    }

    private fun stagedFixture(): Pair<File, File> {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val scoresDir = File(context.filesDir, "Scores").apply { mkdirs() }
        val file = File(scoresDir, "parity.mscz")
        context.assets.open("parity.mscz").use { input -> file.outputStream().use { input.copyTo(it) } }
        return file to scoresDir
    }

    @Test fun sessionsStayIdenticalThroughAScriptedEdit() {
        val (file, scoresDir) = stagedFixture()
        val rig = openRig(file, scoresDir)
        val relay = rig.relay
        assertAgreed(rig, "after open")

        // Stand in for SP4's tap: select the first rest of the first bar by its ID.
        relay.selectItem(ScoreItemIDCodec.encode(ScoreItemID.Rest(firstRestID())))
        assertAgreed(rig, "after the first selection")

        relay.armDuration(QUARTER)
        relay.inputPitch("C")
        assertAgreed(rig, "after writing C")

        relay.inputPitch("E")
        relay.inputPitch("G")
        assertAgreed(rig, "after writing E and G")

        relay.shiftPitch(1)
        assertAgreed(rig, "after a semitone up")

        relay.armDuration(EIGHTH)
        relay.toggleArmedDot()
        relay.inputPitch("A")
        assertAgreed(rig, "after a dotted eighth")

        relay.writeRest()
        assertAgreed(rig, "after a rest")

        relay.deleteSelection()
        assertAgreed(rig, "after a delete")

        repeat(4) { relay.undo(); assertAgreed(rig, "after undo $it") }
        repeat(4) { relay.redo(); assertAgreed(rig, "after redo $it") }

        assertEquals("no resync should have been needed", 0, relay.resyncCount)
        assertTrue("the host should have been asked to redraw", rig.host.relayouts > 0)

        relay.close()
        SheetMusicJNI.nativeReleaseScore(rig.host.handle)
    }

    /**
     * Closing a session does not revert the mirror, and SP3 saves nothing — so a second session parses the unedited
     * file while the handle still holds the edits. The fingerprint check in `open()` is what catches that, and this
     * is the test that fails if someone removes it as redundant.
     */
    @Test fun reopeningAfterAnUnsavedEditResyncsInsteadOfDiverging() {
        val (file, scoresDir) = stagedFixture()
        val first = openRig(file, scoresDir)
        first.relay.selectItem(ScoreItemIDCodec.encode(ScoreItemID.Rest(firstRestID())))
        first.relay.armDuration(QUARTER)
        first.relay.inputPitch("C")
        assertAgreed(first, "after the first session's edit")
        val editedFingerprint = SheetMusicJNI.nativeScoreFingerprint(first.host.handle)
        first.relay.close()

        // Same handle, same (untouched) file: exactly what the Reader does when edit mode is re-entered.
        val bridge = GeneratedEditBridging(EditorBridgeViewModel(EditorRoomFiles()))
        val relay = EditSessionRelay(bridge, first.host, RealEditNatives)
        assertEquals(OpenResult.OPENED, relay.open(file.path, scoresDir.path, "parity"))
        assertEquals("open must have resynced", 1, relay.resyncCount)
        assertEquals(
            "the two copies must agree after the resync",
            bridge.scoreFingerprint(),
            SheetMusicJNI.nativeScoreFingerprint(first.host.handle),
        )
        assertNotEquals(
            "the resync must have replaced the mirror's edited score, not adopted it",
            editedFingerprint,
            SheetMusicJNI.nativeScoreFingerprint(first.host.handle),
        )

        relay.close()
        SheetMusicJNI.nativeReleaseScore(first.host.handle)
    }

    /** Measures one fingerprint walk, so `FINGERPRINT_SAMPLE_EVERY` is chosen against a number, not a guess. */
    @Test fun fingerprintWalkIsCheapEnoughToSample() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val bytes = context.assets.open("parity.mscz").use { it.readBytes() }
        val handle = SheetMusicJNI.nativeLoadScore(bytes)
        val started = System.nanoTime()
        repeat(50) { SheetMusicJNI.nativeScoreFingerprint(handle) }
        val perWalkMicros = (System.nanoTime() - started) / 50 / 1_000
        android.util.Log.i("EditSessionParity", "stableFingerprint walk: ${perWalkMicros}us")
        SheetMusicJNI.nativeReleaseScore(handle)
        assertTrue("fingerprint walk unexpectedly slow: ${perWalkMicros}us", perWalkMicros < 2_000)
    }

    private fun assertAgreed(rig: Rig, step: String) {
        assertEquals(step, rig.bridge.scoreFingerprint(), SheetMusicJNI.nativeScoreFingerprint(rig.host.handle))
    }

    private companion object {
        const val QUARTER = 3
        const val EIGHTH = 4

        /** The fixture's first timed slot. Adjust the indices to whatever the staged score actually starts with. */
        fun firstRestID() = RestID(staff = 0, measureIndex = 0, voiceIndex = 0, elementIndex = 1)
    }
}
```

Three things to settle against the real APIs:

- **`RestID`'s Kotlin field names and element index.** The Kotlin models come from the ssm audio AAR
  (`io.github.jiyimeta.sheetmusic.audio.model`); read the generated class rather than trusting the call above, and
  pick an `elementIndex` that is actually a rest in the staged fixture — element 0 is usually the clef or the time
  signature, not a timed slot. If the first selection lands on nothing, every later assertion still passes
  vacuously, so **assert that the selection took**: `bridge` exposes `selectedItemFrame` through the generated view
  model, and it must be non-empty after the first `selectItem`.
- **`EditorBridgeViewModel(EditorRoomFiles())`** — the constructor shape comes from the generator (`nativeNew` wraps
  the `@WireletProvided` handle). Read the generated file and match it.
- **`GeneratedEditBridging.scoreFingerprint()`** is used as the authoritative side's digest here; that is the same
  call `EditSessionRelay` makes internally, which is what makes this a real cross-image comparison rather than a
  tautology.

- [ ] **Step 3: Run it on the Pixel**

```sh
adb devices                       # confirm the physical device is listed
Android/gradlew -p Android :FolinoEditorAndroid:connectedDebugAndroidTest
```

Expected: all three tests pass. Wireless `adb` setup, if the device is not attached, is in
`reference_android_pixel_wireless_adb`.

Triage order when the parity test fails:

1. **A stale mavenLocal AAR is suspect number one**, and the §8.1 version gate will NOT catch it: the stamp hashes a
   version string, and every local ssm publish carries the same `0.0.0-SNAPSHOT`. Re-run Task 6 Step 1 (build the
   `.so`s, publish all three modules from one ssm revision) and re-run the test before believing anything else.
2. **A failure at one specific step** means that step's intent does not carry everything the mirror needs — an
   ssm-side gap in the intent vocabulary, the same class of finding SP2 hit five times. Do not paper over it in
   Kotlin; report it.
3. **A failure at `after open`** means the fixture parses differently on the two sides, which is a parser-level
   problem, not a relay one.

- [ ] **Step 4: Fix the sampling constant to the measurement**

Read the logged `stableFingerprint walk: …us`. If a walk is under ~250µs, leave `FINGERPRINT_SAMPLE_EVERY = 8` and
record the measured number in its doc comment. If it is slower, raise the constant so the amortized cost per edit
stays under half a millisecond, and record both numbers.

- [ ] **Step 5: Commit**

```sh
git add Android/FolinoEditorAndroid/src/androidTest \
        Android/FolinoEditorAndroid/src/main/kotlin/com/keynumber/folino/editor/EditSessionRelay.kt
git commit -m "test(android): prove both images stay identical through a scripted edit"
```

---

### Task 10: The ledger, and what SP4 inherits

**Files:**
- Modify: `Android/FolinoEditorAndroid/src/main/kotlin/com/keynumber/folino/editor/EditSessionRelay.kt` (the marker)
- Modify: `docs/engineering/ios-android-parity.md` (regenerated)

- [ ] **Step 1: Leave the marker**

At the top of `EditSessionRelay`, per CLAUDE.md's ledger convention and SP0's finding:

```kotlin
// PARITY(android): note editing — the session and the relay are here, but nothing drives them yet: the contextual
// app bar, pad, callout and caret are SP4, and autosave plus the sibling-.mscz policy are SP5. Delete this marker
// when SP5 lands.
```

- [ ] **Step 2: Regenerate the ledger**

```sh
Scripts/parity-report.py
git diff docs/engineering/ios-android-parity.md
```

Expected: one new row. The `parity-ledger` pre-commit hook fails if the file drifted, so this is not optional.

- [ ] **Step 3: Full re-verification before the commit**

```sh
cd Packages/Features/Editor && xcodebuild test -scheme Editor-Package \
    -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation
cd - && Android/gradlew -p Android :FolinoEditorAndroid:testDebugUnitTest
Android/gradlew -p Android :FolinoEditorAndroid:connectedDebugAndroidTest
Android/gradlew -p Android :app:assembleDebug
```

Expected: all green. The last one is the one that catches a settings.gradle / dependency mistake that the module's
own tasks do not.

- [ ] **Step 4: Commit**

```sh
git add -A
git commit -m "docs(android): record what note editing still owes Android"
```

---

## Notes for whoever executes this

**Three things SP3 deliberately does not fix.**

1. **The stale-layout race.** `nativeComputeLayout` writes `LayoutDocumentCache` without the edit lock, so a layout
   compute in flight when an edit lands can cache a layout of the old score against a handle whose score is new — and
   because `nativeEditingHitTest` reads that cache and its answer feeds the next intent, the symptom is "a different
   element was edited", not "the cursor is off". It stays unreachable while Compose drives everything from one
   thread, which SP3 does. **SP4 is where it becomes reachable**, because that is where a scroll-driven relayout can
   overlap a tap. The prescription is SP0's: a per-handle generation in ssm's cache. It is an ssm change, so it lands
   and tags on that side first.
2. **`.tuplet` is still in filtered addressing** out of `engineCursorForFilteredTap`.
3. **Persistence.** No save path, no autosave, no `onPause` flush, no Room refresh — all SP5.
   `UnimplementedScoreWriter` traps rather than no-ops so this cannot be mistaken for working, and it is where the
   decision that Android's `refreshRow` is a partial update of three columns is written down. That decision and the
   stub row are one safety: SP5 must not implement a whole-row Android writer while the row is still a stub, or the
   first autosave writes placeholder titles, tags and dates over the user's real library row.

**The one thing to check before starting.** Project memory recorded (2026-08-12) that `main`'s Android build was
broken because the mixer per-instrument migration changed Swift's staff addressing to `(part, staff)` and the Kotlin
had not followed. Reading the call sites on this branch after merging `main`, `MainActivity.kt` now passes
`(partIndex, staffIndexInPart, …)` and the generated bridge takes three arguments, so it looks resolved — but
**nobody has compiled it**, and Task 6 is the first thing here that will. If `:FolinoReaderAndroid:compileDebugKotlin`
is red for a mixer reason, that is not SP3's bug; report it rather than absorbing the fix into this branch.

**Two user rulings this plan inherits and must not reverse.**

- **2026-08-06** — the intent wire has exactly one declaration, in ssm's `SheetMusicEditWire`. Both `.so`s link it.
- **2026-08-12** — the ssm re-pin happens on `main` and is merged down into this worktree branch; never edited here
  directly.

**What SP4 will want from this and does not have yet.** The hit-test leg (`nativeEditingHitTest` → `selectItem`) is
built but never called — SP4 supplies the tap coordinates and the layout options. The caret rect
(`nativeEditingCaretFrame(handle, caretItemFrame.bytes)`) and the selection tint
(`nativeEncodeDrawProgram(handle, selectionBytes)`) are both ssm entry points that SP3 leaves untouched: the bytes
they need are already projected, so SP4 is UI plus two native calls, not more plumbing.

## Amendments after design review (2026-08-13)

The plan was reviewed once more before execution, and four things changed. They are recorded here because the
reasoning matters more than the diff.

1. **`open()` now fingerprint-checks and resyncs.** The original plan opened both sessions and trusted that they
   started from the same score. They do not, on the second session of any score: ending a session does not revert
   the mirror, SP3/SP4 save nothing, so a reopen parses an unedited file against a handle holding the edits. Every
   later gate would have missed it for up to eight edits, during which taps resolve against one score and edits land
   on another. Tasks 7, 8 (case 4) and 9 (`reopeningAfterAnUnsavedEditResyncsInsteadOfDiverging`) all changed.
2. **`EditSessionRelay` owns the bridge privately, with one named method per op**, replacing
   `perform(op: () -> Unit)`. A caller holding the view model could apply an intent without relaying it, and a
   resync in between would then double-apply the stranded frames. `resync()` also purges the queue for the same
   reason.
3. **The deferred save is spelled honestly.** `UnimplementedScoreWriter` traps instead of throwing
   `SheetMusicError.invalidEdit` (the one error this feature deliberately swallows, and one `performSave` catches
   silently), the stub row's factory is named `stubRowPendingSave`, and Android's partial-update `refreshRow`
   semantics are decided now rather than left for SP5 to discover.
4. **Smaller:** `sync()`'s no-session branch resets everything the session owned; the version gate's blind spot
   (a stale mavenLocal AAR at an unchanged `0.0.0-SNAPSHOT`) is stated where it matters and leads Task 9's triage;
   a failed resync closes the session instead of spinning; and the relay documents that it is single-threaded,
   because ssm's side locks and Folino's deliberately does not.

## Self-review

**Spec coverage.** §11's SP3 bullet names: `FolinoEditorJNI` (Tasks 2–5), the Kotlin relay as *one* function so it
cannot be half-called (Task 7's private `relay`, reachable only through the named ops), the §8 gates (§8.1 version
skew in `open`, §8.2 refused edits — a refused op produces no frame, which Task 1 tests and Task 8 re-tests at the
relay, §8.3 divergence detection and resync in `verifyOrResync` / `resync`, §8.4 save failure — SP5's, noted), and
recovery (`resync`). §5.3's nine JNI entry points are all ssm's and all already shipped; SP3 consumes six of them and
leaves the three geometry ones for SP4. §8.3's analytics event is downgraded to a log line, noted in Task 7.

**Additions beyond the spec.** `EditBridging` and `EditSessionHost` (both Task 7) are not in the spec: the generated
view model is a final class over JNI and the spec assumed the relay lives beside the Reader, so without these two the
relay's policy would be testable only on a device and the device test would need a whole Reader. Both are noted so
§11 can be amended when SP3 reports.

**Known deviation.** The spec's §6.1 says each op returns the intent it applied; SP2 shipped `Void` ops with the
intent visible only inside `apply`. Task 1 resolves that with a drained queue instead of return values, which also
handles the ops that apply more than one intent. Same guarantee, different shape.

**Placeholders.** Three names in Task 2 Step 5 are marked as unverified (`ScoreFileParsing.parse`,
`MSCZWriter.data(from:)`, the `ScoreItem` field list), each with the real API named beside it and the file to read
before writing the call. That is deliberate: a plausible-looking name for an API nobody opened is worse than a
pointer to the file that has the answer.
