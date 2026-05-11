# Version History Sheet Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship an in-app version-history sheet sourced from a hand-edited `VersionHistory.yml`, surfaced both from Settings and auto-presented on the first cold launch after an update — without colliding with the existing `ReviewPromptCoordinator` pre-prompt.

**Architecture:** Domain stays Foundation-only (`AppVersion`, `VersionHistoryEntry`). Settings owns the Yams-backed loader, the screen, and its view model. App owns the persistence key and a presenter that coordinates with `ReviewPromptCoordinator`. The screen never touches `UserDefaults` — both the auto-sheet and the Settings push report "seen" via injected closures.

**Tech Stack:** Swift 6.3, iOS 26+, SwiftUI, Swift Testing (new), Yams 5.3 (Settings only), `UserDefaults`, XcodeGen.

**Spec:** `docs/superpowers/specs/2026-05-11-version-history-design.md`

**Reference implementation:** `~/Developer/Personal/ios-apps/VocalTuner` (general shape only — Folino differs in `AppVersion` raw representation, loader placement, and review-prompt coordination).

---

## File Map

### Create
- `Packages/Domain/Sources/Domain/Models/AppVersion.swift`
- `Packages/Domain/Sources/Domain/Models/VersionHistoryEntry.swift`
- `Packages/Domain/Tests/DomainTests/Models/AppVersionTests.swift`
- `Packages/Domain/Tests/DomainTests/Models/VersionHistoryEntryTests.swift`
- `Packages/Features/Settings/Sources/Settings/VersionHistory/VersionHistoryLoader.swift`
- `Packages/Features/Settings/Sources/Settings/VersionHistory/VersionHistoryViewModel.swift`
- `Packages/Features/Settings/Sources/Settings/VersionHistory/VersionHistoryScreen.swift`
- `Packages/Features/Settings/Tests/SettingsTests/VersionHistory/DefaultVersionHistoryLoaderTests.swift`
- `Packages/Features/Settings/Tests/SettingsTests/VersionHistory/VersionHistoryViewModelTests.swift`
- `App/VersionHistoryPresenter.swift`
- `Tests/FolinoTests/VersionHistoryPresenterTests.swift`
- `Tests/FolinoTests/ReviewPromptCoordinatorTests.swift`

### Modify
- `Packages/Features/Settings/Package.swift` — add Yams dependency
- `Packages/Features/Settings/Sources/Settings/Resources/Localizable.xcstrings` — add 5 keys
- `Packages/Features/Settings/Sources/Settings/Screens/SettingsSheet.swift` — new init params, NavigationLink in `aboutSection`, `versionHistoryDestination()` helper
- `App/ReviewPromptCoordinator.swift` — add `suppressDisplay:` parameter
- `App/FolinoApp.swift` — instantiate presenter, order `.task` registrations
- `App/AppShellView.swift` — wire `onVersionHistoryViewed`, add auto-sheet binding
- `project.yml` — add Yams to `packages:`, add FolinoTests xctest target
- `App/Resources/VersionHistory.yml` — already present (entries 1.1.0, 1.1.1); leave intact

### Existing — referenced but not modified
- `App/Resources/VersionHistory.yml` — picked up by the existing `App` source glob (XcodeGen treats unknown extensions as resources). Verify after `xcodegen generate`.

---

## Yams version pin

Use `from: "5.3.0"` — the most recent 5.x release line, no breaking changes anticipated. If the SwiftPM resolver picks something newer in 5.x, accept it. Pin must match in both `Packages/Features/Settings/Package.swift` and `project.yml`'s `packages:` block.

---

## Task 1: `AppVersion` value type (Domain)

**Files:**
- Create: `Packages/Domain/Sources/Domain/Models/AppVersion.swift`
- Test: `Packages/Domain/Tests/DomainTests/Models/AppVersionTests.swift`

- [ ] **Step 1: Write failing tests**

`Packages/Domain/Tests/DomainTests/Models/AppVersionTests.swift`:

```swift
import Testing
@testable import Domain

@Suite struct AppVersionTests {
    @Test func initFromValidDottedString() {
        #expect(AppVersion("1.2.3") == AppVersion(1, 2, 3))
        #expect(AppVersion("0.0.0") == .zero)
        #expect(AppVersion("10.20.30") == AppVersion(10, 20, 30))
    }

    @Test(arguments: ["", "1", "1.2", "1.2.3.4", "1.2.x", "abc", "1..2"])
    func initFromInvalidStringReturnsNil(_ raw: String) {
        #expect(AppVersion(raw) == nil)
    }

    @Test func comparable() {
        let table: [(AppVersion, AppVersion)] = [
            (AppVersion(1, 0, 0), AppVersion(1, 0, 1)),
            (AppVersion(1, 0, 1), AppVersion(1, 1, 0)),
            (AppVersion(1, 1, 0), AppVersion(2, 0, 0)),
            (AppVersion(1, 9, 9), AppVersion(2, 0, 0)),
        ]
        for (lhs, rhs) in table {
            #expect(lhs < rhs)
            #expect(rhs > lhs)
            #expect(lhs != rhs)
        }
    }

    @Test func rawValueRoundTrip() {
        let cases = [AppVersion.zero, AppVersion(1, 2, 3), AppVersion(0, 0, 1), AppVersion(99, 99, 99)]
        for v in cases {
            #expect(AppVersion(rawValue: v.rawValue) == v)
            #expect(v.description == v.rawValue)
        }
    }

    @Test func zeroRawValue() {
        #expect(AppVersion.zero.rawValue == "0.0.0")
        #expect(AppVersion(rawValue: "0.0.0") == .zero)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd Packages/Domain && swift test --filter AppVersionTests`
Expected: FAIL with "cannot find 'AppVersion' in scope" or similar.

- [ ] **Step 3: Write minimal implementation**

`Packages/Domain/Sources/Domain/Models/AppVersion.swift`:

```swift
import Foundation

public struct AppVersion: Hashable, Sendable, Comparable, CustomStringConvertible, RawRepresentable {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(_ major: Int, _ minor: Int, _ patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public init?(_ string: String) {
        let parts = string.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        guard let major = Int(parts[0]),
              let minor = Int(parts[1]),
              let patch = Int(parts[2]) else { return nil }
        self.init(major, minor, patch)
    }

    public init?(rawValue: String) { self.init(rawValue) }

    public var rawValue: String { description }

    public var description: String { "\(major).\(minor).\(patch)" }

    public static let zero = AppVersion(0, 0, 0)

    public static let current: AppVersion = {
        let raw = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        guard let v = AppVersion(raw) else {
            fatalError("CFBundleShortVersionString is missing or malformed: \(raw)")
        }
        return v
    }()

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd Packages/Domain && swift test --filter AppVersionTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add Packages/Domain/Sources/Domain/Models/AppVersion.swift \
        Packages/Domain/Tests/DomainTests/Models/AppVersionTests.swift
git commit -m "Domain: add AppVersion value type for version history"
```

---

## Task 2: `VersionHistoryEntry` value type (Domain)

**Files:**
- Create: `Packages/Domain/Sources/Domain/Models/VersionHistoryEntry.swift`
- Test: `Packages/Domain/Tests/DomainTests/Models/VersionHistoryEntryTests.swift`

- [ ] **Step 1: Write failing tests**

`Packages/Domain/Tests/DomainTests/Models/VersionHistoryEntryTests.swift`:

