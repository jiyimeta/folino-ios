# Firebase Analytics Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Firebase Analytics to folino — a structured event per meaningful user action plus user properties for the settings/library snapshot — behind an opt-out toggle, shared across iOS and Android.

**Architecture:** Mirror the existing Crashlytics integration. A `Analytics` protocol + canonical `AnalyticsEvent`/`AnalyticsUserProperty` definitions live in `UtilityCore` (the parity contract). A `FirebaseAnalyticsClient` adapter in `Infrastructure/Analytics` is the only place importing the Firebase Analytics SDK. `AppBootstrap` builds the client and injects `any Analytics` into Feature view models via constructor injection. Android implements the same protocol with the Firebase Android SDK, driven by the shared catalog.

**Tech Stack:** Swift 6.3, SwiftPM modules, `firebase-ios-sdk` (already pinned, `from: 11.0.0`), GRDB (Persistence), Swift Testing for unit tests, Firebase Android SDK (Kotlin) for the Android backend.

## Global Constraints

- iOS 26+, Swift 6.3, bundle id `com.KeyNumber.Folino`. Android via swift-wirelet.
- **Layered modules:** Features never import Firebase or Infrastructure directly — only `any Analytics` from `UtilityCore`. Firebase imports stay in `Infrastructure/Analytics`. Domain is Foundation-only.
- **Access modifiers:** default `internal`; add `public` only where a type/member crosses a module boundary.
- **Brand:** user-visible copy uses lowercase `folino`; internal feature names (Reader/Editor/…) never appear in UI strings.
- **New tests use Swift Testing** (`import Testing`, `@Suite`, `@Test`, `#expect`). Fakes implement Domain/Utility protocols — no real Firebase in tests.
- **Privacy:** analytics collection is opt-out, default ON, gated by `privacyAnalyticsEnabled`. Stored preference is authoritative. No `setUserID`, no PII (no titles, file paths, search strings, raw counts — counts are bucketed; no `item_id`).
- **Event design:** semantic named events + low-cardinality params; reuse Firebase reserved names (`share`, `select_content`, `search`) where they map; no generic `button_tap`.
- **Comment reflow budget:** 120 columns.
- **Localization:** Settings strings live in the Settings package `.xcstrings`; key scheme `module.feature.thing`.
- **Package + project sync:** any Infrastructure product/target change updates both `Packages/Infrastructure/Package.swift` and `project.yml` `products:`.
- **Build/test command:** `xcodebuild test -scheme <Pkg|Pkg-Package> -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation` (run from the package dir for a single package). `swift test` does not work in this repo.

---

## Phase 1 — Shared analytics core (UtilityCore + Domain)

### Task 1: `AnalyticsValue` + `Analytics` protocol + `NoopAnalytics`

**Files:**
- Create: `Packages/Utility/Sources/UtilityCore/Analytics.swift`
- Test: `Packages/Utility/Tests/UtilityCoreTests/AnalyticsNoopTests.swift`

**Interfaces:**
- Produces: `Analytics` protocol; `AnalyticsValue` enum; `NoopAnalytics` struct.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
@testable import UtilityCore

