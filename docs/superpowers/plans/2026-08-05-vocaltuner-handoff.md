# VocalTuner Score Hand-Off Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a "VocalTunerで音程確認" row above the file formats in folino's share menu (library row + reader toolbar) that hands the score to VocalTuner in one tap, falling back to the system share sheet or VocalTuner's App Store page depending on what's installed.

**Architecture:** Feature packages see only a `VocalTunerHandoff` Domain protocol. The pure staging/decoding logic lands in `ImportExportAppGroup`, which already owns the cross-app contract for the inbound direction. The single UIKit/StoreKit adapter lives in `App/`. `ScoreUI`'s two share-menu views gain one optional closure, which is what puts the row in both features from one change.

**Tech Stack:** Swift 6.3, SwiftUI, Swift Testing (`@Test` / `#expect`), SwiftPM local packages, App Group `group.com.KeyNumber.shared`, StoreKit `SKStoreProductViewController`.

**Spec:** `docs/superpowers/specs/2026-08-05-vocaltuner-handoff-design.md`
**Wire contract (outside the repo):** `~/Desktop/vocaltuner-open-score-handoff.md`

## Global Constraints

- Work in the worktree `/Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/vocaltuner-handoff`, on branch `worktree-vocaltuner-handoff`. Never `cd` to the primary checkout. Use `git -C <worktree>` for every git call.
- **The staging directory is `IncomingScoresVT/`, never `IncomingScores/`.** folino's own `IncomingScoreCoordinator.drainAll()` sweeps every token under `IncomingScores/` unconditionally and would import the score it was trying to send.
- Shared App Group identifier: `group.com.KeyNumber.shared` (`SharedAppGroupIDs.identifier`, already defined).
- VocalTuner: bundle id `com.KeyNumber.VocalTuner`, URL scheme `vocaltuner`, App Store id `1505735245`. `vocaltuner` is already in `App/Info.plist`'s `LSApplicationQueriesSchemes` — do not add it again.
- The hand-off always sends `.museScoreV4` (`.mscz`), for every item including PDF-sourced ones. No per-item format branching.
- The menu row's label never changes across the three availability states.
- User-facing brand name is lowercase `folino`; `Folino` only in type names. VocalTuner is capitalized as `VocalTuner`.
- Localization keys follow `module.feature.thing`. All five locales must be filled: `en`, `ja`, `ko`, `zh-Hans`, `zh-Hant`.
- New tests use Swift Testing. Test function names in this repo use backtick-quoted natural language, e.g. `@Test func \`resolve returns not installed\`()`.
- Comments reflow at 120 columns, American spelling except where an Apple API dictates otherwise.
- Access modifiers: `public` only where the symbol crosses a module boundary.
- Package tests run through `xcodebuild`, never `swift test`. Destination is always `platform=iOS Simulator,name=iPhone 17 Pro Max`, and every command needs `-skipPackagePluginValidation`.
- Do not run `xcodebuild` in the background — wait for each result.

---

### Task 1: Domain — the `VocalTunerHandoff` protocol and availability resolution

**Files:**
- Create: `Packages/Domain/Sources/Domain/Protocols/VocalTunerHandoff.swift`
- Test: `Packages/Domain/Tests/DomainTests/Protocols/VocalTunerAvailabilityTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `VocalTunerCapabilities` (`protocolVersion: Int`, `vocalTunerAppVersion: String`, `Codable`), `VocalTunerAvailability` (`.notInstalled` / `.installedLegacy` / `.installedHandoffCapable`, plus `static func resolve(canOpenVocalTuner: Bool, capabilities: VocalTunerCapabilities?) -> VocalTunerAvailability` and `static let requiredProtocolVersion = 1`), `VocalTunerHandoffResult` (`.openedViaDeepLink` / `.needsShareFallback`), `@MainActor protocol VocalTunerHandoff` with `var availability: VocalTunerAvailability { get }`, `func openScore(fileURL: URL, displayName: String) -> VocalTunerHandoffResult`, `func presentAppStore()`, and `NoopVocalTunerHandoff()`.

- [ ] **Step 1: Write the failing test**

Create `Packages/Domain/Tests/DomainTests/Protocols/VocalTunerAvailabilityTests.swift`:

```swift
import Domain
import Testing

struct VocalTunerAvailabilityTests {
    @Test func `not installed when the scheme cannot be opened`() {
        let result = VocalTunerAvailability.resolve(
            canOpenVocalTuner: false,
            capabilities: VocalTunerCapabilities(protocolVersion: 1, vocalTunerAppVersion: "3.4.1"),
        )
        #expect(result == .notInstalled)
    }

    @Test func `legacy when installed without a capability stamp`() {
        let result = VocalTunerAvailability.resolve(canOpenVocalTuner: true, capabilities: nil)
        #expect(result == .installedLegacy)
    }

    @Test func `legacy when the stamp advertises a lower protocol version`() {
        let result = VocalTunerAvailability.resolve(
            canOpenVocalTuner: true,
            capabilities: VocalTunerCapabilities(protocolVersion: 0, vocalTunerAppVersion: "3.4.1"),
        )
        #expect(result == .installedLegacy)
    }

    @Test func `handoff capable when the stamp meets the required version`() {
        let result = VocalTunerAvailability.resolve(
            canOpenVocalTuner: true,
            capabilities: VocalTunerCapabilities(protocolVersion: 1, vocalTunerAppVersion: "3.4.1"),
        )
        #expect(result == .installedHandoffCapable)
    }

    @Test func `handoff capable when the stamp is ahead of the required version`() {
        let result = VocalTunerAvailability.resolve(
            canOpenVocalTuner: true,
            capabilities: VocalTunerCapabilities(protocolVersion: 7, vocalTunerAppVersion: "4.0.0"),
        )
        #expect(result == .installedHandoffCapable)
    }

    @Test func `capabilities decode from the stamp JSON`() throws {
        let json = Data(#"{"protocolVersion":1,"vocalTunerAppVersion":"3.4.1"}"#.utf8)
        let decoded = try JSONDecoder().decode(VocalTunerCapabilities.self, from: json)
        #expect(decoded == VocalTunerCapabilities(protocolVersion: 1, vocalTunerAppVersion: "3.4.1"))
    }
}
```

Add `import Foundation` at the top too — `Data` and `JSONDecoder` need it.

- [ ] **Step 2: Run the test to verify it fails**

Run from `Packages/Domain`:

```bash
xcodebuild test -scheme Domain \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -skipPackagePluginValidation \
  -only-testing:DomainTests/VocalTunerAvailabilityTests
```

Expected: compile failure — `cannot find 'VocalTunerAvailability' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Packages/Domain/Sources/Domain/Protocols/VocalTunerHandoff.swift`:

```swift
import Foundation

/// The capability stamp VocalTuner publishes at `vocaltuner/capabilities.json` in the shared App Group container.
///
/// folino reads it to decide whether the one-tap `vocaltuner://open-score` hand-off is available. No file, or a
/// `protocolVersion` below `VocalTunerAvailability.requiredProtocolVersion`, means fall back to the system share
/// sheet. This mirrors the `FolinoCapabilities` stamp folino writes for the inbound direction — the stamp is what
/// lets either side ship without a coordinated release.
public struct VocalTunerCapabilities: Codable, Sendable, Equatable {
    public let protocolVersion: Int
    public let vocalTunerAppVersion: String