```swift
import Foundation
import Testing
@testable import Domain

@Suite struct VersionHistoryEntryTests {
    @Test func decodesEnglishWhenLocaleIsEn() throws {
        let json = #"""
        {
          "version": "1.2.3",
          "descriptions": [
            {"en": "Added X", "ja": "Xを追加"},
            {"en": "Fixed Y", "ja": "Yを修正"}
          ]
        }
        """#.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.userInfo[VersionHistoryEntry.localeUserInfoKey] = Locale(identifier: "en_US")
        let entry = try decoder.decode(VersionHistoryEntry.self, from: json)

        #expect(entry.version == AppVersion(1, 2, 3))
        #expect(entry.descriptions == ["Added X", "Fixed Y"])
        #expect(entry.id == AppVersion(1, 2, 3))
    }

    @Test func decodesJapaneseWhenLocaleIsJa() throws {
        let json = #"""
        {
          "version": "1.2.3",
          "descriptions": [
            {"en": "Added X", "ja": "Xを追加"}
          ]
        }
        """#.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.userInfo[VersionHistoryEntry.localeUserInfoKey] = Locale(identifier: "ja_JP")
        let entry = try decoder.decode(VersionHistoryEntry.self, from: json)

        #expect(entry.descriptions == ["Xを追加"])
    }

    @Test func decodesEmptyDescriptions() throws {
        let json = #"""
        {"version": "1.0.0", "descriptions": []}
        """#.data(using: .utf8)!
        let entry = try JSONDecoder().decode(VersionHistoryEntry.self, from: json)
        #expect(entry.version == AppVersion(1, 0, 0))
        #expect(entry.descriptions.isEmpty)
    }

    @Test func decodingFailsForMalformedVersion() {
        let json = #"""
        {"version": "1.x.0", "descriptions": []}
        """#.data(using: .utf8)!
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(VersionHistoryEntry.self, from: json)
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd Packages/Domain && swift test --filter VersionHistoryEntryTests`
Expected: FAIL with "cannot find 'VersionHistoryEntry' in scope".

- [ ] **Step 3: Write minimal implementation**

`Packages/Domain/Sources/Domain/Models/VersionHistoryEntry.swift`:

```swift
import Foundation

public struct VersionHistoryEntry: Equatable, Identifiable, Sendable, Decodable {
    public let version: AppVersion
    public let descriptions: [String]
    public var id: AppVersion { version }

    public init(version: AppVersion, descriptions: [String]) {
        self.version = version
        self.descriptions = descriptions
    }

    /// Inject a `Locale` into `Decoder.userInfo` under this key to override
    /// the default `Locale.current` lookup. Tests use this; production code
    /// can leave `userInfo` empty.
    public static let localeUserInfoKey = CodingUserInfoKey(rawValue: "VersionHistoryEntry.locale")!

    private enum CodingKeys: String, CodingKey {
        case version
        case descriptions
    }

    private struct LocalizedDescription: Decodable {
        let en: String
        let ja: String
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let versionString = try container.decode(String.self, forKey: .version)
        guard let parsed = AppVersion(versionString) else {
            throw DecodingError.dataCorruptedError(
                forKey: .version,
                in: container,
                debugDescription: "Malformed version string: \(versionString)"
            )
        }
        version = parsed

        let entries = try container.decode([LocalizedDescription].self, forKey: .descriptions)
        let locale = decoder.userInfo[Self.localeUserInfoKey] as? Locale ?? .current
        let isJa = locale.language.languageCode?.identifier == "ja"
        descriptions = entries.map { isJa ? $0.ja : $0.en }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd Packages/Domain && swift test --filter VersionHistoryEntryTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Packages/Domain/Sources/Domain/Models/VersionHistoryEntry.swift \
        Packages/Domain/Tests/DomainTests/Models/VersionHistoryEntryTests.swift
git commit -m "Domain: add VersionHistoryEntry with locale-resolved descriptions"
```

---

## Task 3: Add Yams dependency to Settings

**Files:**
- Modify: `Packages/Features/Settings/Package.swift`
- Modify: `project.yml` — `packages:` block

- [ ] **Step 1: Add Yams to Settings Package.swift**

Edit `Packages/Features/Settings/Package.swift`. In the `dependencies:` array, add:

```swift
        .package(url: "https://github.com/jpsim/Yams", from: "5.3.0"),
```

In the `Settings` target's `dependencies:` array, add:

```swift
                .product(name: "Yams", package: "Yams"),
```

Final shape:

```swift
    dependencies: [
        .package(url: "https://github.com/devicekit/devicekit", from: "5.8.0"),
        .package(url: "https://github.com/jpsim/Yams", from: "5.3.0"),
        .package(url: "https://github.com/SimplyDanny/SwiftLintPlugins", from: "0.63.2"),
        .package(path: "../../Domain"),
        .package(path: "../../Utility"),
    ],
    targets: [
        .target(
            name: "Settings",
            dependencies: [
                "Domain",
                .product(name: "DeviceKit", package: "DeviceKit"),
                .product(name: "UtilityCore", package: "Utility"),
                .product(name: "UtilityUI", package: "Utility"),
                .product(name: "Yams", package: "Yams"),
            ],
            resources: [.process("Resources")],
            plugins: swiftLintPlugins
        ),
        .testTarget(name: "SettingsTests", dependencies: ["Settings", "Domain"]),
    ]
```

- [ ] **Step 2: Add Yams to project.yml**

Edit `project.yml`. Under `packages:`, append:

```yaml
  Yams:
    url: https://github.com/jpsim/Yams
    from: 5.3.0
```