@Suite struct AnalyticsNoopTests {
    @Test func noopAcceptsEventsAndPropertiesWithoutCrashing() {
        let analytics: any Analytics = NoopAnalytics()
        analytics.setCollectionEnabled(true)
        analytics.log(AnalyticsEvent(name: "test_event", parameters: ["k": .string("v")]))
        analytics.setUserProperty("page", for: AnalyticsUserProperty(name: "layout_mode"))
        // No assertion needed: the test passes if these calls compile and don't trap.
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme Utility -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation -only-testing:UtilityTests/AnalyticsNoopTests` (from `Packages/Utility`)
Expected: FAIL — `Analytics`, `AnalyticsEvent`, `AnalyticsUserProperty`, `NoopAnalytics` undefined.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

/// A single analytics parameter value. The adapter maps each case to the platform SDK's parameter encoding.
public enum AnalyticsValue: Sendable, Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
}

/// Ambient analytics abstraction. Production code depends on `any Analytics` rather than a concrete SDK so Features
/// stay testable and the SDK import stays in one Infrastructure target. Implementations must be safe to call from any
/// actor and must be best-effort: a failed log never throws to the caller.
public protocol Analytics: Sendable {
    /// Enable or disable collection. Implementations persist this across launches and no-op all logging while disabled.
    func setCollectionEnabled(_ enabled: Bool)
    /// Record a single event. No-op when collection is disabled.
    func log(_ event: AnalyticsEvent)
    /// Set (or clear, when `value` is nil) a user property. No-op when collection is disabled.
    func setUserProperty(_ value: String?, for property: AnalyticsUserProperty)
}

/// No-op `Analytics` for SwiftUI previews and tests. Never touches an analytics SDK.
public struct NoopAnalytics: Analytics {
    public init() {}
    public func setCollectionEnabled(_: Bool) {}
    public func log(_: AnalyticsEvent) {}
    public func setUserProperty(_: String?, for _: AnalyticsUserProperty) {}
}
```

- [ ] **Step 4: Run test to verify it passes** (after Task 2 defines `AnalyticsEvent`/`AnalyticsUserProperty`, this compiles)

Run: same command as Step 2.
Expected: PASS. (If run before Task 2, expect a compile error on the two undefined types — proceed to Task 2 first, then return.)

- [ ] **Step 5: Commit**

```bash
git add Packages/Utility/Sources/UtilityCore/Analytics.swift Packages/Utility/Tests/UtilityCoreTests/AnalyticsNoopTests.swift
git commit -m "feat(analytics): Analytics protocol + NoopAnalytics"
```

---

### Task 2: `AnalyticsEvent` + `AnalyticsUserProperty` value types

**Files:**
- Create: `Packages/Utility/Sources/UtilityCore/AnalyticsEvent.swift`
- Test: `Packages/Utility/Tests/UtilityCoreTests/AnalyticsEventTests.swift`

**Interfaces:**
- Consumes: `AnalyticsValue` (Task 1).
- Produces: `struct AnalyticsEvent { let name: String; let parameters: [String: AnalyticsValue] }`; `struct AnalyticsUserProperty { let name: String }`.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
@testable import UtilityCore

@Suite struct AnalyticsEventTests {
    @Test func eventStoresNameAndParameters() {
        let event = AnalyticsEvent(name: "score_imported", parameters: ["format": .string("mscz")])
        #expect(event.name == "score_imported")
        #expect(event.parameters["format"] == .string("mscz"))
    }

    @Test func userPropertyStoresWireName() {
        let property = AnalyticsUserProperty(name: "layout_mode")
        #expect(property.name == "layout_mode")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme Utility -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation -only-testing:UtilityTests/AnalyticsEventTests` (from `Packages/Utility`)
Expected: FAIL — types undefined.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

/// A wire-ready analytics event: a name plus low-cardinality parameters. Features never construct this directly with
/// raw strings — they call the typed factories in `AnalyticsEvent+Factories.swift`, which are the single source of
/// truth for event names and parameter keys (the iOS/Android parity contract).
public struct AnalyticsEvent: Sendable, Equatable {
    public let name: String
    public let parameters: [String: AnalyticsValue]

    public init(name: String, parameters: [String: AnalyticsValue] = [:]) {
        self.name = name
        self.parameters = parameters
    }
}

/// A wire-ready user-property key. Construct via the typed statics in `AnalyticsUserProperty+Keys.swift`.
public struct AnalyticsUserProperty: Sendable, Equatable {
    public let name: String
    public init(name: String) { self.name = name }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: same as Step 2.
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Packages/Utility/Sources/UtilityCore/AnalyticsEvent.swift Packages/Utility/Tests/UtilityCoreTests/AnalyticsEventTests.swift
git commit -m "feat(analytics): AnalyticsEvent + AnalyticsUserProperty value types"
```

---

### Task 3: `AnalyticsSource` + `countBucket` (Domain, shared, pure)

**Files:**
- Create: `Packages/Domain/Sources/Domain/Analytics/AnalyticsSource.swift`
- Create: `Packages/Domain/Sources/Domain/Analytics/AnalyticsBucketing.swift`
- Test: `Packages/Domain/Tests/DomainTests/AnalyticsBucketingTests.swift`

**Interfaces:**
- Produces: `enum AnalyticsSource: String` with cases `scoreRowMenu`, `bulkEdit`, `readerOverlay`, `scoreInfoSheet`, `recentlyOpened`, `favorites`, `playlist`, `tag`, `searchResult`, `libraryAll`; `func countBucket(_ count: Int) -> String`.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
@testable import Domain

@Suite struct AnalyticsBucketingTests {
    @Test(arguments: [
        (0, "0"), (1, "1-5"), (5, "1-5"), (6, "6-20"), (20, "6-20"),
        (21, "21-50"), (50, "21-50"), (51, "51+"), (1000, "51+"),
    ])
    func bucketsCounts(_ input: Int, _ expected: String) {
        #expect(countBucket(input) == expected)
    }

    @Test func sourceWireValuesAreSnakeCase() {
        #expect(AnalyticsSource.scoreRowMenu.rawValue == "score_row_menu")
        #expect(AnalyticsSource.searchResult.rawValue == "search_result")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme Domain -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation -only-testing:DomainTests/AnalyticsBucketingTests` (from `Packages/Domain`)
Expected: FAIL — `countBucket`, `AnalyticsSource` undefined.

- [ ] **Step 3: Write minimal implementation**

`AnalyticsSource.swift`:
```swift
/// The UI surface an action was initiated from. Carried as the `source` parameter on multi-path events
/// (favorite/delete/share/add-to-playlist) so analytics can attribute where each action originates.
public enum AnalyticsSource: String, Sendable {
    case scoreRowMenu = "score_row_menu"
    case bulkEdit = "bulk_edit"
    case readerOverlay = "reader_overlay"
    case scoreInfoSheet = "score_info_sheet"
    case recentlyOpened = "recently_opened"
    case favorites
    case playlist
    case tag
    case searchResult = "search_result"
    case libraryAll = "library_all"
}
```

`AnalyticsBucketing.swift`:
```swift
/// Bucket a raw count into a low-cardinality string so no precise magnitude reaches analytics.
public func countBucket(_ count: Int) -> String {
    switch count {
    case ..<1: "0"
    case 1...5: "1-5"
    case 6...20: "6-20"
    case 21...50: "21-50"
    default: "51+"
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: same as Step 2.
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Packages/Domain/Sources/Domain/Analytics Packages/Domain/Tests/DomainTests/AnalyticsBucketingTests.swift
git commit -m "feat(analytics): AnalyticsSource + countBucket in Domain"
```

---

### Task 4: Event factories (`AnalyticsEvent+Factories`)

**Files:**
- Create: `Packages/Domain/Sources/Domain/Analytics/AnalyticsEvent+Factories.swift`
- Test: `Packages/Domain/Tests/DomainTests/AnalyticsEventFactoryTests.swift`

> **Note on placement:** factories live in Domain (not UtilityCore) because they reference `AnalyticsSource`, `ScoreFormat`, `ScoreItemSort`, `ReaderLayoutMode`, `RepeatMode` — all Domain types. Domain depends on UtilityCore for `AnalyticsEvent`/`AnalyticsValue`. Confirm Domain already links `UtilityCore`; if not, add it to `Packages/Domain/Package.swift` `dependencies` for the `Domain` target.

**Interfaces:**
- Consumes: `AnalyticsEvent`, `AnalyticsValue` (UtilityCore); `AnalyticsSource`, `ScoreFormat`, `ScoreItemSort`, `ReaderLayoutMode`, `RepeatMode` (Domain).
- Produces: static factories on `AnalyticsEvent` — full list below. Each returns an `AnalyticsEvent` with the exact wire name/params from the spec catalog.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import UtilityCore
@testable import Domain

@Suite struct AnalyticsEventFactoryTests {
    @Test func scoreImportedCarriesFormatSourceDuplicateAndVersion() {
        let event = AnalyticsEvent.scoreImported(
            format: .mscz, source: "file_picker", isDuplicate: false, museScoreMajorVersion: 4)
        #expect(event.name == "score_imported")
        #expect(event.parameters["format"] == .string("mscz"))
        #expect(event.parameters["source"] == .string("file_picker"))
        #expect(event.parameters["is_duplicate"] == .bool(false))
        #expect(event.parameters["musescore_version"] == .string("4"))
    }

    @Test func scoreImportedWithoutVersionEmitsUnknown() {
        let event = AnalyticsEvent.scoreImported(
            format: .musicXML, source: "share_ext", isDuplicate: true, museScoreMajorVersion: nil)
        #expect(event.parameters["musescore_version"] == .string("unknown"))
    }

    @Test func favoriteToggledCarriesEnabledSourceMode() {
        let event = AnalyticsEvent.favoriteToggled(enabled: true, source: .scoreRowMenu, mode: .single)
        #expect(event.name == "favorite_toggled")
        #expect(event.parameters["enabled"] == .bool(true))
        #expect(event.parameters["source"] == .string("score_row_menu"))
        #expect(event.parameters["mode"] == .string("single"))
    }

    @Test func selectContentUsesReservedNameWithFrom() {
        let event = AnalyticsEvent.scoreOpened(from: .playlist)
        #expect(event.name == "select_content")
        #expect(event.parameters["content_type"] == .string("score"))
        #expect(event.parameters["from"] == .string("playlist"))
    }

    @Test func shareUsesReservedName() {
        let event = AnalyticsEvent.share(method: "pdf", source: .bulkEdit, mode: .bulk)
        #expect(event.name == "share")
        #expect(event.parameters["content_type"] == .string("score"))
        #expect(event.parameters["method"] == .string("pdf"))
        #expect(event.parameters["mode"] == .string("bulk"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme Domain -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation -only-testing:DomainTests/AnalyticsEventFactoryTests` (from `Packages/Domain`)
Expected: FAIL — factories undefined.

- [ ] **Step 3: Write minimal implementation**

```swift
import UtilityCore

/// A multiplicity tag for actions that can apply to one item or a bulk selection.
public enum AnalyticsActionMode: String, Sendable {
    case single
    case bulk
}

public extension AnalyticsEvent {
    // MARK: Library

    static func scoreImported(
        format: ScoreFormat, source: String, isDuplicate: Bool, museScoreMajorVersion: Int?,
    ) -> AnalyticsEvent {
        AnalyticsEvent(name: "score_imported", parameters: [
            "format": .string(format.analyticsValue),
            "source": .string(source),
            "is_duplicate": .bool(isDuplicate),
            "musescore_version": .string(museScoreMajorVersion.map(String.init) ?? "unknown"),
        ])
    }

    static func scoreImportFailed(format: String, reason: String) -> AnalyticsEvent {
        AnalyticsEvent(name: "score_import_failed",
                       parameters: ["format": .string(format), "reason": .string(reason)])
    }

    static func scoreOpened(from: AnalyticsSource) -> AnalyticsEvent {
        AnalyticsEvent(name: "select_content",
                       parameters: ["content_type": .string("score"), "from": .string(from.rawValue)])
    }

    static func sortChanged(_ sort: ScoreItemSort) -> AnalyticsEvent {
        AnalyticsEvent(name: "sort_changed", parameters: ["sort_order": .string(sort.analyticsValue)])
    }

    static func scoreDeleted(source: AnalyticsSource, mode: AnalyticsActionMode, count: Int) -> AnalyticsEvent {
        AnalyticsEvent(name: "score_deleted", parameters: [
            "source": .string(source.rawValue), "mode": .string(mode.rawValue), "count": .int(count),
        ])
    }

    static func favoriteToggled(enabled: Bool, source: AnalyticsSource, mode: AnalyticsActionMode) -> AnalyticsEvent {
        AnalyticsEvent(name: "favorite_toggled", parameters: [
            "enabled": .bool(enabled), "source": .string(source.rawValue), "mode": .string(mode.rawValue),
        ])
    }

    static func search() -> AnalyticsEvent { AnalyticsEvent(name: "search") }

    // MARK: Playlists & tags

    static func playlistCreated(source: AnalyticsSource) -> AnalyticsEvent {
        AnalyticsEvent(name: "playlist_created", parameters: ["source": .string(source.rawValue)])
    }
    static func playlistRenamed(source: AnalyticsSource) -> AnalyticsEvent {
        AnalyticsEvent(name: "playlist_renamed", parameters: ["source": .string(source.rawValue)])
    }
    static func playlistDeleted(source: AnalyticsSource) -> AnalyticsEvent {
        AnalyticsEvent(name: "playlist_deleted", parameters: ["source": .string(source.rawValue)])
    }
    static func playlistReordered() -> AnalyticsEvent { AnalyticsEvent(name: "playlist_reordered") }
    static func scoreAddedToPlaylist(source: AnalyticsSource, count: Int) -> AnalyticsEvent {
        AnalyticsEvent(name: "score_added_to_playlist",
                       parameters: ["source": .string(source.rawValue), "count": .int(count)])
    }
    static func scoreRemovedFromPlaylist(source: AnalyticsSource, count: Int) -> AnalyticsEvent {
        AnalyticsEvent(name: "score_removed_from_playlist",
                       parameters: ["source": .string(source.rawValue), "count": .int(count)])
    }
    static func tagCreated(source: AnalyticsSource) -> AnalyticsEvent {
        AnalyticsEvent(name: "tag_created", parameters: ["source": .string(source.rawValue)])
    }
    static func tagRenamed(source: AnalyticsSource) -> AnalyticsEvent {
        AnalyticsEvent(name: "tag_renamed", parameters: ["source": .string(source.rawValue)])
    }
    static func tagDeleted(source: AnalyticsSource) -> AnalyticsEvent {
        AnalyticsEvent(name: "tag_deleted", parameters: ["source": .string(source.rawValue)])
    }
    static func tagAssigned(source: AnalyticsSource, count: Int) -> AnalyticsEvent {
        AnalyticsEvent(name: "tag_assigned",
                       parameters: ["source": .string(source.rawValue), "count": .int(count)])
    }
    static func tagUnassigned(source: AnalyticsSource, count: Int) -> AnalyticsEvent {
        AnalyticsEvent(name: "tag_unassigned",
                       parameters: ["source": .string(source.rawValue), "count": .int(count)])
    }

    // MARK: Reader / playback

    static func playbackStarted(layoutMode: ReaderLayoutMode, from: AnalyticsSource) -> AnalyticsEvent {
        AnalyticsEvent(name: "playback_started", parameters: [
            "layout_mode": .string(layoutMode.analyticsValue), "from": .string(from.rawValue),
        ])
    }
    static func playbackCompleted() -> AnalyticsEvent { AnalyticsEvent(name: "playback_completed") }
    static func playbackControl(action: String) -> AnalyticsEvent {
        AnalyticsEvent(name: "playback_control", parameters: ["action": .string(action)])
    }
    static func repeatModeChanged(_ mode: RepeatMode) -> AnalyticsEvent {
        AnalyticsEvent(name: "repeat_mode_changed", parameters: ["mode": .string(mode.analyticsValue)])
    }
    static func tempoChanged(direction: String) -> AnalyticsEvent {
        AnalyticsEvent(name: "tempo_changed", parameters: ["direction": .string(direction)])
    }
    static func layoutModeChanged(_ mode: ReaderLayoutMode) -> AnalyticsEvent {
        AnalyticsEvent(name: "layout_mode_changed", parameters: ["mode": .string(mode.analyticsValue)])
    }
    static func transposeChanged(direction: String) -> AnalyticsEvent {
        AnalyticsEvent(name: "transpose_changed", parameters: ["direction": .string(direction)])
    }
    static func scoreInfoOpened(source: AnalyticsSource) -> AnalyticsEvent {
        AnalyticsEvent(name: "score_info_opened", parameters: ["source": .string(source.rawValue)])
    }
    static func annotationStarted() -> AnalyticsEvent { AnalyticsEvent(name: "annotation_started") }
    static func annotationInkCommitted() -> AnalyticsEvent { AnalyticsEvent(name: "annotation_ink_committed") }

    // MARK: Share

    static func share(method: String, source: AnalyticsSource, mode: AnalyticsActionMode) -> AnalyticsEvent {
        AnalyticsEvent(name: "share", parameters: [
            "content_type": .string("score"), "method": .string(method),
            "source": .string(source.rawValue), "mode": .string(mode.rawValue),
        ])
    }

    // MARK: Settings / app

    static func settingChanged(key: String, value: String) -> AnalyticsEvent {
        AnalyticsEvent(name: "setting_changed", parameters: ["key": .string(key), "value": .string(value)])
    }
    static func settingsOpened() -> AnalyticsEvent { AnalyticsEvent(name: "settings_opened") }
}
```

> The `.analyticsValue` properties referenced above (`ScoreFormat`, `ScoreItemSort`, `ReaderLayoutMode`, `RepeatMode`) are added in Task 5. Until then this file will not compile — implement Task 5 before running this test.

- [ ] **Step 4: Run test to verify it passes** (after Task 5)

Run: same as Step 2.
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Packages/Domain/Sources/Domain/Analytics/AnalyticsEvent+Factories.swift Packages/Domain/Tests/DomainTests/AnalyticsEventFactoryTests.swift
git commit -m "feat(analytics): typed AnalyticsEvent factories"
```

---

### Task 5: `analyticsValue` on Domain enums

**Files:**
- Create: `Packages/Domain/Sources/Domain/Analytics/DomainEnums+Analytics.swift`
- Test: `Packages/Domain/Tests/DomainTests/DomainEnumsAnalyticsTests.swift`

> Verify each enum's real case names first (`ScoreFormat`, `ScoreItemSort`, `ReaderLayoutMode`, `RepeatMode`) by reading their definitions under `Packages/Domain/Sources/Domain/Models/`. The mappings below assume the spec's wire values; adjust the right-hand strings only if a case name differs, never the wire string.

**Interfaces:**
- Produces: `var analyticsValue: String` on `ScoreFormat`, `ScoreItemSort`, `ReaderLayoutMode`, `RepeatMode`.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
@testable import Domain

@Suite struct DomainEnumsAnalyticsTests {
    @Test func scoreFormatWireValues() {
        #expect(ScoreFormat.mscx.analyticsValue == "mscx")
        #expect(ScoreFormat.mscz.analyticsValue == "mscz")
        #expect(ScoreFormat.musicXML.analyticsValue == "musicxml")
        #expect(ScoreFormat.mxl.analyticsValue == "mxl")
        #expect(ScoreFormat.midi.analyticsValue == "midi")
    }
    @Test func sortWireValues() {
        #expect(ScoreItemSort.dateAddedDesc.analyticsValue == "date_added")
        #expect(ScoreItemSort.titleAsc.analyticsValue == "title")
        #expect(ScoreItemSort.composerAsc.analyticsValue == "composer")
        #expect(ScoreItemSort.lastOpenedDesc.analyticsValue == "last_opened")
    }
    @Test func layoutWireValues() {
        #expect(ReaderLayoutMode.vertical.analyticsValue == "vertical")
        #expect(ReaderLayoutMode.horizontal.analyticsValue == "horizontal")
        #expect(ReaderLayoutMode.page.analyticsValue == "page")
    }
    @Test func repeatWireValues() {
        #expect(RepeatMode.off.analyticsValue == "off")
        #expect(RepeatMode.loopAll.analyticsValue == "loop_all")
        #expect(RepeatMode.abLoop.analyticsValue == "ab_loop")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme Domain -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation -only-testing:DomainTests/DomainEnumsAnalyticsTests` (from `Packages/Domain`)
Expected: FAIL — `analyticsValue` undefined.

- [ ] **Step 3: Write minimal implementation**

```swift
extension ScoreFormat {
    /// Stable wire value for analytics. Independent of `rawValue`/extension so refactors there don't shift analytics.
    public var analyticsValue: String {
        switch self {
        case .mscx: "mscx"
        case .mscz: "mscz"
        case .musicXML: "musicxml"
        case .mxl: "mxl"
        case .midi: "midi"
        }
    }
}

extension ScoreItemSort {
    public var analyticsValue: String {
        switch self {
        case .dateAddedDesc: "date_added"
        case .titleAsc: "title"
        case .composerAsc: "composer"
        case .lastOpenedDesc: "last_opened"
        }
    }
}

extension ReaderLayoutMode {
    public var analyticsValue: String {
        switch self {
        case .vertical: "vertical"
        case .horizontal: "horizontal"
        case .page: "page"
        }
    }
}

extension RepeatMode {
    public var analyticsValue: String {
        switch self {
        case .off: "off"
        case .loopAll: "loop_all"
        case .abLoop: "ab_loop"
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes** (run Task 4's suite too — it now compiles)

Run: same as Step 2, then re-run `-only-testing:DomainTests/AnalyticsEventFactoryTests`.
Expected: PASS for both.

- [ ] **Step 5: Commit**

```bash
git add Packages/Domain/Sources/Domain/Analytics/DomainEnums+Analytics.swift Packages/Domain/Tests/DomainTests/DomainEnumsAnalyticsTests.swift
git commit -m "feat(analytics): stable analyticsValue on Domain enums"
```

---

### Task 6: `AnalyticsUserProperty` keys

**Files:**
- Create: `Packages/Utility/Sources/UtilityCore/AnalyticsUserProperty+Keys.swift`
- Test: `Packages/Utility/Tests/UtilityCoreTests/AnalyticsUserPropertyKeyTests.swift`

**Interfaces:**
- Produces: typed statics on `AnalyticsUserProperty` for every property in the catalog.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
@testable import UtilityCore

@Suite struct AnalyticsUserPropertyKeyTests {
    @Test func keyWireNames() {
        #expect(AnalyticsUserProperty.layoutMode.name == "layout_mode")
        #expect(AnalyticsUserProperty.soundfontPreset.name == "soundfont_preset")
        #expect(AnalyticsUserProperty.currentSortOrder.name == "current_sort_order")
        #expect(AnalyticsUserProperty.librarySizeBucket.name == "library_size_bucket")
        #expect(AnalyticsUserProperty.crashReportingEnabled.name == "crash_reporting_enabled")
        #expect(AnalyticsUserProperty.hasUsedAnnotation.name == "has_used_annotation")
        #expect(AnalyticsUserProperty.scoreCountMscz2.name == "score_count_mscz2")
        #expect(AnalyticsUserProperty.scoreCountMscz3.name == "score_count_mscz3")
        #expect(AnalyticsUserProperty.scoreCountMscz4.name == "score_count_mscz4")
        #expect(AnalyticsUserProperty.scoreCountMusicXML.name == "score_count_musicxml")
        #expect(AnalyticsUserProperty.scoreCountMidi.name == "score_count_midi")
        #expect(AnalyticsUserProperty.scoreCountPdf.name == "score_count_pdf")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme Utility -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation -only-testing:UtilityTests/AnalyticsUserPropertyKeyTests` (from `Packages/Utility`)
Expected: FAIL — statics undefined.

- [ ] **Step 3: Write minimal implementation**

```swift
public extension AnalyticsUserProperty {
    static let layoutMode = AnalyticsUserProperty(name: "layout_mode")
    static let soundfontPreset = AnalyticsUserProperty(name: "soundfont_preset")
    static let currentSortOrder = AnalyticsUserProperty(name: "current_sort_order")
    static let librarySizeBucket = AnalyticsUserProperty(name: "library_size_bucket")
    static let crashReportingEnabled = AnalyticsUserProperty(name: "crash_reporting_enabled")
    static let hasUsedAnnotation = AnalyticsUserProperty(name: "has_used_annotation")
    static let scoreCountMscz2 = AnalyticsUserProperty(name: "score_count_mscz2")
    static let scoreCountMscz3 = AnalyticsUserProperty(name: "score_count_mscz3")
    static let scoreCountMscz4 = AnalyticsUserProperty(name: "score_count_mscz4")
    static let scoreCountMusicXML = AnalyticsUserProperty(name: "score_count_musicxml")
    static let scoreCountMidi = AnalyticsUserProperty(name: "score_count_midi")
    static let scoreCountPdf = AnalyticsUserProperty(name: "score_count_pdf")
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: same as Step 2.
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Packages/Utility/Sources/UtilityCore/AnalyticsUserProperty+Keys.swift Packages/Utility/Tests/UtilityCoreTests/AnalyticsUserPropertyKeyTests.swift
git commit -m "feat(analytics): AnalyticsUserProperty key catalog"
```

---

## Phase 2 — Firebase iOS adapter + composition wiring

### Task 7: `FirebaseAnalyticsClient` adapter + Infrastructure product

**Files:**
- Create: `Packages/Infrastructure/Sources/Analytics/FirebaseAnalyticsClient.swift`
- Modify: `Packages/Infrastructure/Package.swift` (add `Analytics` product + target depending on `FirebaseAnalytics`)
- Modify: `project.yml` (`products:` — add the `Analytics` product so the app links it)
- Test: `Packages/Infrastructure/Tests/AnalyticsTests/FirebaseAnalyticsClientGatingTests.swift`

**Interfaces:**
- Consumes: `Analytics`, `AnalyticsEvent`, `AnalyticsUserProperty`, `AnalyticsValue` (UtilityCore).
- Produces: `FirebaseAnalyticsClient` conforming to `Analytics`, with `@MainActor static func make(collectionEnabled:)`.

> **Design note for testability:** the gating no-op (don't log while disabled) is enforced in the adapter independent of the SDK, so it is unit-testable without Firebase. Extract the SDK call behind a small internal closure seam so the test can inject a recorder. The Firebase import stays in this file.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import UtilityCore
@testable import Analytics

@Suite struct FirebaseAnalyticsClientGatingTests {
    @Test func disabledClientDropsEventsAndProperties() {
        var loggedEvents: [String] = []
        var setProps: [String] = []
        let client = FirebaseAnalyticsClient(
            logEvent: { name, _ in loggedEvents.append(name) },
            setUserProperty: { _, name in setProps.append(name) })
        client.setCollectionEnabled(false)
        client.log(AnalyticsEvent(name: "score_imported"))
        client.setUserProperty("page", for: .layoutMode)
        #expect(loggedEvents.isEmpty)
        #expect(setProps.isEmpty)
    }

    @Test func enabledClientForwardsEvents() {
        var loggedEvents: [String] = []
        let client = FirebaseAnalyticsClient(
            logEvent: { name, _ in loggedEvents.append(name) },
            setUserProperty: { _, _ in })
        client.setCollectionEnabled(true)
        client.log(AnalyticsEvent(name: "score_imported"))
        #expect(loggedEvents == ["score_imported"])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme Infrastructure -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation -only-testing:InfrastructureTests/FirebaseAnalyticsClientGatingTests` (from `Packages/Infrastructure`)
Expected: FAIL — module/type undefined.

- [ ] **Step 3: Write minimal implementation**

`FirebaseAnalyticsClient.swift`:
```swift
import FirebaseAnalytics
import Foundation
import UtilityCore

/// `Analytics` backed by Firebase Analytics. The only place in folino that imports `FirebaseAnalytics`.
/// Logging is gated locally (in addition to the SDK-level disable) as defense-in-depth.
public struct FirebaseAnalyticsClient: Analytics {
    private let enabled = AnalyticsEnabledFlag()
    private let logEvent: @Sendable (_ name: String, _ parameters: [String: Any]) -> Void
    private let setUserPropertyImpl: @Sendable (_ value: String?, _ name: String) -> Void

    /// Seam constructor for tests. Production uses `make(collectionEnabled:)`.
    init(
        logEvent: @escaping @Sendable (_ name: String, _ parameters: [String: Any]) -> Void,
        setUserProperty: @escaping @Sendable (_ value: String?, _ name: String) -> Void,
    ) {
        self.logEvent = logEvent
        setUserPropertyImpl = setUserProperty
    }

    /// Production constructor. Assumes `FirebaseApp.configure()` already ran (the crash reporter owns that call).
    @MainActor
    public static func make(collectionEnabled: Bool) -> FirebaseAnalyticsClient {
        let client = FirebaseAnalyticsClient(
            logEvent: { FirebaseAnalytics.Analytics.logEvent($0, parameters: $1) },
            setUserProperty: { FirebaseAnalytics.Analytics.setUserProperty($0, forName: $1) })
        client.setCollectionEnabled(collectionEnabled)
        return client
    }

    public func setCollectionEnabled(_ on: Bool) {
        enabled.value = on
        FirebaseAnalytics.Analytics.setAnalyticsCollectionEnabled(on)
    }

    public func log(_ event: AnalyticsEvent) {
        guard enabled.value else { return }
        logEvent(event.name, event.parameters.mapValues(\.firebaseValue))
    }

    public func setUserProperty(_ value: String?, for property: AnalyticsUserProperty) {
        guard enabled.value else { return }
        setUserPropertyImpl(value, property.name)
    }
}

/// Thread-safe boolean for the local gate.
final class AnalyticsEnabledFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    var value: Bool {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

private extension AnalyticsValue {
    var firebaseValue: Any {
        switch self {
        case let .string(s): s
        case let .int(i): i
        case let .double(d): d
        case let .bool(b): b
        }
    }
}
```

`Package.swift` — add product + target (mirror the existing `CrashReporting` product):
```swift
// in products:
.library(name: "Analytics", targets: ["Analytics"]),
// in targets:
.target(
    name: "Analytics",
    dependencies: [
        "UtilityCore",
        .product(name: "FirebaseAnalytics", package: "firebase-ios-sdk"),
    ],
),
.testTarget(name: "AnalyticsTests", dependencies: ["Analytics"]),
```

`project.yml` — add `Analytics` alongside the existing `CrashReporting` entry under the Infrastructure package's `products:` list so the App target links it.

- [ ] **Step 4: Run test to verify it passes**

Run: same as Step 2.
Expected: PASS (gating tests). Then run `xcodegen generate` to refresh the project for the new product.

- [ ] **Step 5: Commit**

```bash
git add Packages/Infrastructure/Sources/Analytics Packages/Infrastructure/Tests/AnalyticsTests Packages/Infrastructure/Package.swift project.yml
git commit -m "feat(analytics): FirebaseAnalyticsClient adapter + Infrastructure product"
```

---

### Task 8: Enable Analytics in plist + `privacyAnalyticsEnabled` key

**Files:**
- Modify: `App/GoogleService-Info.plist` (`IS_ANALYTICS_ENABLED` → `true`)
- Modify: `Packages/Domain/Sources/Domain/Models/PrivacySettingsKey.swift` (add `analyticsEnabled`)
- Test: `Packages/Domain/Tests/DomainTests/PrivacySettingsKeyTests.swift`

**Interfaces:**
- Produces: `PrivacySettingsKey.analyticsEnabled == "privacyAnalyticsEnabled"`.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
@testable import Domain

@Suite struct PrivacySettingsKeyTests {
    @Test func analyticsKeyIsStableRawString() {
        #expect(PrivacySettingsKey.analyticsEnabled == "privacyAnalyticsEnabled")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme Domain -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation -only-testing:DomainTests/PrivacySettingsKeyTests` (from `Packages/Domain`)
Expected: FAIL — `analyticsEnabled` undefined.

- [ ] **Step 3: Write minimal implementation**

In `PrivacySettingsKey.swift`, add below `crashReportingEnabled`:
```swift
    /// Bool. Whether Firebase Analytics collection is enabled. Opt-out semantics: absent (first launch) is treated as
    /// `true`. Do not rename — the raw string is persisted user state.
    public static let analyticsEnabled = "privacyAnalyticsEnabled"
```

In `App/GoogleService-Info.plist`, set:
```xml
    <key>IS_ANALYTICS_ENABLED</key>
    <true/>
```

- [ ] **Step 4: Run test to verify it passes**

Run: same as Step 2.
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Packages/Domain/Sources/Domain/Models/PrivacySettingsKey.swift App/GoogleService-Info.plist Packages/Domain/Tests/DomainTests/PrivacySettingsKeyTests.swift
git commit -m "feat(analytics): enable Analytics collection + privacyAnalyticsEnabled key"
```

---

### Task 9: Wire `Analytics` into `AppBootstrap`

**Files:**
- Modify: `App/AppBootstrap.swift` (import `Analytics`; add `analytics` property; build it after the crash reporter)
- Test: manual — verified via Feature tests in later tasks; no new unit test for the composition root.

**Interfaces:**
- Consumes: `FirebaseAnalyticsClient.make(collectionEnabled:)` (Task 7).
- Produces: `AppBootstrap.analytics: (any Analytics)?` for injection into Feature view models.

- [ ] **Step 1: Add the property and build call**

In `App/AppBootstrap.swift`:
- Add `import Analytics` to the import block.
- Add the stored property beside `crashReporter`:
```swift
    private(set) var analytics: (any Analytics)?
```
- In `start()`, immediately after the `crashReporter = FirebaseCrashReporter.configure(...)` line, add:
```swift
        let analyticsEnabled = UserDefaults.standard
            .object(forKey: PrivacySettingsKey.analyticsEnabled) as? Bool ?? true
        analytics = FirebaseAnalyticsClient.make(collectionEnabled: analyticsEnabled)
```

- [ ] **Step 2: Build the app to verify it compiles**

Run: `xcodebuild -project Folino.xcodeproj -scheme Folino -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add App/AppBootstrap.swift
git commit -m "feat(analytics): build + hold Analytics client in AppBootstrap"
```

---

### Task 10: Analytics opt-out toggle in Settings

**Files:**
- Modify: `Packages/Features/Settings/Sources/Settings/Screens/PrivacySettingsSection.swift`
- Modify: the Settings string catalog (`Packages/Features/Settings/Sources/Settings/Resources/*.xcstrings`) — add `settings.privacy.analytics.title` / `.footer`
- Modify: the call site that constructs `PrivacySettingsSection` (search `PrivacySettingsSection(` under `Packages/Features/Settings`) to pass `analytics:`
- Modify: `App/` composition that injects into the Settings sheet — pass `bootstrap.analytics ?? NoopAnalytics()`
- Test: `Packages/Features/Settings/Tests/SettingsTests/PrivacyAnalyticsToggleTests.swift`

**Interfaces:**
- Consumes: `any Analytics` (UtilityCore), `PrivacySettingsKey.analyticsEnabled` (Domain).

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import UtilityCore
@testable import Settings

/// Recording fake for asserting collection-state forwarding.
final class SpyAnalytics: Analytics, @unchecked Sendable {
    private(set) var collectionStates: [Bool] = []
    func setCollectionEnabled(_ enabled: Bool) { collectionStates.append(enabled) }
    func log(_: AnalyticsEvent) {}
    func setUserProperty(_: String?, for _: AnalyticsUserProperty) {}
}

@Suite struct PrivacyAnalyticsToggleTests {
    @Test func togglingForwardsCollectionState() {
        let spy = SpyAnalytics()
        // The section's onChange handler is what we assert; drive it directly through a tiny seam if the View
        // exposes one, or via ViewInspector if already used in this package. If neither exists, assert the
        // handler closure used by `.onChange` calls `analytics.setCollectionEnabled(newValue)`.
        spy.setCollectionEnabled(false)
        #expect(spy.collectionStates == [false])
    }
}
```

> If the Settings package has no view-testing harness, keep this as a compile-level guarantee plus manual verification, and rely on the AppBootstrap launch path for the authoritative gate. Do not add a new test dependency just for this toggle.

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme Settings -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation -only-testing:SettingsTests/PrivacyAnalyticsToggleTests` (from `Packages/Features/Settings`)
Expected: FAIL — `analytics` parameter not yet on the section.

- [ ] **Step 3: Write minimal implementation**

In `PrivacySettingsSection.swift`:
- Add stored property `let analytics: any Analytics`.
- Add a second `@AppStorage(PrivacySettingsKey.analyticsEnabled) private var isAnalyticsEnabled = true`.
- Add a second `Toggle` inside the same `Section`, below the crash-reporting one:
```swift
            Toggle(isOn: $isAnalyticsEnabled) {
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("settings.privacy.analytics.title", bundle: .module)
                        Text("settings.privacy.analytics.footer", bundle: .module)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "chart.bar.xaxis")
                }
            }
            .onChange(of: isAnalyticsEnabled) { _, newValue in
                analytics.setCollectionEnabled(newValue)
            }
```
- Add the two localized strings to the Settings `.xcstrings`. Use user-facing copy that says "usage analytics / 使用状況の分析" — never the word "Reader"/"Editor" or other internal feature names. Suggested English: title "Share usage analytics", footer "Helps improve folino. No score contents are ever collected." Provide the Japanese localization too.
- Update every `PrivacySettingsSection(` call site to pass `analytics:`; at the App composition root inject `bootstrap.analytics ?? NoopAnalytics()`.

- [ ] **Step 4: Run test to verify it passes + build app**

Run: section test command from Step 2, then `xcodebuild -project Folino.xcodeproj -scheme Folino -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation build`.
Expected: PASS + BUILD SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
git add Packages/Features/Settings App
git commit -m "feat(analytics): usage-analytics opt-out toggle in Settings"
```

---

## Phase 3 — Persist mscz major version (prereq for format-count properties)

### Task 11: Add `museScoreMajorVersion` to `ScoreItem` + persistence

**Files:**
- Modify: `Packages/Domain/Sources/Domain/Models/ScoreItem.swift` (add `museScoreMajorVersion: Int?`)
- Modify: the GRDB record + migration in `Packages/Infrastructure/Sources/Persistence/` (add a nullable `museScoreMajorVersion` column via a new migration registered after the latest existing one)
- Modify: the importer (`LiveScoreFileImporter`) to read the metadata reader's `ScoreSourceKind.museScore(majorVersion:)` and persist it on the new `ScoreItem` field
- Test: `Packages/Infrastructure/Tests/PersistenceTests/ScoreItemMuseScoreVersionTests.swift`

**Interfaces:**
- Consumes: existing `ScoreSourceKind.museScore(majorVersion: Int)` bridge (`Domain/Protocols/ScoreMetadataReading.swift`).
- Produces: `ScoreItem.museScoreMajorVersion: Int?`, persisted; populated at import for mscz/mscx.

> **Read first:** open `ScoreItem.swift`, the GRDB record/migrations file under `Persistence`, and `LiveScoreFileImporter` to match the existing column-add migration pattern and the importer's metadata step. Existing rows get `nil` (backfill is not required; nil classifies as v4 default in Task 12, matching ssm detection).

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Domain
@testable import Persistence

@Suite struct ScoreItemMuseScoreVersionTests {
    @Test func roundTripsMajorVersionThroughDatabase() async throws {
        let db = try AppDatabase(databaseURL: URL(fileURLWithPath: "/dev/null").appendingPathExtension("sqlite"))
        // Use the package's existing in-memory/tmp DB helper if one exists; otherwise a tmp file URL.
        var item = ScoreItem.fixture() // use the existing test fixture helper in this package
        item.museScoreMajorVersion = 3
        try await db.upsert(item)
        let loaded = try await db.scoreItem(id: item.id)
        #expect(loaded?.museScoreMajorVersion == 3)
    }
}
```

> Adapt the DB-construction and upsert/load calls to the Persistence package's actual test helpers and repository API (read an existing Persistence test to copy the pattern). The assertion — major version survives a write/read round-trip — is the contract.

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme Infrastructure -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation -only-testing:InfrastructureTests/ScoreItemMuseScoreVersionTests` (from `Packages/Infrastructure`)
Expected: FAIL — field/column missing.

- [ ] **Step 3: Write minimal implementation**

- Add `public var museScoreMajorVersion: Int?` to `ScoreItem` (with default `nil` in the memberwise init; update any existing initializers/`Codable` accordingly).
- Add a GRDB migration registering `museScoreMajorVersion` as a nullable integer column on the scores table, following the existing migration registration style.
- In `LiveScoreFileImporter`, after metadata read, map `ScoreSourceKind.museScore(majorVersion:)` → set `item.museScoreMajorVersion`; leave `nil` for non-MuseScore formats.

- [ ] **Step 4: Run test to verify it passes**

Run: same as Step 2.
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Packages/Domain/Sources/Domain/Models/ScoreItem.swift Packages/Infrastructure/Sources/Persistence Packages/Infrastructure/Tests/PersistenceTests/ScoreItemMuseScoreVersionTests.swift
git commit -m "feat(analytics): persist mscz major version on ScoreItem"
```

---

## Phase 4 — User-property sync

### Task 12: `AnalyticsUserPropertySync` (compute + push properties)

**Files:**
- Create: `Packages/Domain/Sources/Domain/Analytics/AnalyticsUserPropertySync.swift`
- Test: `Packages/Domain/Tests/DomainTests/AnalyticsUserPropertySyncTests.swift`

**Interfaces:**
- Consumes: `[ScoreItem]`, `ScoreItemSort`, `any Analytics`, `AnalyticsUserProperty`, `countBucket`.
- Produces: `struct AnalyticsUserPropertySync` with `func syncLibrary(items:sort:into:)` and `func syncSetting(_:value:into:)` static helpers; pure mapping unit-tested.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import UtilityCore
@testable import Domain

private final class RecordingAnalytics: Analytics, @unchecked Sendable {
    var properties: [String: String?] = [:]
    func setCollectionEnabled(_: Bool) {}
    func log(_: AnalyticsEvent) {}
    func setUserProperty(_ value: String?, for property: AnalyticsUserProperty) { properties[property.name] = value }
}

@Suite struct AnalyticsUserPropertySyncTests {
    @Test func countsScoresByFormatAndMsczMajor() {
        let items = [
            ScoreItem.fixture(format: .mscz, museScoreMajorVersion: 4),
            ScoreItem.fixture(format: .mscz, museScoreMajorVersion: 4),
            ScoreItem.fixture(format: .mscz, museScoreMajorVersion: 3),
            ScoreItem.fixture(format: .mscz, museScoreMajorVersion: nil), // defaults to v4
            ScoreItem.fixture(format: .musicXML, museScoreMajorVersion: nil),
            ScoreItem.fixture(format: .midi, museScoreMajorVersion: nil),
        ]
        let rec = RecordingAnalytics()
        AnalyticsUserPropertySync.syncLibrary(items: items, sort: .titleAsc, into: rec)
        #expect(rec.properties["score_count_mscz4"] == "1-5") // two v4 + one nil-as-v4 = 3
        #expect(rec.properties["score_count_mscz3"] == "1-5")
        #expect(rec.properties["score_count_mscz2"] == "0")
        #expect(rec.properties["score_count_musicxml"] == "1-5")
        #expect(rec.properties["score_count_midi"] == "1-5")
        #expect(rec.properties["score_count_pdf"] == "0")
        #expect(rec.properties["library_size_bucket"] == "6-20")
        #expect(rec.properties["current_sort_order"] == "title")
    }
}
```

> `ScoreItem.fixture(format:museScoreMajorVersion:)` — extend the existing Domain test fixture helper with these parameters (or add a small local helper in the test). PDF is import-only and may not be a `ScoreFormat` case; count PDFs by file extension if `ScoreItem` exposes it, otherwise treat `score_count_pdf` as always "0" until PDF import lands (see PDF-import spec) and note that here.

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme Domain -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation -only-testing:DomainTests/AnalyticsUserPropertySyncTests` (from `Packages/Domain`)
Expected: FAIL — `AnalyticsUserPropertySync` undefined.

- [ ] **Step 3: Write minimal implementation**

```swift
import UtilityCore

/// Computes and pushes the library/settings user-property snapshot to analytics. Pure mapping; the caller decides
/// when to invoke it (launch, and after import/delete for the library half).
public enum AnalyticsUserPropertySync {
    public static func syncLibrary(items: [ScoreItem], sort: ScoreItemSort, into analytics: any Analytics) {
        analytics.setUserProperty(countBucket(items.count), for: .librarySizeBucket)
        analytics.setUserProperty(sort.analyticsValue, for: .currentSortOrder)

        func count(_ predicate: (ScoreItem) -> Bool) -> String { countBucket(items.filter(predicate).count) }

        // mscz split by major version; nil major on an mscz row defaults to v4 (matches ssm detection default).
        func msczMajor(_ item: ScoreItem) -> Int? { item.format == .mscz ? (item.museScoreMajorVersion ?? 4) : nil }
        analytics.setUserProperty(count { msczMajor($0) == 2 }, for: .scoreCountMscz2)
        analytics.setUserProperty(count { msczMajor($0) == 3 }, for: .scoreCountMscz3)
        analytics.setUserProperty(count { msczMajor($0) == 4 }, for: .scoreCountMscz4)
        analytics.setUserProperty(count { $0.format == .musicXML || $0.format == .mxl }, for: .scoreCountMusicXML)
        analytics.setUserProperty(count { $0.format == .midi }, for: .scoreCountMidi)
        // PDF: see note — until PDF import lands, this is always "0".
        analytics.setUserProperty(countBucket(0), for: .scoreCountPdf)
    }
}
```

> Adjust `item.format` access to `ScoreItem`'s real API (it may derive format from `localFileName`; add a computed `format: ScoreFormat?` on `ScoreItem` if one doesn't exist, in Domain, and unit-test that derivation here too).

- [ ] **Step 4: Run test to verify it passes**

Run: same as Step 2.
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Packages/Domain/Sources/Domain/Analytics/AnalyticsUserPropertySync.swift Packages/Domain/Tests/DomainTests/AnalyticsUserPropertySyncTests.swift
git commit -m "feat(analytics): library user-property sync"
```

---

### Task 13: Invoke property sync from `AppBootstrap` + settings snapshot

**Files:**
- Modify: `App/AppBootstrap.swift` — after `repository.refresh()`, call `AnalyticsUserPropertySync.syncLibrary(...)`; also push the settings-snapshot properties (`layout_mode`, `soundfont_preset`, `crash_reporting_enabled`, `has_used_annotation`) by reading UserDefaults
- Modify: the repository mutation points (import/delete) to re-run `syncLibrary` — preferably via an existing change hook on `LiveScoreLibraryRepository`; if none exists, call it from `AppBootstrap` after import/delete completions
- Test: covered by Task 12's pure test; composition wiring verified by app build + manual DebugView.

- [ ] **Step 1: Add the launch-time sync**

In `AppBootstrap.start()`, inside the existing `Task { ... }` after `try await repository.refresh()`:
```swift
                    if let analytics = self?.analytics {
                        let defaults = UserDefaults.standard
                        AnalyticsUserPropertySync.syncLibrary(
                            items: repository.scoreItems,
                            sort: /* current sort from settings */ .dateAddedDesc,
                            into: analytics)
                        analytics.setUserProperty(
                            defaults.string(forKey: ReaderGlobalSettingsKey.layoutMode), for: .layoutMode)
                        analytics.setUserProperty(
                            (defaults.object(forKey: PrivacySettingsKey.crashReportingEnabled) as? Bool ?? true)
                                ? "true" : "false",
                            for: .crashReportingEnabled)
                        // soundfont_preset + has_used_annotation: read their stored keys similarly.
                    }
```

> Read `ReaderGlobalSettingsKey` and the soundfont-preset / annotation-usage storage keys to fill the exact key names. Use the real current-sort key for `sort:`.

- [ ] **Step 2: Build the app**

Run: `xcodebuild -project Folino.xcodeproj -scheme Folino -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add App/AppBootstrap.swift
git commit -m "feat(analytics): push user-property snapshot at launch"
```

---

## Phase 5 — iOS event instrumentation

Each task below injects `any Analytics` into the relevant view model(s) via `init` (defaulting to `NoopAnalytics()` for previews/tests), then logs the catalog events at the real action sites. For every task: **read the view model first**, add the `analytics` parameter, update the App composition root to pass `bootstrap.analytics ?? NoopAnalytics()`, and assert with a `SpyAnalytics` fake that records `loggedEvents: [AnalyticsEvent]`.

> Shared test fake (add once to each Feature's test target, or to a shared test-support target if the repo has one):
> ```swift
> final class SpyAnalytics: Analytics, @unchecked Sendable {
>     private(set) var events: [AnalyticsEvent] = []
>     func setCollectionEnabled(_: Bool) {}
>     func log(_ event: AnalyticsEvent) { events.append(event) }
>     func setUserProperty(_: String?, for _: AnalyticsUserProperty) {}
> }
> ```

### Task 14: Library instrumentation

**Files:**
- Modify: Library view model(s) under `Packages/Features/Library/Sources/Library/` (import, open, sort change, delete, favorite toggle, search, playlist/tag CRUD, add/remove to playlist, tag assign/unassign)
- Modify: Library App composition to inject `analytics`
- Test: `Packages/Features/Library/Tests/LibraryTests/LibraryAnalyticsTests.swift`

**Events to log (with `source` for multi-path actions):**
- `score_imported` (on successful import; `source` = `file_picker`), `score_import_failed` (also record a Crashlytics non-fatal — inject the existing `any CrashReporter` if not already present)
- `scoreOpened(from:)` — set `from` per originating section (`libraryAll`/`recentlyOpened`/`favorites`/`playlist`/`tag`/`searchResult`)
- `sortChanged`
- `scoreDeleted(source:mode:count:)` — from row menu (`scoreRowMenu`, single) and bulk edit (`bulkEdit`, bulk)
- `favoriteToggled(enabled:source:mode:)` — from row menu and bulk
- `search()` — on search execution
- `playlistCreated/Renamed/Deleted`, `playlistReordered`, `scoreAddedToPlaylist`, `scoreRemovedFromPlaylist`
- `tagCreated/Renamed/Deleted`, `tagAssigned`, `tagUnassigned`

- [ ] **Step 1: Write the failing test** (representative — favorite from two sources)

```swift
import Testing
import Domain
import UtilityCore
@testable import Library

@Suite struct LibraryAnalyticsTests {
    @Test func favoriteFromRowMenuLogsSingleSource() async {
        let spy = SpyAnalytics()
        let vm = LibraryViewModel(/* existing deps + */ analytics: spy)
        await vm.toggleFavorite(/* a score id */, source: .scoreRowMenu) // add `source:` param to the method
        #expect(spy.events.contains { $0.name == "favorite_toggled"
            && $0.parameters["source"] == .string("score_row_menu")
            && $0.parameters["mode"] == .string("single") })
    }

    @Test func bulkFavoriteLogsBulkSource() async {
        let spy = SpyAnalytics()
        let vm = LibraryViewModel(/* deps + */ analytics: spy)
        await vm.bulkToggleFavorite(/* ids */) // already exists for bulk edit
        #expect(spy.events.contains { $0.name == "favorite_toggled"
            && $0.parameters["source"] == .string("bulk_edit")
            && $0.parameters["mode"] == .string("bulk") })
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme Library -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation -only-testing:LibraryTests/LibraryAnalyticsTests` (from `Packages/Features/Library`)
Expected: FAIL — `analytics:` param / `source:` param absent.

- [ ] **Step 3: Write minimal implementation**

- Add `private let analytics: any Analytics` to the view model(s); default `NoopAnalytics()` in `init`.
- Thread an `AnalyticsSource` into each multi-path action method (favorite/delete/share/add-to-playlist) so the call site (row menu vs bulk vs section) passes the originating surface; the views already know which surface they are.
- At each action site, after the existing mutation succeeds, call `analytics.log(.favoriteToggled(...))` etc. using the Task 4 factories.
- For `scoreOpened(from:)`, the navigation that opens the Reader passes the originating section as `AnalyticsSource`.
- Update the App composition to inject `bootstrap.analytics ?? NoopAnalytics()`.

- [ ] **Step 4: Run test to verify it passes + build app**

Run: test command from Step 2, then app build.
Expected: PASS + BUILD SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
git add Packages/Features/Library App
git commit -m "feat(analytics): instrument Library actions"
```

### Task 15: Reader / playback instrumentation

**Files:**
- Modify: Reader view model(s) under `Packages/Features/Reader/Sources/Reader/`
- Modify: Reader App composition to inject `analytics`
- Test: `Packages/Features/Reader/Tests/ReaderTests/ReaderAnalyticsTests.swift`

**Events:** `playbackStarted(layoutMode:from:)`, `playbackCompleted`, `playbackControl(action:)` (pause/prev/next/seek), `repeatModeChanged`, `tempoChanged(direction:)`, `layoutModeChanged`, `transposeChanged(direction:)`, `scoreInfoOpened(source: .readerOverlay)`, `share(method:source:.readerOverlay,mode:.single)`.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Domain
import UtilityCore
@testable import Reader

@Suite struct ReaderAnalyticsTests {
    @Test func playLogsPlaybackStartedWithLayoutAndOrigin() async {
        let spy = SpyAnalytics()
        let vm = ReaderViewModel(/* deps + */ analytics: spy, openedFrom: .playlist)
        await vm.play()
        #expect(spy.events.contains { $0.name == "playback_started"
            && $0.parameters["from"] == .string("playlist") })
    }
}
```

- [ ] **Step 2–5:** Same shape as Task 14 (run → fails; add `analytics` + `openedFrom` to the VM, log at each transport/inspector action; run → passes; build; commit).

```bash
git add Packages/Features/Reader App
git commit -m "feat(analytics): instrument Reader/playback actions"
```

### Task 16: Annotation instrumentation + `has_used_annotation`

**Files:**
- Modify: the annotation entry point (mode toggle → `annotationStarted`) and the PencilKit ink-commit path (→ `annotationInkCommitted`) under `Packages/Features/Reader/`
- Modify: on first ink commit, persist a UserDefaults flag (e.g. `analytics.hasUsedAnnotation`) and set the `has_used_annotation` user property to `"true"`
- Test: `Packages/Features/Reader/Tests/ReaderTests/AnnotationAnalyticsTests.swift`

> `annotation_ink_committed` must fire when ink is actually written (the PencilKit canvas commits a drawing), NOT when the mode is merely entered — that distinction is the whole point (real pencil-usage signal). Find the canvas/commit callback used by the M1 annotation work (see `project_pencil_annotation_m1` memory / `docs/.../ipad-pencil-annotation-design.md`).

- [ ] **Step 1: failing test** asserting an ink-commit callback logs `annotation_ink_committed` and sets `has_used_annotation`.
- [ ] **Step 2–5:** implement, run, build, commit.

```bash
git add Packages/Features/Reader
git commit -m "feat(analytics): annotation started + ink-committed events"
```

### Task 17: Share/import-failure split + Settings `setting_changed`

**Files:**
- Modify: `ImportExport` import path — on failure, both `analytics.log(.scoreImportFailed(...))` AND `crashReporter.record(error:)` (inject `any CrashReporter` if absent)
- Modify: share action sites (Library + Reader already covered for the event; ensure the share-format menu logs `share(method:...)` with the chosen `method`)
- Modify: each Settings toggle/picker `onChange` to log `settingChanged(key:value:)` (one helper for all controls in the Settings sections)
- Modify: Settings sheet presentation to log `settingsOpened`
- Test: `Packages/Features/Settings/Tests/SettingsTests/SettingChangedAnalyticsTests.swift` and an ImportExport failure test

- [ ] **Step 1: failing test** — a settings toggle change logs `setting_changed` with the right `key`/`value`; an import failure logs `score_import_failed` and records a Crashlytics non-fatal (assert via a `SpyCrashReporter`).
- [ ] **Step 2–5:** implement, run, build, commit.

```bash
git add Packages/Features/Settings Packages/Features/ImportExport App
git commit -m "feat(analytics): import-failure split + setting_changed events"
```

---

## Phase 6 — Android parity

> The Android backend reuses the **shared** event/property catalog (names, params, value enums, bucketing) — it does not re-derive it. Only the Firebase Android SDK call site and its wiring are Android-specific, mirroring the existing `android-crashlytics-opt-out` pattern. Read `docs/superpowers/specs/2026-06-09-android-crashlytics-opt-out-design.md` and the Android composition before starting. Build/install/launch per the Android workflow (`installDebug` + adb launch) for every Android-touching task.

### Task 18: Android `Analytics` implementation + opt-out

**Files:**
- Create: the Kotlin `Analytics` implementation calling `com.google.firebase:firebase-analytics`, wired into the Android composition where the Kotlin `CrashReporter` equivalent is wired
- Modify: Android Settings to add the usage-analytics opt-out toggle (mirror the iOS toggle copy + the Android Crashlytics toggle pattern)
- Modify: Android Gradle to add the `firebase-analytics` dependency and ensure `google-services.json` is present (analytics enabled)
- Test: Android instrumented/unit test asserting the catalog mapping + the opt-out gate, following the Crashlytics opt-out test pattern

- [ ] **Step 1–5:** failing test → implement Kotlin client + toggle → run Android tests → `installDebug` + launch to smoke-verify in Firebase DebugView → commit.

```bash
git add <android analytics + settings + gradle files>
git commit -m "feat(analytics-android): Firebase Analytics client + opt-out toggle"
```

### Task 19: Android event instrumentation + user-property sync

**Files:**
- Modify: Android Library/Reader/Settings action sites to log the same catalog events with the same `source` params as iOS
- Modify: Android launch/import/delete to call the shared user-property sync (port `AnalyticsUserPropertySync` via the shared Swift target if reachable from Android, or mirror its pure logic in the shared layer so both platforms call one implementation — do NOT hand-reimplement the mapping)
- Test: Android tests asserting representative events (favorite from two sources, playback_started `from`, setting_changed)

- [ ] **Step 1–5:** failing tests → instrument → run → install/launch smoke → commit.

```bash
git add <android instrumentation files>
git commit -m "feat(analytics-android): instrument actions + user-property sync"
```

---

## Optional follow-ups (not required for v1)

- **`SemanticVersion` generalization** (spec §Architecture): generalize `Domain/Models/AppVersion.swift` into a reusable `SemanticVersion` with `AppVersion` as a typealias. This is a Domain public-API rename — **confirm with the user before doing it**. v1 does not need it (analytics uses the existing `majorVersion: Int`).
- **Full mscz patch version** (e.g. `4.7.2`): requires swift-sheet-music to expose the raw `<museScore version>` string (its own example-app-verify → push → re-pin flow). Out of scope for v1.
- **Privacy nutrition label / Play Data Safety**: declare usage/diagnostics collection in App Store Connect and Play before release.
