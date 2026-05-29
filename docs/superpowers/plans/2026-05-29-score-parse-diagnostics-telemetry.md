# Score parse diagnostics telemetry Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** On every successful score parse, forward `warning`-severity parse diagnostics to Firebase Crashlytics as non-fatals (grouped by `code`, carrying full `message`/`location`), with the diagnostic data source behind a one-function seam that returns `[]` until the upstream `swift-sheet-music` branch lands.

**Architecture:** A folino-owned `ScoreParseDiagnostic` value type is the seam between the (not-yet-released) parser diagnostics API and telemetry. `ScoreParseDiagnostic.asNSError()` maps it to an `NSError` shaped for Crashlytics grouping; `ScoreDiagnosticReporter` applies the warning-only / dedupe / cap policy and calls the existing `CrashReporter.record(error:)`. `LiveScoreFileGateway` (the single parse chokepoint) reports diagnostics after a successful parse. Telemetry only — nothing flows to Domain or Features.

**Tech Stack:** Swift 6.3, SwiftPM packages, Swift Testing (`@Test`/`#expect`), Firebase Crashlytics (via existing `CrashReporter` abstraction in `UtilityCore`).

**Reference:** Design spec at `docs/superpowers/specs/2026-05-29-score-parse-diagnostics-telemetry-design.md`.