(Do **not** add Yams to the `Folino` target's `dependencies:` block — the App layer accesses Yams only transitively through Settings.)

- [ ] **Step 3: Resolve and verify build**

```bash
cd Packages/Features/Settings && swift package resolve
swift build
```

Expected: Yams resolves to 5.3.x; Settings builds clean.

- [ ] **Step 4: Regenerate xcodeproj**

```bash
cd ../../..  # back to repo root
xcodegen generate
```

Expected: no errors. The `Folino.xcodeproj` is gitignored — do not stage it.

- [ ] **Step 5: Commit**

```bash
git add Packages/Features/Settings/Package.swift project.yml
git commit -m "Settings: add Yams dependency for version history loader"
```

---

## Task 4: `VersionHistoryLoader` (Settings)

**Files:**
- Create: `Packages/Features/Settings/Sources/Settings/VersionHistory/VersionHistoryLoader.swift`
- Test: `Packages/Features/Settings/Tests/SettingsTests/VersionHistory/DefaultVersionHistoryLoaderTests.swift`

- [ ] **Step 1: Write failing tests**

`Packages/Features/Settings/Tests/SettingsTests/VersionHistory/DefaultVersionHistoryLoaderTests.swift`:

```swift
import Domain
import Foundation
import Testing
@testable import Settings

@Suite struct DefaultVersionHistoryLoaderTests {
    private func writeYAML(_ contents: String, name: String = "VersionHistory") throws -> Bundle {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("\(name).yml")
        try contents.write(to: file, atomically: true, encoding: .utf8)
        return Bundle(url: dir)!
    }

    @Test func loadsValidYAML() throws {
        let yaml = """
        - version: 1.1.0
          descriptions:
            - en: Added MIDI import
              ja: MIDI取り込みを追加
        - version: 1.0.0
          descriptions: []
        """
        let bundle = try writeYAML(yaml)
        let loader = DefaultVersionHistoryLoader(bundle: bundle)
        let entries = try loader.load()
        #expect(entries.count == 2)
        #expect(entries[0].version == AppVersion(1, 1, 0))
        #expect(entries[1].version == AppVersion(1, 0, 0))
        #expect(entries[1].descriptions.isEmpty)
    }

    @Test func throwsWhenResourceMissing() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let bundle = Bundle(url: dir)!
        let loader = DefaultVersionHistoryLoader(bundle: bundle)
        #expect(throws: (any Error).self) { _ = try loader.load() }
    }

    @Test func throwsWhenYAMLUnparseable() throws {
        let bundle = try writeYAML(":\n  this is\n: not yaml: at all: ::")
        let loader = DefaultVersionHistoryLoader(bundle: bundle)
        #expect(throws: (any Error).self) { _ = try loader.load() }
    }

    @Test func skipsMalformedEntriesAndKeepsValidOnes() throws {
        let yaml = """
        - version: 1.1.0
          descriptions:
            - en: Good
              ja: 良
        - version: not-a-version
          descriptions: []
        - version: 1.0.0
          descriptions: []
        """
        let bundle = try writeYAML(yaml)
        let loader = DefaultVersionHistoryLoader(bundle: bundle)
        let entries = try loader.load()
        #expect(entries.map(\.version) == [AppVersion(1, 1, 0), AppVersion(1, 0, 0)])
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd Packages/Features/Settings && swift test --filter DefaultVersionHistoryLoaderTests`
Expected: FAIL with "cannot find 'DefaultVersionHistoryLoader' in scope".

- [ ] **Step 3: Write minimal implementation**

`Packages/Features/Settings/Sources/Settings/VersionHistory/VersionHistoryLoader.swift`:

```swift
import Domain
import Foundation
import Yams

public protocol VersionHistoryLoader: Sendable {
    func load() throws -> [VersionHistoryEntry]
}

public struct DefaultVersionHistoryLoader: VersionHistoryLoader {
    public enum LoadError: Error {
        case resourceNotFound(name: String)
        case unparseableRoot
    }

    private let bundle: Bundle
    private let resourceName: String

    public init(bundle: Bundle = .main, resourceName: String = "VersionHistory") {
        self.bundle = bundle
        self.resourceName = resourceName
    }

    public func load() throws -> [VersionHistoryEntry] {
        guard let url = bundle.url(forResource: resourceName, withExtension: "yml") else {
            throw LoadError.resourceNotFound(name: resourceName)
        }
        let yaml = try String(contentsOf: url, encoding: .utf8)
        // Parse to the YAML node tree first so we can iterate the top-level
        // sequence and decode each child independently. This way a single
        // malformed entry is skipped instead of failing the whole load.
        guard let root = try Yams.compose(yaml: yaml) else {
            throw LoadError.unparseableRoot
        }
        guard case let .sequence(sequence, _, _) = root else {
            throw LoadError.unparseableRoot
        }
        let decoder = YAMLDecoder()
        return sequence.compactMap { node in
            guard let yamlForEntry = try? Yams.serialize(node: node) else { return nil }
            return try? decoder.decode(VersionHistoryEntry.self, from: yamlForEntry)
        }
    }
}
```

**Why this shape:** Yams' top-level `YAMLDecoder.decode` is all-or-nothing — one bad sub-entry aborts the whole decode. Parsing first with `Yams.compose` gives us the node tree; we then re-serialize each child and run a typed decode, swallowing per-entry failures with `try?`. The Locale defaults to `Locale.current` because we don't inject `userInfo` here (matching production behavior).

If the Yams `Node.sequence` enum signature differs in 5.3.x (the associated values changed in earlier versions), adapt the `case let .sequence(...)` pattern to match — the goal is "iterate the top-level sequence's children." Don't fall back to the JSON-roundtrip approach; keep this Yams-native.

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd Packages/Features/Settings && swift test --filter DefaultVersionHistoryLoaderTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Packages/Features/Settings/Sources/Settings/VersionHistory/VersionHistoryLoader.swift \
        Packages/Features/Settings/Tests/SettingsTests/VersionHistory/DefaultVersionHistoryLoaderTests.swift
git commit -m "Settings: add VersionHistoryLoader backed by Yams"
```

---

## Task 5: `VersionHistoryViewModel` (Settings)

**Files:**
- Create: `Packages/Features/Settings/Sources/Settings/VersionHistory/VersionHistoryViewModel.swift`
- Test: `Packages/Features/Settings/Tests/SettingsTests/VersionHistory/VersionHistoryViewModelTests.swift`

- [ ] **Step 1: Write failing tests**

`Packages/Features/Settings/Tests/SettingsTests/VersionHistory/VersionHistoryViewModelTests.swift`:

```swift
import Domain
import Testing
@testable import Settings

@MainActor
@Suite struct VersionHistoryViewModelTests {
    private func entries(_ versions: [(Int, Int, Int)]) -> [VersionHistoryEntry] {
        versions.map { VersionHistoryEntry(version: AppVersion($0.0, $0.1, $0.2), descriptions: []) }
    }

    @Test func zeroBaselinePutsEverythingInRecent() {
        let all = entries([(1, 5, 0), (1, 2, 0), (1, 0, 0)])
        let vm = VersionHistoryViewModel(entries: all, baseline: .zero, isHistorySplit: false)
        #expect(vm.recentChanges.map(\.version) == all.map(\.version))
        #expect(vm.pastChanges.isEmpty)
        #expect(vm.isHistorySplit == false)
        #expect(vm.isPastChangesShown == false)
    }

    @Test func nonZeroBaselineSplitsAtBaseline() {
        let all = entries([(1, 5, 0), (1, 3, 0), (1, 2, 0), (1, 0, 0)])
        let vm = VersionHistoryViewModel(
            entries: all, baseline: AppVersion(1, 2, 0), isHistorySplit: true
        )
        #expect(vm.recentChanges.map(\.version) == [AppVersion(1, 5, 0), AppVersion(1, 3, 0)])
        #expect(vm.pastChanges.map(\.version) == [AppVersion(1, 2, 0), AppVersion(1, 0, 0)])
    }

    @Test func showMoreButtonTapFlipsFlag() {
        let vm = VersionHistoryViewModel(entries: [], baseline: .zero, isHistorySplit: true)
        #expect(vm.isPastChangesShown == false)
        vm.showMoreButtonDidTap()
        #expect(vm.isPastChangesShown == true)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd Packages/Features/Settings && swift test --filter VersionHistoryViewModelTests`
Expected: FAIL.

- [ ] **Step 3: Write minimal implementation**

`Packages/Features/Settings/Sources/Settings/VersionHistory/VersionHistoryViewModel.swift`:

```swift
import Domain
import Observation

@Observable
@MainActor
public final class VersionHistoryViewModel {
    public let isHistorySplit: Bool
    public let recentChanges: [VersionHistoryEntry]
    public let pastChanges: [VersionHistoryEntry]
    public var isPastChangesShown: Bool = false

    public init(entries: [VersionHistoryEntry], baseline: AppVersion, isHistorySplit: Bool) {
        self.isHistorySplit = isHistorySplit
        self.recentChanges = entries.filter { $0.version > baseline }
        self.pastChanges = entries.filter { $0.version <= baseline }
    }

    public func showMoreButtonDidTap() {
        isPastChangesShown = true
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd Packages/Features/Settings && swift test --filter VersionHistoryViewModelTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Packages/Features/Settings/Sources/Settings/VersionHistory/VersionHistoryViewModel.swift \
        Packages/Features/Settings/Tests/SettingsTests/VersionHistory/VersionHistoryViewModelTests.swift
git commit -m "Settings: add VersionHistoryViewModel"
```

---

## Task 6: Add localization keys to Settings xcstrings

**Files:**
- Modify: `Packages/Features/Settings/Sources/Settings/Resources/Localizable.xcstrings`

- [ ] **Step 1: Add five keys**

Open `Packages/Features/Settings/Sources/Settings/Resources/Localizable.xcstrings`. Add the following entries to the top-level `strings` object (other entries already exist — leave them untouched):

```json
"settings.versionHistory.title": {
  "extractionState": "manual",
  "localizations": {
    "en": { "stringUnit": { "state": "translated", "value": "Version History" } },
    "ja": { "stringUnit": { "state": "translated", "value": "アップデート履歴" } }
  }
},
"settings.versionHistory.recentUpdates": {
  "extractionState": "manual",
  "localizations": {
    "en": { "stringUnit": { "state": "translated", "value": "Recent updates" } },
    "ja": { "stringUnit": { "state": "translated", "value": "最近の更新" } }
  }
},
"settings.versionHistory.pastChanges": {
  "extractionState": "manual",
  "localizations": {
    "en": { "stringUnit": { "state": "translated", "value": "Past changes" } },
    "ja": { "stringUnit": { "state": "translated", "value": "過去の更新" } }
  }
},
"settings.versionHistory.showMore": {
  "extractionState": "manual",
  "localizations": {
    "en": { "stringUnit": { "state": "translated", "value": "See more" } },
    "ja": { "stringUnit": { "state": "translated", "value": "もっと見る" } }
  }
},
"settings.versionHistory.empty": {
  "extractionState": "manual",
  "localizations": {
    "en": { "stringUnit": { "state": "translated", "value": "Version history is unavailable." } },
    "ja": { "stringUnit": { "state": "translated", "value": "アップデート履歴を読み込めませんでした。" } }
  }
}
```

Keep JSON sorted lexically (the file is normally sorted, and the linter complains otherwise).

- [ ] **Step 2: Verify file still parses**

```bash
python3 -c "import json; json.load(open('Packages/Features/Settings/Sources/Settings/Resources/Localizable.xcstrings'))"
```

Expected: no output (file parsed cleanly).

- [ ] **Step 3: Commit**

```bash
git add Packages/Features/Settings/Sources/Settings/Resources/Localizable.xcstrings
git commit -m "Settings: add version-history localization keys (en + ja)"
```

---

## Task 7: `VersionHistoryScreen` (Settings)

**Files:**
- Create: `Packages/Features/Settings/Sources/Settings/VersionHistory/VersionHistoryScreen.swift`

This task is preview-driven, not test-driven (per CLAUDE.md: "Verifying UI changes — preview first").

- [ ] **Step 1: Write the screen**

`Packages/Features/Settings/Sources/Settings/VersionHistory/VersionHistoryScreen.swift`:

```swift
import Domain
import SwiftUI

public struct VersionHistoryScreen: View {
    @Bindable private var viewModel: VersionHistoryViewModel
    private let onAppear: @MainActor () -> Void

    public init(viewModel: VersionHistoryViewModel, onAppear: @escaping @MainActor () -> Void = {}) {
        self.viewModel = viewModel
        self.onAppear = onAppear
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if viewModel.isHistorySplit {
                    splitBody
                } else {
                    entriesList(viewModel.recentChanges + viewModel.pastChanges)
                }
            }
            .padding()
        }
        .onAppear { onAppear() }
    }

    @ViewBuilder
    private var splitBody: some View {
        if !viewModel.recentChanges.isEmpty {
            sectionHeader("settings.versionHistory.recentUpdates")
            entriesList(viewModel.recentChanges)
        }
        if !viewModel.pastChanges.isEmpty {
            Divider()
            if viewModel.isPastChangesShown {
                sectionHeader("settings.versionHistory.pastChanges")
                entriesList(viewModel.pastChanges)
            } else {
                Button {
                    viewModel.showMoreButtonDidTap()
                } label: {
                    Text("settings.versionHistory.showMore", bundle: .module)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private func sectionHeader(_ key: LocalizedStringKey) -> some View {
        Text(key, bundle: .module)
            .font(.title3.bold())
    }

    @ViewBuilder
    private func entriesList(_ entries: [VersionHistoryEntry]) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(entries) { entry in
                entryRow(entry)
            }
        }
    }

    @ViewBuilder
    private func entryRow(_ entry: VersionHistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(entry.version.description)
                .font(.headline)
            ForEach(Array(entry.descriptions.enumerated()), id: \.offset) { _, line in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("•")
                    Text(line)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(rowBackground(for: entry.version), in: RoundedRectangle(cornerRadius: 10))
    }

    @Environment(\.colorScheme) private var colorScheme

    private func rowBackground(for version: AppVersion) -> Color {
        let isMajorRelease = version.minor == 0 && version.patch == 0
        guard isMajorRelease else { return Color(.secondarySystemBackground) }
        return colorScheme == .dark
            ? Color.yellow.opacity(0.18)
            : Color.blue.opacity(0.12)
    }
}

#Preview("Settings push (flat)") {
    let entries = [
        VersionHistoryEntry(version: AppVersion(1, 1, 1),
                            descriptions: ["Fixed an import error", "Improved playback"]),
        VersionHistoryEntry(version: AppVersion(1, 1, 0),
                            descriptions: ["Added MIDI import", "Improved score recognition"]),
        VersionHistoryEntry(version: AppVersion(1, 0, 0), descriptions: []),
    ]
    return VersionHistoryScreen(
        viewModel: VersionHistoryViewModel(entries: entries, baseline: .zero, isHistorySplit: false)
    )
}

#Preview("Auto-sheet (split, collapsed)") {
    let entries = [
        VersionHistoryEntry(version: AppVersion(1, 1, 1),
                            descriptions: ["Fixed an import error", "Improved playback"]),
        VersionHistoryEntry(version: AppVersion(1, 1, 0),
                            descriptions: ["Added MIDI import"]),
        VersionHistoryEntry(version: AppVersion(1, 0, 0), descriptions: []),
    ]
    return VersionHistoryScreen(
        viewModel: VersionHistoryViewModel(
            entries: entries, baseline: AppVersion(1, 1, 0), isHistorySplit: true
        )
    )
}
```

- [ ] **Step 2: Render previews to verify**

Run via the `mcp__xcode__RenderPreview` MCP tool against both previews; `Read` the resulting PNGs. Confirm:
- Flat preview: shows all three entries top-to-bottom, 1.0.0 has the tinted (major-release) background.
- Split-collapsed preview: shows only 1.1.1 above the divider with a "See more" button below; tap once and 1.1.0 + 1.0.0 appear.

If a preview fails to render, debug the cause and stay on the preview path.

- [ ] **Step 3: Commit**

```bash
git add Packages/Features/Settings/Sources/Settings/VersionHistory/VersionHistoryScreen.swift
git commit -m "Settings: add VersionHistoryScreen with split / flat rendering"
```

---

## Task 8: Integrate version history into `SettingsSheet`

**Files:**
- Modify: `Packages/Features/Settings/Sources/Settings/Screens/SettingsSheet.swift`

- [ ] **Step 1: Extend the initializer**

In `SettingsSheet.swift`, add two stored properties and extend `init`:

```swift
    private let versionHistoryLoader: any VersionHistoryLoader
    private let onVersionHistoryViewed: @MainActor () -> Void

    public init(
        soundfontResolver: (any SoundfontResolver)? = nil,
        presetCatalog: (any SoundfontPresetCatalog)? = nil,
        versionHistoryLoader: any VersionHistoryLoader = DefaultVersionHistoryLoader(),
        onVersionHistoryViewed: @escaping @MainActor () -> Void = {},
        @ViewBuilder licenseContent: @escaping () -> LicenseContent
    ) {
        self.soundfontResolver = soundfontResolver
        self.presetCatalog = presetCatalog
        self.versionHistoryLoader = versionHistoryLoader
        self.onVersionHistoryViewed = onVersionHistoryViewed
        self.licenseContent = licenseContent
    }
```

- [ ] **Step 2: Insert NavigationLink in aboutSection**

In `aboutSection`, **above** the existing Licenses NavigationLink, insert:

```swift
            NavigationLink {
                versionHistoryDestination
            } label: {
                Label {
                    Text("settings.versionHistory.title", bundle: .module)
                } icon: {
                    Image(systemName: "clock.arrow.circlepath")
                }
            }
```

- [ ] **Step 3: Add the destination helper**

Below `aboutSection`, add:

```swift
    @ViewBuilder
    private var versionHistoryDestination: some View {
        if let entries = try? versionHistoryLoader.load() {
            VersionHistoryScreen(
                viewModel: VersionHistoryViewModel(
                    entries: entries,
                    baseline: .zero,
                    isHistorySplit: false
                ),
                onAppear: onVersionHistoryViewed
            )
            .navigationTitle(Text("settings.versionHistory.title", bundle: .module))
            .navigationBarTitleDisplayMode(.inline)
        } else {
            ContentUnavailableView {
                Label {
                    Text("settings.versionHistory.empty", bundle: .module)
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                }
            }
            .navigationTitle(Text("settings.versionHistory.title", bundle: .module))
            .navigationBarTitleDisplayMode(.inline)
        }
    }
```

(Note: `onAppear` is **not** invoked in the error branch — the user did not see the actual list, so we do not bump `lastOpenedVersionHistory`.)

- [ ] **Step 4: Build Settings package**

```bash
cd Packages/Features/Settings && swift build
```

Expected: clean build.

- [ ] **Step 5: Commit**

```bash
git add Packages/Features/Settings/Sources/Settings/Screens/SettingsSheet.swift
git commit -m "Settings: surface version history from the about section"
```

---

## Task 9: Add `FolinoTests` xctest target to project

**Files:**
- Modify: `project.yml`
- Create: `Tests/FolinoTests/` directory (with a placeholder smoke test so xcodegen has something to wire)

App-layer code (`ReviewPromptCoordinator`, soon `VersionHistoryPresenter`) currently has no test home — the App target is the only entry in `project.yml`. We need a place to write unit tests against App-layer types without leaking them into a feature package.

- [ ] **Step 1: Add target to project.yml**

After the `Folino:` target block, add:

```yaml
  FolinoTests:
    type: bundle.unit-test
    platform: iOS
    sources:
      - path: Tests/FolinoTests
    dependencies:
      - target: Folino
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.KeyNumber.Folino.tests
        GENERATE_INFOPLIST_FILE: YES
        BUNDLE_LOADER: $(TEST_HOST)
        TEST_HOST: $(BUILT_PRODUCTS_DIR)/folino.app/folino
```

- [ ] **Step 2: Create placeholder test**

Create `Tests/FolinoTests/FolinoSmokeTests.swift`:

```swift
import Testing
@testable import folino

@Suite struct FolinoSmokeTests {
    @Test func appTargetLinks() {
        // Compile-time check: if this file builds, the test target is wired
        // against the app target correctly.
        #expect(Bool(true))
    }
}
```

(`@testable import folino` works because XcodeGen derives the module name from `PRODUCT_NAME` which is set to `folino` in `project.yml`.)

- [ ] **Step 3: Regenerate xcodeproj and run**

```bash
xcodegen generate
xcodebuild -project Folino.xcodeproj -scheme Folino \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -skipPackagePluginValidation test
```

Expected: full build + test passes with the smoke test green.

If `@testable import folino` fails (module name mismatch), check the actual product name in build settings and use that name. Update the placeholder test accordingly.

- [ ] **Step 4: Commit**

```bash
git add project.yml Tests/FolinoTests/FolinoSmokeTests.swift
git commit -m "App: add FolinoTests xctest target for App-layer unit tests"
```

---

## Task 10: Add `suppressDisplay:` to `ReviewPromptCoordinator`

**Files:**
- Modify: `App/ReviewPromptCoordinator.swift`
- Create: `Tests/FolinoTests/ReviewPromptCoordinatorTests.swift`

- [ ] **Step 1: Write failing tests**

`Tests/FolinoTests/ReviewPromptCoordinatorTests.swift`:

```swift
import Foundation
import Testing
@testable import folino

@MainActor
@Suite struct ReviewPromptCoordinatorTests {
    private func makeDefaults() -> UserDefaults {
        let suite = UserDefaults(suiteName: "test.review.\(UUID().uuidString)")!
        suite.removePersistentDomain(forName: suite.dictionaryRepresentation().first?.key ?? "")
        return suite
    }

    @Test func suppressDisplayStillIncrementsCounter() {
        let defaults = makeDefaults()
        // Seed counter so that count == 10 (first threshold) after increment.
        defaults.set(9, forKey: "ReviewPrompt.coldLaunchCount")
        let coordinator = ReviewPromptCoordinator(defaults: defaults)
        coordinator.registerColdLaunchIfNeeded(suppressDisplay: true)
        #expect(defaults.integer(forKey: "ReviewPrompt.coldLaunchCount") == 10)
        #expect(coordinator.isPrePromptPresented == false)
    }

    @Test func suppressDisplayFalsePresentsAtThreshold() {
        let defaults = makeDefaults()
        defaults.set(9, forKey: "ReviewPrompt.coldLaunchCount")
        let coordinator = ReviewPromptCoordinator(defaults: defaults)
        coordinator.registerColdLaunchIfNeeded(suppressDisplay: false)
        #expect(defaults.integer(forKey: "ReviewPrompt.coldLaunchCount") == 10)
        #expect(coordinator.isPrePromptPresented == true)
    }

    @Test func defaultArgMatchesExistingCallSites() {
        let defaults = makeDefaults()
        defaults.set(9, forKey: "ReviewPrompt.coldLaunchCount")
        let coordinator = ReviewPromptCoordinator(defaults: defaults)
        coordinator.registerColdLaunchIfNeeded()
        #expect(coordinator.isPrePromptPresented == true)
    }

    @Test func idempotentAcrossMultipleCalls() {
        let defaults = makeDefaults()
        defaults.set(9, forKey: "ReviewPrompt.coldLaunchCount")
        let coordinator = ReviewPromptCoordinator(defaults: defaults)
        coordinator.registerColdLaunchIfNeeded(suppressDisplay: true)
        coordinator.registerColdLaunchIfNeeded(suppressDisplay: false)
        // Second call is a no-op because hasRegistered.
        #expect(defaults.integer(forKey: "ReviewPrompt.coldLaunchCount") == 10)
        #expect(coordinator.isPrePromptPresented == false)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
xcodebuild -project Folino.xcodeproj -scheme Folino \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -skipPackagePluginValidation test \
  -only-testing FolinoTests/ReviewPromptCoordinatorTests
```

Expected: compile failure on `suppressDisplay:` parameter, or the suppression test fails because the alert is still presented.

- [ ] **Step 3: Update `ReviewPromptCoordinator`**

Edit `App/ReviewPromptCoordinator.swift`. Replace `registerColdLaunchIfNeeded()` with:

```swift
    /// Idempotent per-process. Safe to call from `.task` blocks that may run
    /// multiple times across iPad multi-window scenes.
    ///
    /// Pass `suppressDisplay: true` when another cold-launch sheet (e.g.
    /// version history) is taking priority for this launch. The counter still
    /// increments so the cadence keeps moving; the user just doesn't see the
    /// pre-prompt this time around.
    func registerColdLaunchIfNeeded(suppressDisplay: Bool = false) {
        guard !hasRegistered else { return }
        hasRegistered = true

        let count = defaults.integer(forKey: Self.coldLaunchCountKey) + 1
        defaults.set(count, forKey: Self.coldLaunchCountKey)
        if !suppressDisplay, shouldPrompt(at: count) {
            isPrePromptPresented = true
        }
    }
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
xcodebuild -project Folino.xcodeproj -scheme Folino \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -skipPackagePluginValidation test \
  -only-testing FolinoTests/ReviewPromptCoordinatorTests
```

Expected: 4 tests pass.

- [ ] **Step 5: Commit**

```bash
git add App/ReviewPromptCoordinator.swift Tests/FolinoTests/ReviewPromptCoordinatorTests.swift
git commit -m "App: add suppressDisplay opt-out to ReviewPromptCoordinator"
```

---

## Task 11: `VersionHistoryPresenter` (App)

**Files:**
- Create: `App/VersionHistoryPresenter.swift`
- Create: `Tests/FolinoTests/VersionHistoryPresenterTests.swift`

- [ ] **Step 1: Write failing tests**

`Tests/FolinoTests/VersionHistoryPresenterTests.swift`:

```swift
import Domain
import Foundation
import Settings
import Testing
@testable import folino

@MainActor
@Suite struct VersionHistoryPresenterTests {
    private struct FakeLoader: VersionHistoryLoader {
        let result: Result<[VersionHistoryEntry], any Error>
        func load() throws -> [VersionHistoryEntry] { try result.get() }
    }

    private struct LoaderError: Error {}

    private static let key = "app.global.lastOpenedVersionHistory"

    private func makeDefaults() -> UserDefaults {
        let name = "test.versionHistory.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    private func entries(_ versions: [AppVersion]) -> [VersionHistoryEntry] {
        versions.map { VersionHistoryEntry(version: $0, descriptions: []) }
    }

    @Test func firstInstallBumpsKeyWithoutShowingSheet() {
        let defaults = makeDefaults()
        let presenter = VersionHistoryPresenter(
            defaults: defaults,
            loader: FakeLoader(result: .success(entries([AppVersion(1, 1, 1)])))
        )
        presenter.registerColdLaunchIfNeeded()
        #expect(presenter.isSheetPresented == false)
        #expect(defaults.string(forKey: Self.key) == AppVersion.current.rawValue)
    }

    @Test func storedEqualsCurrentDoesNothing() {
        let defaults = makeDefaults()
        defaults.set(AppVersion.current.rawValue, forKey: Self.key)
        let presenter = VersionHistoryPresenter(
            defaults: defaults,
            loader: FakeLoader(result: .success(entries([AppVersion.current])))
        )
        presenter.registerColdLaunchIfNeeded()
        #expect(presenter.isSheetPresented == false)
        #expect(defaults.string(forKey: Self.key) == AppVersion.current.rawValue)
    }

    @Test func storedNewerThanCurrentDoesNothing() {
        let defaults = makeDefaults()
        let future = AppVersion(
            AppVersion.current.major + 5, AppVersion.current.minor, AppVersion.current.patch
        )
        defaults.set(future.rawValue, forKey: Self.key)
        let presenter = VersionHistoryPresenter(
            defaults: defaults,
            loader: FakeLoader(result: .success([]))
        )
        presenter.registerColdLaunchIfNeeded()
        #expect(presenter.isSheetPresented == false)
        #expect(defaults.string(forKey: Self.key) == future.rawValue)
    }

    @Test func loaderThrowsLeavesKeyUntouched() {
        let defaults = makeDefaults()
        defaults.set("0.0.1", forKey: Self.key)
        let presenter = VersionHistoryPresenter(
            defaults: defaults,
            loader: FakeLoader(result: .failure(LoaderError()))
        )
        presenter.registerColdLaunchIfNeeded()
        #expect(presenter.isSheetPresented == false)
        #expect(defaults.string(forKey: Self.key) == "0.0.1")
    }

    @Test func loaderReturnsNoNewerEntriesBumpsKeySilently() {
        let defaults = makeDefaults()
        defaults.set("0.0.1", forKey: Self.key)
        // All entries are <= 0.0.1, so nothing new to show.
        let presenter = VersionHistoryPresenter(
            defaults: defaults,
            loader: FakeLoader(result: .success(entries([AppVersion(0, 0, 1)])))
        )
        presenter.registerColdLaunchIfNeeded()
        #expect(presenter.isSheetPresented == false)
        #expect(defaults.string(forKey: Self.key) == AppVersion.current.rawValue)
    }

    @Test func loaderReturnsNewerEntriesShowsSheetWithoutBumpingKey() {
        let defaults = makeDefaults()
        defaults.set("0.0.1", forKey: Self.key)
        let allEntries = entries([AppVersion.current, AppVersion(0, 0, 1)])
        let presenter = VersionHistoryPresenter(
            defaults: defaults,
            loader: FakeLoader(result: .success(allEntries))
        )
        presenter.registerColdLaunchIfNeeded()
        #expect(presenter.isSheetPresented == true)
        #expect(presenter.sheetViewModel != nil)
        #expect(presenter.sheetViewModel?.recentChanges.map(\.version) == [AppVersion.current])
        // Key is not bumped here — the view's onAppear calls markCurrentVersionAsSeen().
        #expect(defaults.string(forKey: Self.key) == "0.0.1")
    }

    @Test func isIdempotentAcrossMultipleCalls() {
        let defaults = makeDefaults()
        defaults.set("0.0.1", forKey: Self.key)
        let presenter = VersionHistoryPresenter(
            defaults: defaults,
            loader: FakeLoader(result: .success(entries([AppVersion.current])))
        )
        presenter.registerColdLaunchIfNeeded()
        let firstSheetState = presenter.isSheetPresented
        presenter.isSheetPresented = false  // simulate user dismissing
        presenter.registerColdLaunchIfNeeded()
        #expect(firstSheetState == true)
        #expect(presenter.isSheetPresented == false)  // second call did nothing
    }

    @Test func markCurrentVersionAsSeenWritesKey() {
        let defaults = makeDefaults()
        let presenter = VersionHistoryPresenter(
            defaults: defaults,
            loader: FakeLoader(result: .success([]))
        )
        presenter.markCurrentVersionAsSeen()
        #expect(defaults.string(forKey: Self.key) == AppVersion.current.rawValue)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
xcodebuild -project Folino.xcodeproj -scheme Folino \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -skipPackagePluginValidation test \
  -only-testing FolinoTests/VersionHistoryPresenterTests
```

Expected: compile failure ("cannot find 'VersionHistoryPresenter' in scope").

- [ ] **Step 3: Write minimal implementation**

`App/VersionHistoryPresenter.swift`:

```swift
import Domain
import Foundation
import Observation
import OSLog
import Settings

@MainActor
@Observable
final class VersionHistoryPresenter {
    private enum DefaultsKey {
        static let lastOpenedVersionHistory = "app.global.lastOpenedVersionHistory"
    }

    private static let logger = Logger(
        subsystem: "com.KeyNumber.Folino", category: "VersionHistory"
    )

    private let defaults: UserDefaults
    private let loader: any VersionHistoryLoader
    private var hasRegistered = false

    var isSheetPresented = false
    var sheetViewModel: VersionHistoryViewModel?

    init(
        defaults: UserDefaults = .standard,
        loader: any VersionHistoryLoader = DefaultVersionHistoryLoader()
    ) {
        self.defaults = defaults
        self.loader = loader
    }

    /// Idempotent per-process. Safe to call from `.task` blocks that may run
    /// multiple times across iPad multi-window scenes.
    func registerColdLaunchIfNeeded() {
        guard !hasRegistered else { return }
        hasRegistered = true
        decideAndPresent()
    }

    func markCurrentVersionAsSeen() {
        defaults.set(AppVersion.current.rawValue, forKey: DefaultsKey.lastOpenedVersionHistory)
    }

    private func decideAndPresent() {
        let stored = defaults.string(forKey: DefaultsKey.lastOpenedVersionHistory)
            .flatMap(AppVersion.init(rawValue:)) ?? .zero
        let current = AppVersion.current

        if stored == .zero {
            // First install (or stored value was unparseable): silent bump,
            // no sheet — we have no history to show this user.
            markCurrentVersionAsSeen()
            return
        }
        if stored >= current { return }  // up-to-date or downgrade

        let entries: [VersionHistoryEntry]
        do {
            entries = try loader.load()
        } catch {
            Self.logger.error("version history failed to load: \(error.localizedDescription)")
            return  // silent retry next cold launch
        }

        let recent = entries.filter { $0.version > stored }
        guard !recent.isEmpty else {
            // YAML is missing entries for the user's range — pretend we showed
            // them and stop nagging.
            markCurrentVersionAsSeen()
            return
        }

        sheetViewModel = VersionHistoryViewModel(
            entries: entries, baseline: stored, isHistorySplit: true
        )
        isSheetPresented = true
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
xcodebuild -project Folino.xcodeproj -scheme Folino \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -skipPackagePluginValidation test \
  -only-testing FolinoTests/VersionHistoryPresenterTests
```

Expected: 8 tests pass.

- [ ] **Step 5: Commit**

```bash
git add App/VersionHistoryPresenter.swift Tests/FolinoTests/VersionHistoryPresenterTests.swift
git commit -m "App: add VersionHistoryPresenter for cold-launch decision"
```

---

## Task 12: Wire `FolinoApp` + `AppShellView`

**Files:**
- Modify: `App/FolinoApp.swift`
- Modify: `App/AppShellView.swift`

- [ ] **Step 1: Update `FolinoApp.swift`**

Replace the contents of `App/FolinoApp.swift` with:

```swift
import SwiftUI

@main
struct FolinoApp: App {
    @State private var bootstrap = AppBootstrap()
    @State private var reviewPrompt = ReviewPromptCoordinator()
    @State private var versionHistoryPresenter = VersionHistoryPresenter()

    init() {
        EdwinFontLoader.registerOnce()
    }

    var body: some Scene {
        WindowGroup {
            AppShellView(
                bootstrap: bootstrap,
                reviewPrompt: reviewPrompt,
                versionHistoryPresenter: versionHistoryPresenter
            )
            .task {
                bootstrap.start()
                versionHistoryPresenter.registerColdLaunchIfNeeded()
                reviewPrompt.registerColdLaunchIfNeeded(
                    suppressDisplay: versionHistoryPresenter.isSheetPresented
                )
            }
            .onOpenURL { bootstrap.acceptIncomingURL($0) }
        }
    }
}
```

- [ ] **Step 2: Update `AppShellView.swift` — add property + init param**

In `AppShellView`, add a property and pass it down:

```swift
struct AppShellView: View {
    let bootstrap: AppBootstrap
    @Bindable var reviewPrompt: ReviewPromptCoordinator
    @Bindable var versionHistoryPresenter: VersionHistoryPresenter
    @Environment(\.requestReview) private var requestReview
```

(SwiftUI generates the memberwise init automatically since it's a struct with all stored properties accessible.)

- [ ] **Step 3: Update the existing SettingsSheet call site**

In `ReadyShell.body`, replace the existing `.sheet(isPresented: $isSettingsPresented)` block. The presenter needs to be reachable from inside ReadyShell — add a property to ReadyShell:

```swift
private struct ReadyShell: View {
    let bootstrap: AppBootstrap
    let versionHistoryPresenter: VersionHistoryPresenter
    // ... existing fields
```

Also extend ReadyShell's `init` to accept and store it:

```swift
    init(
        bootstrap: AppBootstrap,
        versionHistoryPresenter: VersionHistoryPresenter,
        repository: any ScoreLibraryRepository,
        // ... rest as before
    ) {
        self.bootstrap = bootstrap
        self.versionHistoryPresenter = versionHistoryPresenter
        // ... rest as before
    }
```

And update the call site in `AppShellView.body`:

```swift
                ReadyShell(
                    bootstrap: bootstrap,
                    versionHistoryPresenter: versionHistoryPresenter,
                    repository: repository,
                    importer: importer,
                    gateway: gateway,
                    shareService: shareService,
                    scoresDirectory: AppPaths.scoresDirectory
                )
```

Then replace the existing SettingsSheet block with:

```swift
        .sheet(isPresented: $isSettingsPresented) {
            SettingsSheet(
                soundfontResolver: bootstrap.soundfontResolver,
                presetCatalog: bootstrap.presetCatalog,
                onVersionHistoryViewed: { versionHistoryPresenter.markCurrentVersionAsSeen() }
            ) {
                LicenseListView()
            }
        }
```

- [ ] **Step 4: Add the auto-sheet binding**

At the top level of `AppShellView.body` (the outer view that hosts `Group { ... }.alert { ... }`), add a `.sheet` after the existing review-prompt alert. Since `versionHistoryPresenter` is `@Bindable`, the binding works directly:

```swift
        .sheet(isPresented: $versionHistoryPresenter.isSheetPresented) {
            if let vm = versionHistoryPresenter.sheetViewModel {
                NavigationStack {
                    VersionHistoryScreen(
                        viewModel: vm,
                        onAppear: { versionHistoryPresenter.markCurrentVersionAsSeen() }
                    )
                    .navigationTitle(Text("settings.versionHistory.title", bundle: .module))
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button {
                                versionHistoryPresenter.isSheetPresented = false
                            } label: {
                                L10n.Common.done
                            }
                        }
                    }
                }
            }
        }
```

Both `VersionHistoryScreen` and `L10n.Common.done` come from the `Settings` and `UtilityUI` modules — both already imported via the existing imports. **Confirm** `Settings` is imported at the top of `AppShellView.swift` (it already is, per the existing `import Settings` line). The `.module` bundle resolution refers to the *call site*'s module — since `AppShellView` is in the App target, `.module` here is the App's resource bundle, **not** Settings'. The Settings keys live in Settings' bundle. **Fix:** use `Bundle.module` from the Settings module explicitly. Easiest: extract the title into a typed accessor inside Settings.

Add to `Packages/Features/Settings/Sources/Settings/VersionHistory/VersionHistoryScreen.swift`:

```swift
public enum VersionHistoryStrings {
    public static var title: LocalizedStringResource {
        LocalizedStringResource("settings.versionHistory.title", bundle: .atURL(Bundle.module.bundleURL))
    }
}
```

Then in `AppShellView.swift`, replace `Text("settings.versionHistory.title", bundle: .module)` with:

```swift
                    .navigationTitle(Text(VersionHistoryStrings.title))
```

- [ ] **Step 5: Build and run**

```bash
xcodebuild -project Folino.xcodeproj -scheme Folino \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -skipPackagePluginValidation build
```

Expected: clean build.

- [ ] **Step 6: Commit**

```bash
git add App/FolinoApp.swift App/AppShellView.swift \
        Packages/Features/Settings/Sources/Settings/VersionHistory/VersionHistoryScreen.swift
git commit -m "App: wire VersionHistoryPresenter into shell + Settings sheet"
```

---

## Task 13: Manual cold-launch verification

UI verification is manual per the spec — programmatic XCUITest of cold-launch state is unreliable.

- [ ] **Step 1: Build + install the app on a simulator**

```bash
xcodebuild -project Folino.xcodeproj -scheme Folino \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -skipPackagePluginValidation \
  -derivedDataPath /tmp/Folino-dd build
```

Locate the built app:

```bash
APP_PATH=$(find /tmp/Folino-dd/Build/Products -name folino.app -type d | head -1)
echo "$APP_PATH"
```

Boot a simulator and install:

```bash
xcrun simctl boot 'iPhone 16' 2>/dev/null || true
xcrun simctl install booted "$APP_PATH"
```

- [ ] **Step 2: Scenario A — first install (no key)**

```bash
xcrun simctl uninstall booted com.KeyNumber.Folino || true
xcrun simctl install booted "$APP_PATH"
xcrun simctl launch booted com.KeyNumber.Folino
```

Expected: app launches, **no** version-history sheet, no review pre-prompt. Hand to the user to confirm visually.

Verify the key was written:

```bash
xcrun simctl spawn booted defaults read com.KeyNumber.Folino app.global.lastOpenedVersionHistory
```

Expected output: `1.1.1` (the current marketing version).

- [ ] **Step 3: Scenario B — seeded older version**

```bash
xcrun simctl terminate booted com.KeyNumber.Folino || true
xcrun simctl spawn booted defaults write com.KeyNumber.Folino app.global.lastOpenedVersionHistory -string "1.1.0"
xcrun simctl launch booted com.KeyNumber.Folino
```

Expected: cold launch shows the version history sheet auto-presented, with 1.1.1 above the divider and a "See more" button (since 1.1.0 is the only past entry). Hand to user for visual confirmation. After dismissing the sheet, check the key:

```bash
xcrun simctl spawn booted defaults read com.KeyNumber.Folino app.global.lastOpenedVersionHistory
```

Expected: `1.1.1`.

- [ ] **Step 4: Scenario C — Settings entry**

From the running app (Scenario A state — already up-to-date), tap Settings → "Version History" in the About section. Confirm:
- The full list renders (all entries, no "See more").
- Entries with `minor == 0 && patch == 0` (none in current YAML, so add a temporary `1.0.0` entry if needed for visual QA) get a tinted background.
- Back-navigation works.

- [ ] **Step 5: Scenario D — collision with review prompt**

Seed both: stored version older than current AND review counter at threshold.

```bash
xcrun simctl spawn booted defaults write com.KeyNumber.Folino app.global.lastOpenedVersionHistory -string "1.0.0"
xcrun simctl spawn booted defaults write com.KeyNumber.Folino ReviewPrompt.coldLaunchCount -int 9
xcrun simctl terminate booted com.KeyNumber.Folino || true
xcrun simctl launch booted com.KeyNumber.Folino
```

Expected: version-history sheet appears, **no** review pre-prompt alert. Confirm counter still incremented:

```bash
xcrun simctl spawn booted defaults read com.KeyNumber.Folino ReviewPrompt.coldLaunchCount
```

Expected: `10`.

- [ ] **Step 6: Report results**

If any scenario behaves differently than expected, do not commit — file the discrepancy back in the loop and debug. Otherwise, manual QA is complete; nothing to commit for this task.

---

## Task 14: Run full test suite + lint pass

- [ ] **Step 1: Run all tests**

```bash
xcodebuild -project Folino.xcodeproj -scheme Folino \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -skipPackagePluginValidation test
```

Expected: all tests pass — Domain (AppVersion + VersionHistoryEntry), Settings (Loader + VM), App (FolinoTests).

- [ ] **Step 2: Confirm SwiftLint is happy**

The pre-commit hook runs SwiftFormat + `swiftlint --fix` automatically. As a manual check:

```bash
swiftlint --quiet App Packages/Domain/Sources Packages/Features/Settings/Sources
```

Expected: no violations.

- [ ] **Step 3: Confirm xcstrings has no stale or unused keys**

Spot-check that the five new `settings.versionHistory.*` keys are referenced:

```bash
grep -rn 'settings.versionHistory' Packages/Features/Settings/Sources App | wc -l
```

Expected: at least 7 references (5 in SettingsSheet/Screen, 1 in destination's ContentUnavailableView, 1 in AppShellView navigationTitle via `VersionHistoryStrings.title`).

- [ ] **Step 4: Final commit (if any uncommitted hook fixes exist)**

```bash
git status
```

If clean: done. If not (e.g., SwiftFormat re-flowed something): `git add -A && git commit -m "Style: SwiftFormat fixes"`.

---

## Notes for the implementing engineer

- **YAML resource sourcing.** The YAML at `App/Resources/VersionHistory.yml` was already committed before this plan started. It's picked up by the App target's source glob and will land in `Bundle.main`. If `DefaultVersionHistoryLoader(bundle: .main)` returns "resource not found", regenerate with `xcodegen generate` and verify the file appears in the Xcode project's resources phase for the Folino target. Don't move the YAML into a Settings resource — the spec puts it in App.

- **`@testable import folino`.** XcodeGen derives the Swift module name from `PRODUCT_NAME`. The current `project.yml` sets `PRODUCT_NAME: folino` (lowercase) — that's what `@testable import` expects. If the module ends up named differently in your build, fix the imports rather than fighting XcodeGen.

- **Don't introduce abstractions beyond the spec.** The view model takes a flat `[VersionHistoryEntry]` and a baseline; the screen renders directly from it; the presenter owns the decision logic. No `VersionHistoryService` aggregating loader+presenter, no `VersionHistoryEnvironment`, no `@EnvironmentValues` injection — pure constructor injection.

- **Avoid touching VocalTuner.** It's referenced as inspiration only; do not import from or change anything under `~/Developer/Personal/ios-apps/VocalTuner`.

- **Commit cadence.** Each task ends with a commit. The pre-commit hook may rewrite SwiftFormat / SwiftLint fixes; let it re-stage automatically (the project uses `pre-commit install`, so the second `git commit` invocation should land clean). Never use `git add -p`.