    public init(protocolVersion: Int, vocalTunerAppVersion: String) {
        self.protocolVersion = protocolVersion
        self.vocalTunerAppVersion = vocalTunerAppVersion
    }
}

/// How far folino can go when handing a score to VocalTuner.
public enum VocalTunerAvailability: Equatable, Sendable {
    /// VocalTuner is not on the device. The share-menu row leads to its App Store page instead.
    case notInstalled
    /// Installed, but predating the `open-score` receiver (no stamp, or an older `protocolVersion`). Every
    /// VocalTuner build shipped before this feature is in this state, which is why the share-sheet fallback is not
    /// an edge case.
    case installedLegacy
    /// Installed and speaking the hand-off protocol — the one-tap path.
    case installedHandoffCapable

    /// Version of the `IncomingScoresVT/<token>` contract folino stages for. VocalTuner must advertise at least
    /// this to get the deep-link path.
    public static let requiredProtocolVersion = 1

    /// Pure decision logic, kept out of the UIKit adapter so it is unit-testable.
    public static func resolve(
        canOpenVocalTuner: Bool,
        capabilities: VocalTunerCapabilities?,
    ) -> VocalTunerAvailability {
        guard canOpenVocalTuner else { return .notInstalled }
        guard let capabilities, capabilities.protocolVersion >= requiredProtocolVersion else {
            return .installedLegacy
        }
        return .installedHandoffCapable
    }
}

/// Outcome of a staged hand-off attempt. `.needsShareFallback` covers both "installed but legacy" and "staging
/// failed" — in either case the caller presents the ordinary share sheet for the file it already prepared, so the
/// user still gets the score across.
public enum VocalTunerHandoffResult: Equatable, Sendable {
    case openedViaDeepLink
    case needsShareFallback
}

/// Hands a prepared score file to VocalTuner. The live implementation lives in the App composition root because it
/// is the only part that touches UIKit and StoreKit; Features depend on this protocol only.
@MainActor
public protocol VocalTunerHandoff: Sendable {
    /// Re-read on every access rather than cached: VocalTuner can be installed, updated, or removed while folino
    /// sits in the background, and a stale answer would send the user down the wrong branch.
    var availability: VocalTunerAvailability { get }

    /// Stage `fileURL` into the shared container and open `vocaltuner://open-score`. `displayName` is the score's
    /// user-facing title, used to name the staged copy.
    func openScore(fileURL: URL, displayName: String) -> VocalTunerHandoffResult

    /// Present VocalTuner's App Store page in-app.
    func presentAppStore()
}

/// Inert default so previews and tests that don't exercise the companion hand-off need no extra argument.
/// Production injects `LiveVocalTunerHandoff` from the App composition root.
///
/// Lives here rather than once per Feature because both Library and Reader want the same default — a per-feature
/// copy would be the same five lines twice. `public` is earned: it genuinely crosses module boundaries.
@MainActor
public struct NoopVocalTunerHandoff: VocalTunerHandoff {
    public init() {}
    public var availability: VocalTunerAvailability { .notInstalled }
    public func openScore(fileURL _: URL, displayName _: String) -> VocalTunerHandoffResult {
        .needsShareFallback
    }