**Test command (run from the Infrastructure package dir):**
```bash
cd Packages/Infrastructure
xcodebuild test -scheme Infrastructure -destination 'platform=iOS Simulator,name=iPhone 17' -skipPackagePluginValidation -only-testing:InfrastructureTests 2>&1 | tail -30
```
`swift test` is broken for these packages (SwiftLint plugin's macOS requirement); use `xcodebuild` on the iPhone 17 simulator (iPhone 16 is not installed). If `-scheme Infrastructure` is not found, run `xcodebuild -list` in the package dir to get the exact scheme name.

---

### Task 1: `ScoreParseDiagnostic` value type + Crashlytics `NSError` mapping

**Files:**
- Create: `Packages/Infrastructure/Sources/ScoreFiles/ScoreParseDiagnostic.swift`
- Create: `Packages/Infrastructure/Sources/ScoreFiles/ScoreParseDiagnostic+NSError.swift`
- Test: `Packages/Infrastructure/Tests/InfrastructureTests/ScoreFiles/ScoreParseDiagnosticNSErrorTests.swift`

This task is Foundation-only and needs no Package.swift change.

- [ ] **Step 1: Write the failing test**

Create `Packages/Infrastructure/Tests/InfrastructureTests/ScoreFiles/ScoreParseDiagnosticNSErrorTests.swift`:

```swift
import Foundation
@testable import ScoreFiles
import Testing

struct ScoreParseDiagnosticNSErrorTests {
    @Test func `maps code to domain and message to localized description`() {
        let diagnostic = ScoreParseDiagnostic(
            severity: .warning,
            code: "mscx.tremolo.unknownSubtype",
            message: "Tremolo unknown <subtype> r64",
            location: "measure 12, voice 1, Tremolo",
        )
        let error = diagnostic.asNSError()
        #expect(error.domain == "mscx.tremolo.unknownSubtype")
        #expect(error.localizedDescription == "Tremolo unknown <subtype> r64")
        #expect(error.userInfo["diagnosticCode"] as? String == "mscx.tremolo.unknownSubtype")
        #expect(error.userInfo["severity"] as? String == "warning")
        #expect(error.userInfo["location"] as? String == "measure 12, voice 1, Tremolo")
    }

    @Test func `nil location becomes empty string and info severity maps`() {
        let diagnostic = ScoreParseDiagnostic(severity: .info, code: "x", message: "m", location: nil)
        let error = diagnostic.asNSError()
        #expect(error.userInfo["location"] as? String == "")
        #expect(error.userInfo["severity"] as? String == "info")
    }

    @Test func `does not leak filename or content keys`() {
        let diagnostic = ScoreParseDiagnostic(severity: .warning, code: "x", message: "m", location: nil)
        let keys = Set(diagnostic.asNSError().userInfo.keys)
        #expect(keys.contains("filename") == false)
        #expect(keys.contains("path") == false)
        #expect(keys.contains("content") == false)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run the test command above (optionally append `/ScoreParseDiagnosticNSErrorTests` to `-only-testing:InfrastructureTests`).
Expected: FAIL to compile — `cannot find 'ScoreParseDiagnostic' in scope`.

- [ ] **Step 3: Write the value type**

Create `Packages/Infrastructure/Sources/ScoreFiles/ScoreParseDiagnostic.swift`:

```swift
import Foundation

/// folino-owned mirror of swift-sheet-music's `ScoreDiagnostic`, used as the seam between the (not-yet-released)
/// parser diagnostics API and folino's telemetry pipeline. Owned by folino so the whole pipeline can be built and
/// tested before the upstream branch lands; once it does, add `init(_ ssm: ScoreDiagnostic)` to bridge.
///
/// Kept in `ScoreFiles` (not Domain) because it is telemetry-only — no Feature or Domain consumer references it.
struct ScoreParseDiagnostic: Sendable, Hashable {
    enum Severity: Sendable, Hashable {
        /// Recoverable: the offending element was dropped or defaulted.
        case warning
        /// Notable but expected (e.g. MS2 compatibility path).
        case info
    }

    let severity: Severity
    /// Stable, machine-readable identifier, e.g. `"mscx.tremolo.unknownSubtype"`.
    let code: String
    /// Human-readable English message. Sent verbatim — no truncation.
    let message: String
    /// Best-effort in-score location, e.g. `"measure 12, voice 1, Tremolo"`. `nil` when unavailable.
    let location: String?
}
```

- [ ] **Step 4: Write the `NSError` mapping**

Create `Packages/Infrastructure/Sources/ScoreFiles/ScoreParseDiagnostic+NSError.swift`:

```swift
import Foundation

extension ScoreParseDiagnostic {
    /// Maps the diagnostic to an `NSError` shaped for Crashlytics non-fatal grouping: `domain` is the stable `code`
    /// so all occurrences of one anomaly collapse into a single issue, and the full `message`/`location` ride in
    /// `userInfo` with no length limit (the reason Crashlytics beats Analytics for this).
    ///
    /// Privacy boundary: only `code`, `message`, `location`, and `severity` are included — never a filename, file
    /// path, or file contents.
    func asNSError() -> NSError {
        let severityValue: String = switch severity {
        case .warning: "warning"
        case .info: "info"
        }
        return NSError(domain: code, code: 0, userInfo: [
            NSLocalizedDescriptionKey: message,
            "diagnosticCode": code,
            "severity": severityValue,
            "location": location ?? "",
        ])
    }
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run the test command.
Expected: PASS (3 tests in `ScoreParseDiagnosticNSErrorTests`).

- [ ] **Step 6: Commit**

```bash
git add Packages/Infrastructure/Sources/ScoreFiles/ScoreParseDiagnostic.swift \
        Packages/Infrastructure/Sources/ScoreFiles/ScoreParseDiagnostic+NSError.swift \
        Packages/Infrastructure/Tests/InfrastructureTests/ScoreFiles/ScoreParseDiagnosticNSErrorTests.swift
git commit -m "feat(ScoreFiles): add ScoreParseDiagnostic seam type + Crashlytics NSError mapping

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: `ScoreDiagnosticReporter` policy + `FakeCrashReporter` test double

**Files:**
- Modify: `Packages/Infrastructure/Package.swift` (add `UtilityCore` to the `ScoreFiles` target)
- Create: `Packages/Infrastructure/Sources/ScoreFiles/ScoreDiagnosticReporter.swift`
- Create: `Packages/Infrastructure/Tests/InfrastructureTests/TestSupport/FakeCrashReporter.swift`
- Test: `Packages/Infrastructure/Tests/InfrastructureTests/ScoreFiles/ScoreDiagnosticReporterTests.swift`

- [ ] **Step 1: Add `UtilityCore` to the `ScoreFiles` target**

In `Packages/Infrastructure/Package.swift`, find the `ScoreFiles` target and add the `UtilityCore` product. It currently reads:

```swift
        .target(
            name: "ScoreFiles",
            dependencies: [
                "Domain",
                .product(name: "SheetMusic", package: "swift-sheet-music"),
                .product(name: "SheetMusicPDF", package: "swift-sheet-music"),
            ],
            plugins: swiftLintPlugins,
        ),
```

Change the `dependencies` array to:

```swift
            dependencies: [
                "Domain",
                .product(name: "UtilityCore", package: "Utility"),
                .product(name: "SheetMusic", package: "swift-sheet-music"),
                .product(name: "SheetMusicPDF", package: "swift-sheet-music"),
            ],
```

(`UtilityCore` exposes `CrashReporter` and `NoopCrashReporter`. The `Utility` package is already declared in this `Package.swift`'s top-level `dependencies`, so no new `.package(...)` entry is needed. App-project regeneration with `xcodegen generate` is deferred to Task 4; `xcodebuild test` against the package reads `Package.swift` directly.)

- [ ] **Step 2: Write the `FakeCrashReporter` test double**

Create `Packages/Infrastructure/Tests/InfrastructureTests/TestSupport/FakeCrashReporter.swift`:

```swift
import Foundation
import UtilityCore

/// Test double for `CrashReporter`. Records every `record(error:)` call so tests can assert what telemetry was
/// emitted. Thread-safe because `LiveScoreFileGateway` reports from inside a detached task.
final class FakeCrashReporter: CrashReporter, @unchecked Sendable {
    private let lock = NSLock()
    private var _recordedErrors: [Error] = []

    var recordedErrors: [Error] { lock.withLock { _recordedErrors } }

    func setCollectionEnabled(_: Bool) {}
    func log(_: String) {}

    func record(error: Error) {
        lock.withLock { _recordedErrors.append(error) }
    }
}
```

- [ ] **Step 3: Write the failing reporter test**

Create `Packages/Infrastructure/Tests/InfrastructureTests/ScoreFiles/ScoreDiagnosticReporterTests.swift`:

```swift
import Foundation
@testable import ScoreFiles
import Testing

struct ScoreDiagnosticReporterTests {
    @Test func `records only warnings, not info`() throws {
        let fake = FakeCrashReporter()
        ScoreDiagnosticReporter(crashReporter: fake).report([
            ScoreParseDiagnostic(severity: .warning, code: "a", message: "m1", location: nil),
            ScoreParseDiagnostic(severity: .info, code: "b", message: "m2", location: nil),
        ])
        #expect(fake.recordedErrors.count == 1)
        let first = try #require(fake.recordedErrors.first)
        #expect((first as NSError).domain == "a")
    }

    @Test func `dedupes by code within one parse`() {
        let fake = FakeCrashReporter()
        ScoreDiagnosticReporter(crashReporter: fake).report([
            ScoreParseDiagnostic(severity: .warning, code: "a", message: "m", location: nil),
            ScoreParseDiagnostic(severity: .warning, code: "a", message: "m", location: "elsewhere"),
        ])
        #expect(fake.recordedErrors.count == 1)
    }

    @Test func `caps at ten distinct codes`() {
        let fake = FakeCrashReporter()
        let many = (0 ..< 25).map {
            ScoreParseDiagnostic(severity: .warning, code: "code.\($0)", message: "m", location: nil)
        }
        ScoreDiagnosticReporter(crashReporter: fake).report(many)
        #expect(fake.recordedErrors.count == 10)
    }

    @Test func `empty diagnostics record nothing`() {
        let fake = FakeCrashReporter()
        ScoreDiagnosticReporter(crashReporter: fake).report([])
        #expect(fake.recordedErrors.isEmpty)
    }
}
```

- [ ] **Step 4: Run the test to verify it fails**

Run the test command.
Expected: FAIL to compile — `cannot find 'ScoreDiagnosticReporter' in scope`.

- [ ] **Step 5: Write the reporter**

Create `Packages/Infrastructure/Sources/ScoreFiles/ScoreDiagnosticReporter.swift`:

```swift
import Foundation
import UtilityCore

/// Forwards parse diagnostics to crash telemetry. Per-parse policy:
/// - forward only `.warning` (see the spec's "Non-goals: .info" — `.info` has no producers yet and would only add
///   noise);
/// - dedupe by `code` so one file that trips the same anomaly repeatedly reports it once;
/// - cap at `maxPerParse` distinct codes as a flooding safety net.
///
/// No opt-out check here: `CrashReporter.record(error:)` is already a no-op when Crashlytics collection is disabled
/// (`PrivacySettingsKey.crashReportingEnabled == false`), keeping that gate in one place.
struct ScoreDiagnosticReporter: Sendable {
    let crashReporter: any CrashReporter

    private static let maxPerParse = 10

    func report(_ diagnostics: [ScoreParseDiagnostic]) {
        var seen = Set<String>()
        for diagnostic in diagnostics
            where diagnostic.severity == .warning && seen.insert(diagnostic.code).inserted {
            if seen.count > Self.maxPerParse { break }
            crashReporter.record(error: diagnostic.asNSError())
        }
    }
}
```

- [ ] **Step 6: Run the test to verify it passes**

Run the test command.
Expected: PASS (4 tests in `ScoreDiagnosticReporterTests`, plus Task 1's tests still green).

- [ ] **Step 7: Commit**

```bash
git add Packages/Infrastructure/Package.swift \
        Packages/Infrastructure/Sources/ScoreFiles/ScoreDiagnosticReporter.swift \
        Packages/Infrastructure/Tests/InfrastructureTests/TestSupport/FakeCrashReporter.swift \
        Packages/Infrastructure/Tests/InfrastructureTests/ScoreFiles/ScoreDiagnosticReporterTests.swift
git commit -m "feat(ScoreFiles): add ScoreDiagnosticReporter (warning-only, dedupe, cap)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Wire reporting into `LiveScoreFileGateway`

**Files:**
- Modify: `Packages/Infrastructure/Sources/ScoreFiles/LiveScoreFileGateway.swift`
- Test: `Packages/Infrastructure/Tests/InfrastructureTests/ScoreFiles/LiveScoreFileGatewayTests.swift`

- [ ] **Step 1: Write the failing regression test**

Append this test inside the existing `struct LiveScoreFileGatewayTests` in
`Packages/Infrastructure/Tests/InfrastructureTests/ScoreFiles/LiveScoreFileGatewayTests.swift`:

```swift
    @Test func `clean parse emits no diagnostics`() async throws {
        let tmp = try TempDirectory()
        let mscxURL = try Fixtures.writeToTempFile(
            Fixtures.minimalMSCXData(), ext: "mscx", in: tmp.url,
        )
        let fake = FakeCrashReporter()
        let gateway = LiveScoreFileGateway(crashReporter: fake)
        _ = try await gateway.loadScore(fileURL: mscxURL)
        #expect(fake.recordedErrors.isEmpty)
    }
```

- [ ] **Step 2: Run the test to verify it fails**

Run the test command.
Expected: FAIL to compile — `extra argument 'crashReporter' in call` (the gateway has no such initializer yet).

- [ ] **Step 3: Add the `crashReporter` dependency and import**

In `Packages/Infrastructure/Sources/ScoreFiles/LiveScoreFileGateway.swift`, add the import near the top (after `import Foundation`):

```swift
import UtilityCore
```

Replace the existing initializer:

```swift
public struct LiveScoreFileGateway: ScoreFileGateway {
    public init() {}
```

with a stored `crashReporter` and an injecting initializer that defaults to the no-op:

```swift
public struct LiveScoreFileGateway: ScoreFileGateway {
    private let crashReporter: any CrashReporter

    public init(crashReporter: any CrashReporter = NoopCrashReporter()) {
        self.crashReporter = crashReporter
    }
```

- [ ] **Step 4: Make the parse switch yield diagnostics and report them**

In the same file, inside `loadScore(fileURL:)`, the current `do` block builds `score` from a `switch` and returns. Replace the `let score: Score = switch format { … }` assignment and the following `return` with the version below. The format branches now return `(Score, [ScoreParseDiagnostic])` — every branch returns `[]` today; the MSCX/MSCZ branches carry an activation marker:

```swift
            do {
                let (score, diagnostics): (Score, [ScoreParseDiagnostic]) = switch format {
                case .mscx:
                    // TODO(parser-diagnostics): swap to MSCXParser.parseWithDiagnostics once the dependency lands.
                    (try SheetMusic.loadScore(mscxData: data), [])
                case .mscz:
                    // TODO(parser-diagnostics): swap to MSCZReader.parseWithDiagnostics once the dependency lands.
                    (try SheetMusic.loadScore(msczData: data), [])
                case .musicXML:
                    (try SheetMusic.loadScore(musicXMLData: data), [])
                case .mxl:
                    (try SheetMusic.loadScore(mxlData: data), [])
                case .midi:
                    (try SheetMusic.loadScore(
                        midiData: data,
                        sourceFilename: fileURL.deletingPathExtension().lastPathComponent,
                    ), [])
                }
                ScoreDiagnosticReporter(crashReporter: crashReporter).report(diagnostics)
                return (score, ScoreFileSummary(score: score))
            } catch let error as DomainError {
                throw error
            } catch {
                throw DomainError.scoreParseFailed(reason: "\(error)")
            }
```

(The `crashReporter` is `Sendable` and is captured safely inside the existing `Task.detached`. Reporting runs only after a successful parse; a thrown parse skips it.)

- [ ] **Step 5: Run the test to verify it passes**

Run the test command.
Expected: PASS — the full `LiveScoreFileGatewayTests` suite green, including `clean parse emits no diagnostics`, and Tasks 1–2 still green.

- [ ] **Step 6: Commit**

```bash
git add Packages/Infrastructure/Sources/ScoreFiles/LiveScoreFileGateway.swift \
        Packages/Infrastructure/Tests/InfrastructureTests/ScoreFiles/LiveScoreFileGatewayTests.swift
git commit -m "feat(ScoreFiles): report parse diagnostics from LiveScoreFileGateway

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Inject the crash reporter from the composition root

**Files:**
- Modify: `App/AppBootstrap.swift:43-46` (the `gateway` construction in `start()`)

- [ ] **Step 1: Pass the configured crash reporter into the gateway**

In `App/AppBootstrap.swift`, inside `start()`, the gateway is currently built with no arguments:

```swift
            let gateway = LiveScoreFileGateway()
```

`crashReporter` is configured a few lines above (`crashReporter = FirebaseCrashReporter.configure(...)`). Change the line to:

```swift
            let gateway = LiveScoreFileGateway(crashReporter: crashReporter ?? NoopCrashReporter())
```

(`AppBootstrap` already `import UtilityCore`, so `NoopCrashReporter` is in scope.)

- [ ] **Step 2: Regenerate the Xcode project**

The `ScoreFiles` target gained a `UtilityCore` dependency in Task 2; regenerate so the app project picks up the package graph change.

Run:
```bash
xcodegen generate
```
Expected: `Created project at .../Folino.xcodeproj`.

- [ ] **Step 3: Build the app to verify wiring compiles**

Run:
```bash
xcodebuild -project Folino.xcodeproj -scheme Folino -destination 'platform=iOS Simulator,name=iPhone 17' -skipPackagePluginValidation build 2>&1 | tail -20
```
Expected: `** BUILD SUCCEEDED **`. (iPhone 17 simulator — iPhone 16 is not installed on this machine.)

- [ ] **Step 4: Commit**

```bash
git add App/AppBootstrap.swift
git commit -m "feat(App): inject crash reporter into LiveScoreFileGateway

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Not in this plan (activation, once `swift-sheet-music` `feature/parser-diagnostics` is released)

These steps live in the design spec's "Activation steps" and are intentionally deferred — they require the released dependency:

1. Bump the `swift-sheet-music` revision in both `Packages/Infrastructure/Package.swift` and `project.yml`.
2. Confirm `import SheetMusicMSCX` / `SheetMusicCore` resolve in `ScoreFiles`; add the products to the `ScoreFiles` target if needed, then `xcodegen generate`.
3. Add `init(_ ssm: ScoreDiagnostic)` to `ScoreParseDiagnostic` (one-to-one field mapping).
4. Swap the MSCX/MSCZ branches in `LiveScoreFileGateway` from `SheetMusic.loadScore(…)` to `MSCXParser.parseWithDiagnostics(…)` / `MSCZReader.parseWithDiagnostics(…)`, mapping `result.diagnostics` through `ScoreParseDiagnostic.init(_:)`.
5. Add the end-to-end gateway test: a fixture with an unknown tremolo subtype yields exactly one `record(error:)` whose `domain == "mscx.tremolo.unknownSubtype"`.