    public func presentAppStore() {}
}
```

- [ ] **Step 4: Run the test to verify it passes**

Same command as Step 2. Expected: all 6 tests pass.

- [ ] **Step 5: Commit**

```bash
git -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/vocaltuner-handoff add \
  Packages/Domain/Sources/Domain/Protocols/VocalTunerHandoff.swift \
  Packages/Domain/Tests/DomainTests/Protocols/VocalTunerAvailabilityTests.swift
git -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/vocaltuner-handoff commit -m "feat(domain): add the VocalTuner hand-off protocol and availability resolution

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Domain — the `companion_handoff` analytics event

**Files:**
- Create: `Packages/Domain/Sources/Domain/Analytics/CompanionHandoffOutcome.swift`
- Modify: `Packages/Domain/Sources/Domain/Analytics/AnalyticsEvent+Factories.swift` (append to the `// MARK: Share` section, after `share(method:source:mode:)`)
- Test: `Packages/Domain/Tests/DomainTests/AnalyticsEventFactoryTests.swift`

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces: `AnalyticsEvent.companionHandoff(target: String, outcome: CompanionHandoffOutcome, source: AnalyticsSource) -> AnalyticsEvent` and `enum CompanionHandoffOutcome: String` with cases `deepLink = "deep_link"`, `shareFallback = "share_fallback"`, `appStore = "app_store"`, `failed = "failed"`.

- [ ] **Step 1: Write the failing test**

Append to `Packages/Domain/Tests/DomainTests/AnalyticsEventFactoryTests.swift`, inside the existing suite (match the file's existing style for how it reaches `event.parameters`):

```swift
@Test func `companion handoff event carries target outcome and source`() {
    let event = AnalyticsEvent.companionHandoff(
        target: "vocaltuner", outcome: .deepLink, source: .scoreRowMenu,
    )
    #expect(event.name == "companion_handoff")
    #expect(event.parameters["target"] == .string("vocaltuner"))
    #expect(event.parameters["outcome"] == .string("deep_link"))
    #expect(event.parameters["source"] == .string("score_row_menu"))
}

@Test func `companion handoff outcome raw values are snake case`() {
    #expect(CompanionHandoffOutcome.deepLink.rawValue == "deep_link")
    #expect(CompanionHandoffOutcome.shareFallback.rawValue == "share_fallback")
    #expect(CompanionHandoffOutcome.appStore.rawValue == "app_store")
    #expect(CompanionHandoffOutcome.failed.rawValue == "failed")
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run from `Packages/Domain`:

```bash
xcodebuild test -scheme Domain \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -skipPackagePluginValidation \
  -only-testing:DomainTests/AnalyticsEventFactoryTests
```

Expected: compile failure — `type 'AnalyticsEvent' has no member 'companionHandoff'`.

- [ ] **Step 3: Write the implementation**

Create `Packages/Domain/Sources/Domain/Analytics/CompanionHandoffOutcome.swift` — its own file, matching how
`AnalyticsSource.swift` and `AnalyticsScreen.swift` each hold one analytics enum (`DomainEnums+Analytics.swift` is
for extensions that map existing Domain enums to wire values, which this is not):

```swift
/// How far a companion-app hand-off actually got. Logged instead of a bare tap count because the gap between
/// "wanted this" and "could have this" is the number that says whether the companion integration paid off.
public enum CompanionHandoffOutcome: String, Sendable {
    case deepLink = "deep_link"
    case shareFallback = "share_fallback"
    case appStore = "app_store"
    case failed
}
```

And in `AnalyticsEvent+Factories.swift`, after `share(method:source:mode:)`:

```swift
/// Logged once the hand-off resolves, not on tap — matching how `share` is instrumented. `target` is the
/// companion app's short name so a future second companion needs no new event.
public static func companionHandoff(
    target: String,
    outcome: CompanionHandoffOutcome,
    source: AnalyticsSource,
) -> AnalyticsEvent {
    AnalyticsEvent(name: "companion_handoff", parameters: [
        "target": .string(target), "outcome": .string(outcome.rawValue),
        "source": .string(source.rawValue),
    ])
}
```

- [ ] **Step 4: Run the test to verify it passes**

Same command as Step 2. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/vocaltuner-handoff add Packages/Domain
git -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/vocaltuner-handoff commit -m "feat(domain): add the companion_handoff analytics event

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: `ImportExportAppGroup` — outbound paths, capability reader, and the stager

**Files:**
- Modify: `Packages/Features/ImportExport/Sources/ImportExportAppGroup/SharedScorePaths.swift`
- Create: `Packages/Features/ImportExport/Sources/ImportExportAppGroup/OutgoingScoreStager.swift`
- Test: `Packages/Features/ImportExport/Tests/ImportExportAppGroupTests/OutgoingScoreStagerTests.swift`

**Interfaces:**
- Consumes: `VocalTunerCapabilities` from Task 1; the existing `IncomingScoreIntent`, `SharedScorePaths`, and `ScoreExportNaming` (all already in the tree — `ScoreExportNaming` lives in `Domain/Protocols/ScoreShareService.swift`).
- Produces:
  - `SharedScorePaths.vocalTunerIncomingScoresDirname` (`"IncomingScoresVT"`), `.vocalTunerCapabilitiesDirname` (`"vocaltuner"`), and `static func vocalTunerIncomingScoresURL(in:)`, `vocalTunerTokenURL(token:in:)`, `vocalTunerTokenFilesURL(token:in:)`, `vocalTunerTokenIntentURL(token:in:)`, `vocalTunerCapabilitiesURL(in:)`.
  - `OutgoingScoreStager()` with `@discardableResult func stage(fileURL: URL, displayName: String, format: String, token: String, into container: URL, now: Date, fileManager: FileManager = .default) throws -> IncomingScoreIntent`.
  - `VocalTunerCapabilityReader(sharedContainer: URL)` with `func read() -> VocalTunerCapabilities?`.

- [ ] **Step 1: Write the failing test**

Create `Packages/Features/ImportExport/Tests/ImportExportAppGroupTests/OutgoingScoreStagerTests.swift`:

```swift
import Domain
import Foundation
@testable import ImportExportAppGroup
import Testing

struct OutgoingScoreStagerTests {
    private static let now = Date(timeIntervalSince1970: 100)

    /// Fresh temp dir standing in for the shared App Group container.
    private static func makeContainer() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "outgoing-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func makeSourceFile(named name: String) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "src-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appending(path: name, directoryHint: .notDirectory)
        try Data("score-bytes".utf8).write(to: file)
        return file
    }

    @Test func `stages the file and intent under the VocalTuner directory`() throws {
        let container = try Self.makeContainer()
        let source = try Self.makeSourceFile(named: "Air.mscz")

        let intent = try OutgoingScoreStager().stage(
            fileURL: source, displayName: "Air", format: "musescore",
            token: "TOKEN-1", into: container, now: Self.now,
        )

        let staged = container
            .appending(path: "IncomingScoresVT/TOKEN-1/files/Air.mscz", directoryHint: .notDirectory)
        #expect(FileManager.default.fileExists(atPath: staged.path))
        #expect(intent.files.first?.relativePath == "files/Air.mscz")
        #expect(intent.files.first?.originalName == "Air.mscz")
        #expect(intent.files.first?.format == "musescore")
        #expect(intent.source == "folino")
        #expect(intent.openAfter == true)
        #expect(intent.schemaVersion == 1)
        #expect(intent.token == "TOKEN-1")
    }

    @Test func `writes intent json the sibling can decode`() throws {
        let container = try Self.makeContainer()
        let source = try Self.makeSourceFile(named: "Air.mscz")

        try OutgoingScoreStager().stage(
            fileURL: source, displayName: "Air", format: "musescore",
            token: "TOKEN-2", into: container, now: Self.now,
        )

        let intentURL = container
            .appending(path: "IncomingScoresVT/TOKEN-2/intent.json", directoryHint: .notDirectory)
        let data = try Data(contentsOf: intentURL)
        // The `createdAt` must be an ISO-8601 string — a plain decoder must NOT be able to read it.
        #expect((try? JSONDecoder().decode(IncomingScoreIntent.self, from: data)) == nil)
        let decoded = try IncomingScoreIntent.decoder().decode(IncomingScoreIntent.self, from: data)
        #expect(decoded.createdAt == Self.now)
        #expect(decoded.source == "folino")
    }

    @Test func `sanitizes the display name into the staged filename`() throws {
        let container = try Self.makeContainer()
        let source = try Self.makeSourceFile(named: "A1B2C3.mscz")

        let intent = try OutgoingScoreStager().stage(
            fileURL: source, displayName: "Bach / Air: BWV 1068", format: "musescore",
            token: "TOKEN-3", into: container, now: Self.now,
        )

        // `/` and `:` are filesystem-hostile and become `_` (ScoreExportNaming.sanitize).
        #expect(intent.files.first?.originalName == "Bach _ Air_ BWV 1068.mscz")
        let staged = container.appending(
            path: "IncomingScoresVT/TOKEN-3/files/Bach _ Air_ BWV 1068.mscz", directoryHint: .notDirectory,
        )
        #expect(FileManager.default.fileExists(atPath: staged.path))
    }

    @Test func `re staging a token replaces the previous contents`() throws {
        let container = try Self.makeContainer()
        let first = try Self.makeSourceFile(named: "Old.mscz")
        let second = try Self.makeSourceFile(named: "New.mscz")

        try OutgoingScoreStager().stage(
            fileURL: first, displayName: "Old", format: "musescore",
            token: "TOKEN-4", into: container, now: Self.now,
        )
        try OutgoingScoreStager().stage(
            fileURL: second, displayName: "New", format: "musescore",
            token: "TOKEN-4", into: container, now: Self.now,
        )

        let filesDir = container
            .appending(path: "IncomingScoresVT/TOKEN-4/files", directoryHint: .isDirectory)
        let entries = try FileManager.default.contentsOfDirectory(atPath: filesDir.path)
        #expect(entries == ["New.mscz"])
    }

    @Test func `does not write into the inbound IncomingScores directory`() throws {
        let container = try Self.makeContainer()
        let source = try Self.makeSourceFile(named: "Air.mscz")

        try OutgoingScoreStager().stage(
            fileURL: source, displayName: "Air", format: "musescore",
            token: "TOKEN-5", into: container, now: Self.now,
        )

        // folino's own launch sweep drains IncomingScores/ unconditionally; an outbound score landing there
        // would be imported back into folino and scrubbed before VocalTuner ever saw it.
        let inbound = container.appending(path: "IncomingScores", directoryHint: .isDirectory)
        #expect(FileManager.default.fileExists(atPath: inbound.path) == false)
    }

    @Test func `capability reader returns nil when no stamp exists`() throws {
        let container = try Self.makeContainer()
        #expect(VocalTunerCapabilityReader(sharedContainer: container).read() == nil)
    }

    @Test func `capability reader decodes a stamp`() throws {
        let container = try Self.makeContainer()
        let url = SharedScorePaths.vocalTunerCapabilitiesURL(in: container)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
        )
        try Data(#"{"protocolVersion":1,"vocalTunerAppVersion":"3.4.1"}"#.utf8).write(to: url)

        let stamp = VocalTunerCapabilityReader(sharedContainer: container).read()
        #expect(stamp == VocalTunerCapabilities(protocolVersion: 1, vocalTunerAppVersion: "3.4.1"))
    }

    @Test func `capability reader returns nil for malformed json`() throws {
        let container = try Self.makeContainer()
        let url = SharedScorePaths.vocalTunerCapabilitiesURL(in: container)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
        )
        try Data("not json".utf8).write(to: url)

        #expect(VocalTunerCapabilityReader(sharedContainer: container).read() == nil)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run from `Packages/Features/ImportExport`:

```bash
xcodebuild test -scheme ImportExport-Package \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -skipPackagePluginValidation \
  -only-testing:ImportExportAppGroupTests/OutgoingScoreStagerTests
```

Expected: compile failure — `cannot find 'OutgoingScoreStager' in scope`.

- [ ] **Step 3: Extend `SharedScorePaths`**

Append to the `SharedScorePaths` enum in `SharedScorePaths.swift`, and extend that type's doc comment to mention the outbound direction:

```swift
    // MARK: - Outbound (folino → VocalTuner)

    /// Deliberately NOT `incomingScoresDirname`. `IncomingScoreCoordinator.drainAll()` sweeps every token under
    /// `IncomingScores/` with no notion of who a token is addressed to, so staging outbound hand-offs there would
    /// have folino import — and scrub — the score it was trying to send. The receiving side is new, so the sending
    /// side gets to pick a namespace nothing else touches.
    public static let vocalTunerIncomingScoresDirname = "IncomingScoresVT"
    public static let vocalTunerCapabilitiesDirname = "vocaltuner"

    public static func vocalTunerIncomingScoresURL(in container: URL) -> URL {
        container.appending(path: vocalTunerIncomingScoresDirname, directoryHint: .isDirectory)
    }

    public static func vocalTunerTokenURL(token: String, in container: URL) -> URL {
        vocalTunerIncomingScoresURL(in: container)
            .appending(path: token, directoryHint: .isDirectory)
    }

    public static func vocalTunerTokenFilesURL(token: String, in container: URL) -> URL {
        vocalTunerTokenURL(token: token, in: container)
            .appending(path: filesDirname, directoryHint: .isDirectory)
    }

    public static func vocalTunerTokenIntentURL(token: String, in container: URL) -> URL {
        vocalTunerTokenURL(token: token, in: container)
            .appending(path: intentFilename, directoryHint: .notDirectory)
    }

    /// Where VocalTuner stamps its capability file. folino only ever reads this.
    public static func vocalTunerCapabilitiesURL(in container: URL) -> URL {
        container
            .appending(path: vocalTunerCapabilitiesDirname, directoryHint: .isDirectory)
            .appending(path: capabilitiesFilename, directoryHint: .notDirectory)
    }
```

- [ ] **Step 4: Write the stager and capability reader**

Create `Packages/Features/ImportExport/Sources/ImportExportAppGroup/OutgoingScoreStager.swift`:

```swift
import Domain
import Foundation

/// Stages a prepared score file plus its `intent.json` for VocalTuner to pick up. The mirror image of VocalTuner's
/// `FolinoHandoffStager`, and pure `FileManager` for the same reason — the write path is the part worth testing,
/// and it should not need a device or a real App Group to test.
public struct OutgoingScoreStager: Sendable {
    public init() {}

    /// - Parameters:
    ///   - fileURL: the already-prepared export (`ScoreShareService.prepareShare`), whose bytes get copied.
    ///   - displayName: the score's user-facing title. Sanitized with `ScoreExportNaming` — the same rule
    ///     VocalTuner applies in the other direction — and given `fileURL`'s extension. VocalTuner addresses the
    ///     staged bytes by `originalName`, so the on-disk basename and `originalName` must stay identical.
    ///   - format: advisory `ScoreFormat`-style hint. The receiver re-derives the real format from the extension.
    ///   - token: opaque, URL-safe. The receiver validates it before using it as a path component.
    @discardableResult
    public func stage(
        fileURL: URL,
        displayName: String,
        format: String,
        token: String,
        into container: URL,
        now: Date,
        fileManager: FileManager = .default,
    ) throws -> IncomingScoreIntent {
        let root = SharedScorePaths.vocalTunerTokenURL(token: token, in: container)
        let filesDir = SharedScorePaths.vocalTunerTokenFilesURL(token: token, in: container)
        // Clear the whole token directory first: a retried hand-off on the same token must not leave the previous
        // export sitting next to the new one, where the receiver would import both.
        try? fileManager.removeItem(at: root)
        try fileManager.createDirectory(at: filesDir, withIntermediateDirectories: true)

        let stem = ScoreExportNaming.sanitize(title: displayName)
        let ext = fileURL.pathExtension
        let originalName = ext.isEmpty ? stem : "\(stem).\(ext)"
        let destination = filesDir.appending(path: originalName, directoryHint: .notDirectory)
        try fileManager.copyItem(at: fileURL, to: destination)

        let intent = IncomingScoreIntent(
            schemaVersion: 1,
            token: token,
            createdAt: now,
            source: "folino",
            openAfter: true,
            files: [
                .init(
                    relativePath: "\(SharedScorePaths.filesDirname)/\(originalName)",
                    originalName: originalName,
                    format: format,
                ),
            ],
        )
        let data = try IncomingScoreIntent.encoder().encode(intent)
        try data.write(
            to: SharedScorePaths.vocalTunerTokenIntentURL(token: token, in: container), options: .atomic,
        )
        return intent
    }
}

/// Reads VocalTuner's capability stamp out of the shared App Group container. Any failure — missing file,
/// unreadable bytes, malformed JSON — collapses to `nil`, which resolves to the share-sheet fallback rather than
/// to an error the user has to dismiss.
public struct VocalTunerCapabilityReader: Sendable {
    private let sharedContainer: URL

    public init(sharedContainer: URL) {
        self.sharedContainer = sharedContainer
    }

    public func read() -> VocalTunerCapabilities? {
        let url = SharedScorePaths.vocalTunerCapabilitiesURL(in: sharedContainer)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(VocalTunerCapabilities.self, from: data)
    }
}
```

- [ ] **Step 5: Run the test to verify it passes**

Same command as Step 2. Expected: all 8 tests pass.

- [ ] **Step 6: Commit**

```bash
git -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/vocaltuner-handoff add Packages/Features/ImportExport
git -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/vocaltuner-handoff commit -m "feat(importexport): stage outbound score hand-offs for VocalTuner

Stages into IncomingScoresVT/ rather than the inbound IncomingScores/, whose
launch sweep drains every token unconditionally.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: `ScoreUI` — the companion row in the share menu

**Files:**
- Modify: `Packages/ScoreUI/Sources/ScoreUI/ShareSubmenu.swift`
- Modify: `Packages/ScoreUI/Sources/ScoreUI/Resources/Localizable.xcstrings`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `ShareFormatMenuItems(loadFormats:onShare:companionAction:)` and `ShareSubmenu(loadFormats:onShare:companionAction:)`, where `companionAction: (() -> Void)? = nil` is the trailing parameter on both.

- [ ] **Step 1: Add the localized string**

In `Packages/ScoreUI/Sources/ScoreUI/Resources/Localizable.xcstrings`, add a `"scoreUI.share.vocalTuner.action"` entry alongside the existing `"scoreUI.format.*"` keys, matching their exact JSON shape (`"localizations"` → locale → `"stringUnit"` → `{"state": "translated", "value": ...}`):

| Locale | Value |
| --- | --- |
| `en` | `Check pitch in VocalTuner` |
| `ja` | `VocalTunerで音程確認` |
| `ko` | `VocalTuner에서 음정 확인` |
| `zh-Hans` | `在 VocalTuner 中检查音准` |
| `zh-Hant` | `在 VocalTuner 中檢查音準` |

- [ ] **Step 2: Add the parameter and the row to `ShareFormatMenuItems`**

In `ShareSubmenu.swift`, extend `ShareFormatMenuItems`:

```swift
    let loadFormats: @Sendable () async -> [ScoreShareFormatOption]
    let onShare: (ScoreShareFormat) -> Void
    let companionAction: (() -> Void)?
```

```swift
    public init(
        loadFormats: @escaping @Sendable () async -> [ScoreShareFormatOption],
        onShare: @escaping (ScoreShareFormat) -> Void,
        companionAction: (() -> Void)? = nil,
    ) {
        self.loadFormats = loadFormats
        self.onShare = onShare
        self.companionAction = companionAction
    }
```

and put the row at the top of `body`, above the `ForEach`:

```swift
    public var body: some View {
        if let companionAction {
            Button(action: companionAction) {
                Label {
                    Text("scoreUI.share.vocalTuner.action", bundle: .module)
                } icon: {
                    Image(systemName: "tuningfork")
                }
            }
            Divider()
        }
        ForEach(options, id: \.self) { option in
```

Also update the type's doc comment to say the companion row renders above the formats when `companionAction` is non-nil.

- [ ] **Step 3: Pass it through `ShareSubmenu`**

```swift
    let loadFormats: @Sendable () async -> [ScoreShareFormatOption]
    let onShare: (ScoreShareFormat) -> Void
    let companionAction: (() -> Void)?

    public init(
        loadFormats: @escaping @Sendable () async -> [ScoreShareFormatOption],
        onShare: @escaping (ScoreShareFormat) -> Void,
        companionAction: (() -> Void)? = nil,
    ) {
        self.loadFormats = loadFormats
        self.onShare = onShare
        self.companionAction = companionAction
    }

    public var body: some View {
        Menu {
            ShareFormatMenuItems(
                loadFormats: loadFormats, onShare: onShare, companionAction: companionAction,
            )
        } label: {
```

- [ ] **Step 4: Build the package**

Run from `Packages/ScoreUI`:

```bash
xcodebuild build -scheme ScoreUI \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -skipPackagePluginValidation
```

Expected: BUILD SUCCEEDED. The existing call sites still compile because `companionAction` defaults to `nil`.

- [ ] **Step 5: Commit**

```bash
git -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/vocaltuner-handoff add Packages/ScoreUI
git -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/vocaltuner-handoff commit -m "feat(scoreui): add an optional companion row above the share formats

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: Library — view-model branch and the score-row menu row

**Files:**
- Modify: `Packages/Features/Library/Sources/Library/LibraryViewModel.swift` (stored property + `init` + a new method next to `requestShare`)
- Modify: `Packages/Features/Library/Sources/Library/Views/ScoreRowMenu.swift`
- Modify: `Packages/Features/Library/Sources/Library/Screens/ScoreRowMenu+Library.swift`
- Create: `Packages/Features/Library/Tests/LibraryTests/Fakes/FakeVocalTunerHandoff.swift`
- Test: `Packages/Features/Library/Tests/LibraryTests/LibraryViewModelVocalTunerTests.swift`

**Interfaces:**
- Consumes: `VocalTunerHandoff`, `VocalTunerAvailability`, `VocalTunerHandoffResult` (Task 1); `AnalyticsEvent.companionHandoff` and `CompanionHandoffOutcome` (Task 2); `ShareFormatMenuItems` / `ShareSubmenu`'s `companionAction` (Task 4).
- Produces: `LibraryViewModel.init(..., vocalTunerHandoff:)` — a new parameter placed after `metadataReader:` and defaulting to `NoopVocalTunerHandoff()`; `LibraryViewModel.requestVocalTunerHandoff(_ item: ScoreItem, source: AnalyticsSource = .scoreRowMenu) async`; `scoreRowMenu(... onOpenInVocalTuner:)`.

- [ ] **Step 1: Write the fake and the failing test**

Create `Packages/Features/Library/Tests/LibraryTests/Fakes/FakeVocalTunerHandoff.swift`:

```swift
import Domain
import Foundation

/// Records what the view model asked of the hand-off, and lets a test pin the availability state and the result of
/// the staged open.
@MainActor
final class FakeVocalTunerHandoff: VocalTunerHandoff {
    var availabilityToReturn: VocalTunerAvailability = .installedHandoffCapable
    var openScoreResult: VocalTunerHandoffResult = .openedViaDeepLink
    private(set) var openScoreCalls: [(fileURL: URL, displayName: String)] = []
    private(set) var presentAppStoreCallCount = 0

    var availability: VocalTunerAvailability { availabilityToReturn }

    func openScore(fileURL: URL, displayName: String) -> VocalTunerHandoffResult {
        openScoreCalls.append((fileURL, displayName))
        return openScoreResult
    }

    func presentAppStore() {
        presentAppStoreCallCount += 1
    }
}
```

Create `Packages/Features/Library/Tests/LibraryTests/LibraryViewModelVocalTunerTests.swift`:

```swift
import Domain
import Foundation
@testable import Library
import Testing

@MainActor
struct LibraryViewModelVocalTunerTests {
    private static let base = Date(timeIntervalSince1970: 1_700_000_000)

    private static func makeItem() -> ScoreItem {
        ScoreItem(
            title: "Air", composer: nil, instrumentationSummary: nil,
            localFileName: "Air.mscz", contentHash: "h",
            sizeBytes: 0, lengthBeats: 0, defaultTempoBpm: 120,
            primaryKey: nil, addedAt: base, lastOpenedAt: nil,
            tagIDs: [], isFavorite: false,
        )
    }

    private static func makeVM() -> (LibraryViewModel, FakeScoreShareService, FakeVocalTunerHandoff, SpyAnalytics) {
        let share = FakeScoreShareService()
        let handoff = FakeVocalTunerHandoff()
        let analytics = SpyAnalytics()
        let vm = LibraryViewModel(
            repository: FakeScoreLibraryRepository(),
            importer: FakeScoreFileImporter(),
            gateway: FakeScoreFileGateway(),
            shareService: share,
            metadataReader: FakeScoreMetadataReading(),
            vocalTunerHandoff: handoff,
            analytics: analytics,
        )
        return (vm, share, handoff, analytics)
    }

    @Test func `not installed presents the app store and prepares no file`() async {
        let (vm, share, handoff, analytics) = Self.makeVM()
        handoff.availabilityToReturn = .notInstalled

        await vm.requestVocalTunerHandoff(Self.makeItem())

        #expect(handoff.presentAppStoreCallCount == 1)
        #expect(share.prepareShareCalls.isEmpty)
        #expect(vm.shareTarget == nil)
        #expect(analytics.event(named: "companion_handoff")?.parameters["outcome"] == .string("app_store"))
    }

    @Test func `handoff capable stages the mscz and takes the deep link`() async {
        let (vm, share, handoff, analytics) = Self.makeVM()
        share.prepareShareReturnURL = URL(fileURLWithPath: "/tmp/share/Air.mscz")

        await vm.requestVocalTunerHandoff(Self.makeItem())

        #expect(share.prepareShareCalls.first?.format == .museScoreV4)
        #expect(handoff.openScoreCalls.first?.displayName == "Air")
        #expect(handoff.openScoreCalls.first?.fileURL == URL(fileURLWithPath: "/tmp/share/Air.mscz"))
        #expect(vm.shareTarget == nil)
        #expect(analytics.event(named: "companion_handoff")?.parameters["outcome"] == .string("deep_link"))
        #expect(analytics.event(named: "companion_handoff")?.parameters["target"] == .string("vocaltuner"))
    }

    @Test func `share fallback populates the share target`() async {
        let (vm, share, handoff, analytics) = Self.makeVM()
        handoff.availabilityToReturn = .installedLegacy
        handoff.openScoreResult = .needsShareFallback
        share.prepareShareReturnURL = URL(fileURLWithPath: "/tmp/share/Air.mscz")

        await vm.requestVocalTunerHandoff(Self.makeItem())

        #expect(vm.shareTarget?.urls == [URL(fileURLWithPath: "/tmp/share/Air.mscz")])
        #expect(analytics.event(named: "companion_handoff")?.parameters["outcome"] == .string("share_fallback"))
    }

    @Test func `export failure surfaces an error and logs failed`() async {
        let (vm, share, handoff, analytics) = Self.makeVM()
        share.prepareShareError = .scoreParseFailed(reason: "boom")

        await vm.requestVocalTunerHandoff(Self.makeItem())

        #expect(vm.currentError != nil)
        #expect(handoff.openScoreCalls.isEmpty)
        #expect(analytics.event(named: "companion_handoff")?.parameters["outcome"] == .string("failed"))
    }

    @Test func `is preparing share toggles around the handoff`() async {
        let (vm, share, _, _) = Self.makeVM()
        share.prepareShareReturnURL = URL(fileURLWithPath: "/tmp/share/Air.mscz")
        await vm.requestVocalTunerHandoff(Self.makeItem())
        #expect(vm.isPreparingShare == false)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run from `Packages/Features/Library`:

```bash
xcodebuild test -scheme Library-Package \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -skipPackagePluginValidation \
  -only-testing:LibraryTests/LibraryViewModelVocalTunerTests
```

Expected: compile failure — `extra argument 'vocalTunerHandoff' in call`.

If the scheme name is rejected, list what exists with `xcodebuild -list` from the package directory and use the multi-product form (`<Pkg>-Package`) or the plain product name accordingly.

- [ ] **Step 3: Add the dependency and the method to `LibraryViewModel`**

Stored property, next to `metadataReader`:

```swift
    let vocalTunerHandoff: any VocalTunerHandoff
```

`init` parameter, after `metadataReader:` and before `analytics:`:

```swift
        vocalTunerHandoff: any VocalTunerHandoff = NoopVocalTunerHandoff(),
```

with `self.vocalTunerHandoff = vocalTunerHandoff` in the body. `NoopVocalTunerHandoff` comes from Domain (Task 1)
— do not define a local copy.

The method, right after `requestShare(_:format:source:)`:

```swift
    /// Hand this score to VocalTuner for pitch practice. Always exports `.museScoreV4` — it is the format that
    /// carries full pitch information and that VocalTuner accepts — and re-checks availability at tap time,
    /// because VocalTuner can be installed or removed while folino sits in the background.
    ///
    /// `.needsShareFallback` is not an error path: the file is already prepared, so the ordinary share sheet still
    /// gets the score across, and it is the state every VocalTuner build predating the receiver reports.
    func requestVocalTunerHandoff(_ item: ScoreItem, source: AnalyticsSource = .scoreRowMenu) async {
        guard vocalTunerHandoff.availability != .notInstalled else {
            vocalTunerHandoff.presentAppStore()
            analytics.log(.companionHandoff(target: "vocaltuner", outcome: .appStore, source: source))
            return
        }
        isPreparingShare = true
        defer { isPreparingShare = false }
        do {
            let url = try await shareService.prepareShare(item: item, format: .museScoreV4)
            let result = vocalTunerHandoff.openScore(fileURL: url, displayName: item.title)
            switch result {
            case .openedViaDeepLink:
                analytics.log(.companionHandoff(target: "vocaltuner", outcome: .deepLink, source: source))
            case .needsShareFallback:
                shareTarget = ScoreShareTarget(urls: [url])
                analytics.log(.companionHandoff(target: "vocaltuner", outcome: .shareFallback, source: source))
            }
        } catch {
            currentError = error
            analytics.log(.companionHandoff(target: "vocaltuner", outcome: .failed, source: source))
        }
    }
```

- [ ] **Step 4: Run the test to verify it passes**

Same command as Step 2. Expected: all 5 tests pass.

- [ ] **Step 5: Wire the row into the score-row menu**

In `Views/ScoreRowMenu.swift`, add a parameter after `onShare:`:

```swift
    onShare: @escaping (ScoreShareFormat) -> Void,
    onOpenInVocalTuner: @escaping () -> Void,
```

and pass it to the submenu:

```swift
    Divider()
    ShareSubmenu(
        loadFormats: loadShareFormats, onShare: onShare, companionAction: onOpenInVocalTuner,
    )
```

In `Screens/ScoreRowMenu+Library.swift`, supply it from the view model:

```swift
        onShare: { format in Task { await library.requestShare(item, format: format) } },
        onOpenInVocalTuner: { Task { await library.requestVocalTunerHandoff(item) } },
```

- [ ] **Step 6: Build and run the whole Library test target**

Run from `Packages/Features/Library`:

```bash
xcodebuild test -scheme Library-Package \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -skipPackagePluginValidation
```

Expected: BUILD SUCCEEDED and all existing Library tests still pass. Fix any `#Preview` or other call site the new required `onOpenInVocalTuner` parameter broke — pass `{}` in previews.

- [ ] **Step 7: Commit**

```bash
git -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/vocaltuner-handoff add Packages/Features/Library
git -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/vocaltuner-handoff commit -m "feat(library): hand a score to VocalTuner from the score-row share menu

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: Reader — view-model branch and the toolbar rows

**Files:**
- Modify: `Packages/Features/Reader/Sources/Reader/ReaderViewModel.swift` (stored property + `init`)
- Modify: `Packages/Features/Reader/Sources/Reader/ReaderViewModel+Sharing.swift`
- Modify: `Packages/Features/Reader/Sources/Reader/NoopScoreServices.swift`
- Modify: `Packages/Features/Reader/Sources/Reader/Screens/ReaderRootScreen.swift`
- Modify: `Packages/Features/Reader/Sources/Reader/Screens/ReaderToolbar.swift`
- Modify: `Packages/Features/Reader/Tests/ReaderTests/Fakes/FakeScoreShareService.swift`
- Create: `Packages/Features/Reader/Tests/ReaderTests/Fakes/FakeVocalTunerHandoff.swift`
- Test: `Packages/Features/Reader/Tests/ReaderTests/ReaderViewModelVocalTunerTests.swift`

**Interfaces:**
- Consumes: everything Task 5 consumed, plus the same `requestVocalTunerHandoff` shape.
- Produces: `ReaderViewModel.init(..., vocalTunerHandoff: any VocalTunerHandoff = NoopVocalTunerHandoff())` placed next to `shareService:`; `ReaderViewModel.requestVocalTunerHandoff() async`; `ReaderRootScreen.init(..., vocalTunerHandoff:)` placed after `shareService:`.

- [ ] **Step 1: Write the fake and the failing test**

Create `Packages/Features/Reader/Tests/ReaderTests/Fakes/FakeVocalTunerHandoff.swift` — identical body to the Library fake in Task 5 (the two test targets cannot share a file, and copying it is what every other `Fake*` in this repo does):

```swift
import Domain
import Foundation

/// Records what the view model asked of the hand-off, and lets a test pin the availability state and the result of
/// the staged open.
@MainActor
final class FakeVocalTunerHandoff: VocalTunerHandoff {
    var availabilityToReturn: VocalTunerAvailability = .installedHandoffCapable
    var openScoreResult: VocalTunerHandoffResult = .openedViaDeepLink
    private(set) var openScoreCalls: [(fileURL: URL, displayName: String)] = []
    private(set) var presentAppStoreCallCount = 0

    var availability: VocalTunerAvailability { availabilityToReturn }

    func openScore(fileURL: URL, displayName: String) -> VocalTunerHandoffResult {
        openScoreCalls.append((fileURL, displayName))
        return openScoreResult
    }

    func presentAppStore() {
        presentAppStoreCallCount += 1
    }
}
```

Reader's `FakeScoreShareService` is thinner than Library's — it has `preparedURL` / `formats` / `prepareCallCount`
and no way to record the requested format or to throw. Extend it (keep the existing members; other suites use
them):

```swift
final class FakeScoreShareService: ScoreShareService, @unchecked Sendable {
    var preparedURL = URL(filePath: "/tmp/shared.mscz")
    var formats: [ScoreShareFormatOption] = [ScoreShareFormatOption(format: .museScoreV4, isOriginal: true)]
    var prepareError: DomainError?
    private(set) var prepareCallCount = 0
    private(set) var requestedFormats: [ScoreShareFormat] = []

    func availableFormats(for _: ScoreItem) -> [ScoreShareFormatOption] {
        formats
    }

    func prepareShare(item _: ScoreItem, format: ScoreShareFormat) throws -> URL {
        prepareCallCount += 1
        requestedFormats.append(format)
        if let prepareError { throw prepareError }
        return preparedURL
    }
}
```

Create `Packages/Features/Reader/Tests/ReaderTests/ReaderViewModelVocalTunerTests.swift`:

```swift
import Domain
import Foundation
@testable import Reader
import Testing

@MainActor
struct ReaderViewModelVocalTunerTests {
    private static let base = Date(timeIntervalSince1970: 1_700_000_000)

    private static func makeItem() -> ScoreItem {
        ScoreItem(
            title: "Air", composer: nil, instrumentationSummary: nil,
            localFileName: "Air.mscz", contentHash: "h",
            sizeBytes: 0, lengthBeats: 0, defaultTempoBpm: 120,
            primaryKey: nil, addedAt: base, lastOpenedAt: nil,
            tagIDs: [], isFavorite: false,
        )
    }

    private static func makeVM() -> (ReaderViewModel, FakeScoreShareService, FakeVocalTunerHandoff, SpyAnalytics) {
        let share = FakeScoreShareService()
        let handoff = FakeVocalTunerHandoff()
        let analytics = SpyAnalytics()
        let vm = ReaderViewModel(
            scoreItem: makeItem(),
            repository: FakeScoreLibraryRepository(),
            gateway: FakeScoreFileGateway(),
            shareService: share,
            vocalTunerHandoff: handoff,
            scoresDirectory: URL(filePath: "/tmp"),
            playbackController: FakePlaybackController(),
            analytics: analytics,
        )
        return (vm, share, handoff, analytics)
    }

    @Test func `not installed presents the app store and prepares no file`() async {
        let (vm, share, handoff, analytics) = Self.makeVM()
        handoff.availabilityToReturn = .notInstalled

        await vm.requestVocalTunerHandoff()

        #expect(handoff.presentAppStoreCallCount == 1)
        #expect(share.prepareCallCount == 0)
        #expect(vm.shareTarget == nil)
        #expect(analytics.event(named: "companion_handoff")?.parameters["outcome"] == .string("app_store"))
    }

    @Test func `handoff capable stages the mscz and takes the deep link`() async {
        let (vm, share, handoff, analytics) = Self.makeVM()

        await vm.requestVocalTunerHandoff()

        #expect(share.requestedFormats == [.museScoreV4])
        #expect(handoff.openScoreCalls.count == 1)
        #expect(handoff.openScoreCalls.first?.displayName == "Air")
        #expect(vm.shareTarget == nil)
        #expect(analytics.event(named: "companion_handoff")?.parameters["outcome"] == .string("deep_link"))
        #expect(analytics.event(named: "companion_handoff")?.parameters["source"] == .string("reader_overlay"))
    }

    @Test func `share fallback populates the share target`() async {
        let (vm, share, handoff, analytics) = Self.makeVM()
        handoff.availabilityToReturn = .installedLegacy
        handoff.openScoreResult = .needsShareFallback

        await vm.requestVocalTunerHandoff()

        #expect(vm.shareTarget?.urls == [share.preparedURL])
        #expect(analytics.event(named: "companion_handoff")?.parameters["outcome"] == .string("share_fallback"))
    }

    @Test func `export failure logs failed and presents nothing`() async {
        let (vm, share, handoff, analytics) = Self.makeVM()
        share.prepareError = .scoreParseFailed(reason: "boom")

        await vm.requestVocalTunerHandoff()

        #expect(vm.shareTarget == nil)
        #expect(handoff.openScoreCalls.isEmpty)
        #expect(analytics.event(named: "companion_handoff")?.parameters["outcome"] == .string("failed"))
    }
}
```

If `ReaderViewModel.init`'s real parameter list differs from the call above (it has more parameters, most of them
defaulted — check `ReaderViewModel.swift` and the neighboring `ReaderAnalyticsTests.makeVM`), keep the arguments
that exist and drop the rest; the four shown by name (`shareService`, `vocalTunerHandoff`, `analytics`,
`scoreItem`) are the ones these tests depend on.

- [ ] **Step 2: Run the test to verify it fails**

Run from `Packages/Features/Reader`:

```bash
xcodebuild test -scheme Reader-Package \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -skipPackagePluginValidation \
  -only-testing:ReaderTests/ReaderViewModelVocalTunerTests
```

Expected: compile failure — `value of type 'ReaderViewModel' has no member 'requestVocalTunerHandoff'`.

- [ ] **Step 3: Add the dependency and the method**

`NoopVocalTunerHandoff` comes from Domain (Task 1) — do not add one to `NoopScoreServices.swift`, and do not
define a local copy. (`NoopScoreServices.swift` stays in the Files list only because you may want to note in its
header comment that the companion hand-off's no-op lives in Domain; leave the file alone otherwise.)

In `ReaderViewModel.swift`, next to `shareService`:

```swift
    @ObservationIgnored let vocalTunerHandoff: any VocalTunerHandoff
```

with the `init` parameter directly after `shareService:`:

```swift
        vocalTunerHandoff: any VocalTunerHandoff = NoopVocalTunerHandoff(),
```

and `self.vocalTunerHandoff = vocalTunerHandoff` in the body.

In `ReaderViewModel+Sharing.swift`, after `requestShare(format:)`:

```swift
    /// Hand this score to VocalTuner for pitch practice. Always exports `.museScoreV4`, and re-checks availability
    /// at tap time — VocalTuner can be installed or removed while folino sits in the background.
    ///
    /// Unlike Library, the Reader has no error banner, so an export failure presents nothing; the analytics
    /// `failed` outcome is how that case stays visible.
    func requestVocalTunerHandoff() async {
        guard vocalTunerHandoff.availability != .notInstalled else {
            vocalTunerHandoff.presentAppStore()
            analytics.log(.companionHandoff(target: "vocaltuner", outcome: .appStore, source: .readerOverlay))
            return
        }
        isPreparingShare = true
        defer { isPreparingShare = false }
        do {
            let url = try await shareService.prepareShare(item: scoreItem, format: .museScoreV4)
            switch vocalTunerHandoff.openScore(fileURL: url, displayName: scoreItem.title) {
            case .openedViaDeepLink:
                analytics.log(.companionHandoff(target: "vocaltuner", outcome: .deepLink, source: .readerOverlay))
            case .needsShareFallback:
                shareTarget = ScoreShareTarget(urls: [url])
                analytics.log(
                    .companionHandoff(target: "vocaltuner", outcome: .shareFallback, source: .readerOverlay),
                )
            }
        } catch {
            analytics.log(.companionHandoff(target: "vocaltuner", outcome: .failed, source: .readerOverlay))
        }
    }
```

- [ ] **Step 4: Run the test to verify it passes**

Same command as Step 2. Expected: all 4 tests pass.

- [ ] **Step 5: Wire both toolbar call sites**

`ReaderToolbar.swift` builds the share menu twice — once nested in the overflow `Menu` (`ShareSubmenu`, ~line 105) and once as the standalone share button (`ShareFormatMenuItems`, ~line 133). Add the same argument to both:

```swift
                        companionAction: {
                            Task { await viewModel.requestVocalTunerHandoff() }
                        },
```

- [ ] **Step 6: Thread the dependency through `ReaderRootScreen`**

`ReaderRootScreen.init` takes `shareService: any ScoreShareService` (~line 145) and forwards it into the
`ReaderViewModel(...)` it builds (~line 171). Add a `vocalTunerHandoff: any VocalTunerHandoff` parameter directly
after `shareService:` in the `init` signature, and pass `vocalTunerHandoff: vocalTunerHandoff` into that
`ReaderViewModel(...)` call in the same position. Give it **no default** — the App composition root is the only
caller and should be explicit about which adapter it injects.

- [ ] **Step 7: Build and run the whole Reader test target**

Run from `Packages/Features/Reader`:

```bash
xcodebuild test -scheme Reader-Package \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -skipPackagePluginValidation
```

Expected: BUILD SUCCEEDED and all existing Reader tests still pass.

- [ ] **Step 8: Commit**

```bash
git -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/vocaltuner-handoff add Packages/Features/Reader
git -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/vocaltuner-handoff commit -m "feat(reader): hand a score to VocalTuner from the toolbar share menu

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 7: App — the live adapter and composition-root wiring

**Files:**
- Create: `App/LiveVocalTunerHandoff.swift`
- Modify: `App/AppShellView.swift` (the `ReadyShell` dependency list, the `LibraryViewModel(...)` construction, and the `ReaderRootScreen(...)` construction)

**Interfaces:**
- Consumes: `VocalTunerHandoff` / `VocalTunerAvailability` / `VocalTunerHandoffResult` (Task 1); `OutgoingScoreStager`, `VocalTunerCapabilityReader`, `SharedScorePaths` (Task 3); `LibraryViewModel.init(vocalTunerHandoff:)` (Task 5); `ReaderRootScreen.init(vocalTunerHandoff:)` (Task 6).
- Produces: `LiveVocalTunerHandoff()`.

- [ ] **Step 1: Write the live adapter**

Create `App/LiveVocalTunerHandoff.swift`:

```swift
import Domain
import ImportExportAppGroup
import StoreKit
import UIKit

/// Live `VocalTunerHandoff`. The mirror image of VocalTuner's `LiveFolinoPromotionClient`, and the only type in
/// folino that touches `canOpenURL`, `UIApplication.open`, and StoreKit for this feature — everything below the
/// App layer sees the Domain protocol.
@MainActor
struct LiveVocalTunerHandoff: VocalTunerHandoff {
    /// VocalTuner's App Store id. Hardcoded for the same reason VocalTuner hardcodes folino's: it is a stable
    /// identity, and looking it up at runtime would put a network call in front of a menu tap.
    private static let appStoreID = 1_505_735_245
    private static let urlScheme = "vocaltuner"
    /// App Analytics campaign attribution for taps that originate in folino's share menu.
    private static let campaignToken = "folino-share-menu"
    /// ASC provider token (`pt`) for the shared App Store Connect account.
    private static let ascProviderToken = "121279510"

    /// `SKStoreProductViewControllerDelegate` is held weakly, so one retained instance backs every presentation.
    private static let storeDelegate = VocalTunerStoreDelegate()

    // swiftlint:disable:next force_unwrapping
    private static let probeURL = URL(string: "\(urlScheme)://")!

    var availability: VocalTunerAvailability {
        VocalTunerAvailability.resolve(
            canOpenVocalTuner: UIApplication.shared.canOpenURL(Self.probeURL),
            capabilities: Self.capabilities(),
        )
    }

    func openScore(fileURL: URL, displayName: String) -> VocalTunerHandoffResult {
        guard availability == .installedHandoffCapable,
              let container = SharedScorePaths.container()
        else {
            return .needsShareFallback
        }
        let token = UUID().uuidString
        do {
            try OutgoingScoreStager().stage(
                fileURL: fileURL, displayName: displayName, format: "musescore",
                token: token, into: container, now: Date(),
            )
        } catch {
            // The caller already has the exported file, so the share sheet still gets the score across.
            return .needsShareFallback
        }
        guard let url = URL(string: "\(Self.urlScheme)://open-score?token=\(token)") else {
            return .needsShareFallback
        }
        UIApplication.shared.open(url)
        return .openedViaDeepLink
    }

    func presentAppStore() {
        let controller = SKStoreProductViewController()
        controller.delegate = Self.storeDelegate
        controller.loadProduct(withParameters: [
            SKStoreProductParameterITunesItemIdentifier: Self.appStoreID,
            SKStoreProductParameterCampaignToken: Self.campaignToken,
            SKStoreProductParameterProviderToken: Self.ascProviderToken,
        ])
        Self.topViewController()?.present(controller, animated: true)
    }

    private static func capabilities() -> VocalTunerCapabilities? {
        guard let container = SharedScorePaths.container() else { return nil }
        return VocalTunerCapabilityReader(sharedContainer: container).read()
    }

    private static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        var top = scene?.keyWindow?.rootViewController
        while let presented = top?.presentedViewController {
            top = presented
        }
        return top
    }
}

/// Dismisses `SKStoreProductViewController` on "Done". Apple documents dismissal as the delegate's job; relying on
/// the controller dismissing itself is undocumented and would strand the user if that behavior ever changed.
private final class VocalTunerStoreDelegate: NSObject, SKStoreProductViewControllerDelegate {
    func productViewControllerDidFinish(_ viewController: SKStoreProductViewController) {
        viewController.presentingViewController?.dismiss(animated: true)
    }
}
```

- [ ] **Step 2: Wire it into `ReadyShell`**

In `App/AppShellView.swift`:

1. Add `let vocalTunerHandoff: any VocalTunerHandoff` to `ReadyShell`'s stored properties and to its `init` signature (after `metadataReader:`), assigning it in the body.
2. Pass `vocalTunerHandoff: vocalTunerHandoff` into the `LibraryViewModel(...)` construction in that same `init`.
3. Pass `vocalTunerHandoff: vocalTunerHandoff` into the `ReaderRootScreen(...)` construction (after `shareService:`).
4. At the `ReadyShell(...)` call site in `AppShellView.body`, pass `vocalTunerHandoff: LiveVocalTunerHandoff()`.

No `bootstrap` change is needed: the adapter is stateless and reads the container on demand.

- [ ] **Step 3: Build the app**

From the repo root of the worktree:

```bash
xcodegen generate
xcodebuild -project Folino.xcodeproj -scheme Folino \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -skipPackagePluginValidation build
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Verify the row renders**

Add a temporary `#Preview` next to `ShareFormatMenuItems` in `Packages/ScoreUI/Sources/ScoreUI/ShareSubmenu.swift` that wraps it in a `Menu` with `companionAction: {}`, render it with the Xcode MCP `RenderPreview`, and `Read` the resulting PNG. Confirm the VocalTuner row sits above the divider and the five formats below it. Remove the temporary preview afterwards unless it reads as a genuinely useful permanent one.

- [ ] **Step 5: Run every affected package's tests**

Run each from its package directory, waiting for each to finish:

```bash
xcodebuild test -scheme Domain -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation
xcodebuild test -scheme ImportExport-Package -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation
xcodebuild test -scheme Library-Package -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation
xcodebuild test -scheme Reader-Package -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation
```

Expected: all pass. Report the actual result — do not claim success without the output.

- [ ] **Step 6: Commit**

```bash
git -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/vocaltuner-handoff add App
git -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/vocaltuner-handoff commit -m "feat(app): wire the live VocalTuner hand-off into Library and Reader

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Manual verification (after Task 7)

These need a device or simulator with the real App Group and cannot be covered by tests. The hand-off's happy path
cannot be fully verified until the VocalTuner receiver ships — items 1 and 2 are what is checkable today.

1. **VocalTuner not installed** — the row opens VocalTuner's App Store page in-app, and "Done" dismisses it.
2. **VocalTuner installed, no stamp** (every build shipped today) — the row prepares the `.mscz` and presents the
   system share sheet with VocalTuner among the targets.
3. **After the VocalTuner receiver ships** — the row brings VocalTuner forward with the score open, and
   `IncomingScoresVT/<token>/` is gone afterwards.
4. **Regression** — folino's own inbound `folino://open-score` hand-off from VocalTuner still works, and nothing
   appeared under `IncomingScores/`.
