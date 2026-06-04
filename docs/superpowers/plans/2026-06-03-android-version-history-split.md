# Split iOS / Android Version History — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Android's version history its own independent YAML source of truth, parsed by a single shared Swift Yams loader (C-Swift), so iOS and Android "What's New" content can diverge.

**Architecture:** Both platforms author `VersionHistory.yml` in the same schema. A shared `YAMLVersionHistoryLoader` in `SettingsLogic` parses YAML `Data` into `Domain.VersionHistoryEntry` (locale selection happens here, in Swift). iOS reads its bundle yml; Android passes its asset yml bytes over the existing JNI wire bridge — the wire envelope, Kotlin decode, and Compose UI are unchanged. The libyaml C dependency cross-compiles for Android (proven by a spike on this branch).

**Tech Stack:** Swift 6.3 (SwiftPM), Yams (libyaml), swift-wirelet, swift-java (jextract JNI), Kotlin/Compose, Android NDK cross-compile via the Swift 6.3.2 Android SDK.

---

## Context for the executor

- Work in the existing worktree: `/Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/version-history-split` (branch `version-history-split`). All paths below are relative to it unless absolute.
- **Spike state already on disk (uncommitted):** `Packages/Features/Settings/Package.swift` already has `Yams` added to the `SettingsLogic` target, and `Packages/Features/Settings/Sources/SettingsLogic/YAMLVersionHistoryLoader.swift` exists as a spike stub. Task 1 formalizes both. Do not be surprised they are present.
- **iOS package tests** (per project memory — `swift test` is broken by the SwiftLint plugin's macOS requirement): run via xcodebuild on an iOS Simulator. iPhone 16 sim is NOT installed; use **iPhone 17**:
  ```
  xcodebuild test -scheme Settings-Package -destination 'platform=iOS Simulator,name=iPhone 17' -skipPackagePluginValidation
  ```
  Run it from inside `Packages/Features/Settings` (so it resolves the local package). If `Settings-Package` is not found, run `xcodebuild -list` there to get the exact scheme name.
- **Android cross-compile** uses the `/Library` toolchain prepended to PATH (the swiftly shim is broken):
  ```
  PATH=/Library/Developer/Toolchains/swift-6.3.2-RELEASE.xctoolchain/usr/bin:$PATH FOLINO_ANDROID=1 swift build --package-path Packages/Features/Settings --product FolinoSettingsJNI --swift-sdk <triple> -c release
  ```
- Keep commits whole-file (no hunk staging — pre-commit rewrites files).
- Commit message trailer for every commit:
  `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`

---

## File Structure

| File | Responsibility | Action |
| --- | --- | --- |
| `Packages/Features/Settings/Package.swift` | Yams on `SettingsLogic` target | Modify (spike already did this) |
| `…/Sources/SettingsLogic/YAMLVersionHistoryLoader.swift` | Shared YAML→`[VersionHistoryEntry]` loader (throws on unparseable root) | Rewrite from spike stub |
| `…/Sources/SettingsLogic/VersionHistoryWirePayload.swift` | `versionHistoryWirePayload(ymlData:)` JNI helper | Create |
| `…/Sources/SettingsLogic/JSONVersionHistoryLoader.swift` | (old JSON loader + helper) | Delete |
| `…/Tests/SettingsLogicTests/YAMLVersionHistoryLoaderTests.swift` | Loader + wire-payload tests | Create |
| `…/Tests/SettingsLogicTests/JSONVersionHistoryLoaderTests.swift` | (old) | Delete |
| `…/Tests/SettingsLogicTests/AndroidVersionHistoryAssetTests.swift` | Gate: real Android yml asset decodes | Create |
| `…/Sources/Settings/VersionHistory/DefaultVersionHistoryLoader.swift` | iOS bundle loader → delegates to shared loader | Modify |
| `…/Sources/FolinoSettingsJNI/JNISymbols.swift` | JNI entry; param `ymlBytes` | Modify |
| `Android/FolinoSettingsAndroid/src/main/kotlin/com/keynumber/folino/settings/SettingsJNI.kt` | Kotlin façade; param `ymlBytes` | Modify |
| `Android/app/src/main/kotlin/com/keynumber/folino/MainActivity.kt` | reads `VersionHistory.yml` asset | Modify |
| `Android/app/src/main/assets/VersionHistory.yml` | Android source of truth | Create (seed from old json) |
| `Android/app/src/main/assets/VersionHistory.json` | (old) | Delete |
| `Android/FolinoSettingsAndroid/src/main/jniLibs/**` + `src/main/java-generated/**` | rebuilt `.so` + bindings | Regenerate |
| `.release.yml` | future android-release config | Modify |

---

## Task 1: Shared `YAMLVersionHistoryLoader` in SettingsLogic

**Files:**
- Modify: `Packages/Features/Settings/Package.swift` (verify Yams on `SettingsLogic` — spike applied)
- Rewrite: `Packages/Features/Settings/Sources/SettingsLogic/YAMLVersionHistoryLoader.swift`
- Create: `Packages/Features/Settings/Tests/SettingsLogicTests/YAMLVersionHistoryLoaderTests.swift`

- [ ] **Step 1: Confirm the Yams dependency is on `SettingsLogic`**

Open `Package.swift` and confirm the `SettingsLogic` target lists `.product(name: "Yams", package: "Yams")`. If absent (clean checkout), add it:

```swift
.target(
    name: "SettingsLogic",
    dependencies: [
        "Domain",
        .product(name: "Wirelet", package: "swift-wirelet"),
        .product(name: "Yams", package: "Yams"),
    ],
    plugins: swiftLintPlugins,
),
```

- [ ] **Step 2: Write the failing tests**

Create `Packages/Features/Settings/Tests/SettingsLogicTests/YAMLVersionHistoryLoaderTests.swift`:

```swift
import Domain
import Foundation
@testable import SettingsLogic
import Testing

struct YAMLVersionHistoryLoaderTests {
    private let sampleYAML =
        """
        - version: 1.5.1
          descriptions:
            - en: Bug fix
              ja: ja-a
              ko: ko-a
              zh-Hans: ha
              zh-Hant: ht
            - en: Crash fix
              ja: ja-b
        - version: 1.5.0
          descriptions:
            - en: Page view
              ja: ja-c
        """

    @Test func `loads entries from YAML`() throws {
        let entries = try YAMLVersionHistoryLoader(data: Data(sampleYAML.utf8)).load()
        #expect(entries.count == 2)
        #expect(entries[0].version == AppVersion(1, 5, 1))
        #expect(entries[1].version == AppVersion(1, 5, 0))
        #expect(entries[0].descriptions.count == 2)
        #expect(entries[1].descriptions.count == 1)
    }

    @Test func `skips malformed entries and keeps valid ones`() throws {
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
        let entries = try YAMLVersionHistoryLoader(data: Data(yaml.utf8)).load()
        #expect(entries.map(\.version) == [AppVersion(1, 1, 0), AppVersion(1, 0, 0)])
    }

    @Test func `throws when root is not a sequence`() {
        let yaml = "version: 1.0.0\ndescriptions: []"
        #expect(throws: (any Error).self) {
            _ = try YAMLVersionHistoryLoader(data: Data(yaml.utf8)).load()
        }
    }
}
```

- [ ] **Step 3: Run the tests to verify they fail**

From `Packages/Features/Settings`:
```
xcodebuild test -scheme Settings-Package -destination 'platform=iOS Simulator,name=iPhone 17' -skipPackagePluginValidation -only-testing:SettingsLogicTests/YAMLVersionHistoryLoaderTests
```
Expected: FAIL — the spike stub returns `[]` on a non-sequence root (the `throws when root is not a sequence` test fails), confirming the test is meaningful.

- [ ] **Step 4: Rewrite the loader to throw on unparseable root**

Replace the contents of `Packages/Features/Settings/Sources/SettingsLogic/YAMLVersionHistoryLoader.swift`:

```swift
import Domain
import Foundation
import Yams

/// Shared `VersionHistoryLoader` that parses YAML `Data` into `[VersionHistoryEntry]`. Used by both the iOS
/// bundle loader and the Android JNI bridge, so the schema and locale-selection logic stay single-sourced in
/// `Domain.VersionHistoryEntry`.
///
/// Parses the YAML node tree first and re-decodes each top-level element independently, so a single malformed
/// entry is skipped rather than poisoning the whole load. Throws when the document root is missing or is not a
/// sequence; callers that need resilience (the JNI helper) wrap the call in `try?`.
public struct YAMLVersionHistoryLoader: VersionHistoryLoader {
    public enum LoadError: Error {
        case unparseableRoot
    }

    private let data: Data
    public init(data: Data) {
        self.data = data
    }

    public func load() throws -> [VersionHistoryEntry] {
        let yaml = String(decoding: data, as: UTF8.self)
        guard let root = try Yams.compose(yaml: yaml) else {
            throw LoadError.unparseableRoot
        }
        guard case let .sequence(sequence) = root else {
            throw LoadError.unparseableRoot
        }
        let decoder = YAMLDecoder()
        return sequence.compactMap { try? decoder.decode(VersionHistoryEntry.self, from: $0) }
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Same command as Step 3. Expected: PASS (3 tests).

- [ ] **Step 6: Commit**

```bash
git add Packages/Features/Settings/Package.swift \
        Packages/Features/Settings/Sources/SettingsLogic/YAMLVersionHistoryLoader.swift \
        Packages/Features/Settings/Tests/SettingsLogicTests/YAMLVersionHistoryLoaderTests.swift
git commit -m "feat(version-history): shared YAMLVersionHistoryLoader in SettingsLogic

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: Replace JSON wire-payload helper with YAML

**Files:**
- Create: `Packages/Features/Settings/Sources/SettingsLogic/VersionHistoryWirePayload.swift`
- Delete: `Packages/Features/Settings/Sources/SettingsLogic/JSONVersionHistoryLoader.swift`
- Delete: `Packages/Features/Settings/Tests/SettingsLogicTests/JSONVersionHistoryLoaderTests.swift`
- Add the wire-payload test to `YAMLVersionHistoryLoaderTests.swift`

- [ ] **Step 1: Add a failing wire-payload test**

Append this `@Test` to `YAMLVersionHistoryLoaderTests.swift` (inside the struct):

```swift
    @Test func `wire payload round trips`() throws {
        let payload = versionHistoryWirePayload(ymlData: Data(sampleYAML.utf8))
        let list = try VersionHistoryWireList(decoding: payload)
        #expect(list.entries.count == 2)
        #expect(list.entries[0].version == "1.5.1")
        #expect(list.entries[1].version == "1.5.0")
        #expect(list.entries[0].descriptions.count == 2)
        #expect(list.entries[1].descriptions.count == 1)
    }

    @Test func `wire payload yields empty list on garbage`() throws {
        let payload = versionHistoryWirePayload(ymlData: Data("%%%not yaml".utf8))
        let list = try VersionHistoryWireList(decoding: payload)
        #expect(list.entries.isEmpty)
    }
```

- [ ] **Step 2: Create the YAML wire-payload helper**

Create `Packages/Features/Settings/Sources/SettingsLogic/VersionHistoryWirePayload.swift`:

```swift
import Domain
import Foundation

/// Encodes the version history from `ymlData` into a wirelet-format `Data` payload ready for JNI transfer.
///
/// On malformed input the function returns an empty-list payload rather than throwing, so the Kotlin side
/// always receives a valid (possibly empty) `VersionHistoryWireList`.
public func versionHistoryWirePayload(ymlData: Data) -> Data {
    let entries = (try? YAMLVersionHistoryLoader(data: ymlData).load()) ?? []
    let wire = entries.map { VersionHistoryWire(version: $0.version.description, descriptions: $0.descriptions) }
    return VersionHistoryWireList(entries: wire).encodeToData()
}
```

- [ ] **Step 3: Delete the JSON loader and its test**

```bash
git rm Packages/Features/Settings/Sources/SettingsLogic/JSONVersionHistoryLoader.swift \
       Packages/Features/Settings/Tests/SettingsLogicTests/JSONVersionHistoryLoaderTests.swift
```

(`JSONVersionHistoryLoader.swift` held both the old loader struct and the old `versionHistoryWirePayload(jsonData:)`; both are now superseded.)

- [ ] **Step 4: Run the SettingsLogic tests**

From `Packages/Features/Settings`:
```
xcodebuild test -scheme Settings-Package -destination 'platform=iOS Simulator,name=iPhone 17' -skipPackagePluginValidation -only-testing:SettingsLogicTests
```
Expected: PASS. No remaining reference to `JSONVersionHistoryLoader` or `jsonData` should cause a compile error.

- [ ] **Step 5: Commit**

```bash
git add -A Packages/Features/Settings/Sources/SettingsLogic \
          Packages/Features/Settings/Tests/SettingsLogicTests
git commit -m "feat(version-history): YAML wire payload helper; drop JSON loader

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: Refactor `DefaultVersionHistoryLoader` to delegate

**Files:**
- Modify: `Packages/Features/Settings/Sources/Settings/VersionHistory/DefaultVersionHistoryLoader.swift`
- Existing test stays: `…/Tests/SettingsTests/VersionHistory/DefaultVersionHistoryLoaderTests.swift`

- [ ] **Step 1: Rewrite the loader to read Data and delegate**

Replace the contents of `DefaultVersionHistoryLoader.swift`:

```swift
import Domain
import Foundation
import SettingsLogic

public struct DefaultVersionHistoryLoader: VersionHistoryLoader {
    public enum LoadError: Error {
        case resourceNotFound(name: String)
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
        // Parsing + locale selection live in the shared SettingsLogic loader so iOS and Android share one path.
        return try YAMLVersionHistoryLoader(data: Data(contentsOf: url)).load()
    }
}
```

Note: `Yams` import is gone here; the `unparseableRoot` case moved to `YAMLVersionHistoryLoader.LoadError`. The `Settings` target keeps Yams transitively via `SettingsLogic`.

- [ ] **Step 2: Run the Settings tests**

From `Packages/Features/Settings`:
```
xcodebuild test -scheme Settings-Package -destination 'platform=iOS Simulator,name=iPhone 17' -skipPackagePluginValidation -only-testing:SettingsTests/DefaultVersionHistoryLoaderTests
```
Expected: PASS — all four existing tests stay green. (`throws when resource missing` → `resourceNotFound`; `throws when YAML unparseable` → `YAMLVersionHistoryLoader.LoadError.unparseableRoot`; both satisfy `#expect(throws: (any Error).self)`.)

- [ ] **Step 3: Commit**

```bash
git add Packages/Features/Settings/Sources/Settings/VersionHistory/DefaultVersionHistoryLoader.swift
git commit -m "refactor(version-history): DefaultVersionHistoryLoader delegates to shared YAML loader

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: JNI entry + Kotlin façade — switch to YAML bytes

**Files:**
- Modify: `Packages/Features/Settings/Sources/FolinoSettingsJNI/JNISymbols.swift`
- Modify: `Android/FolinoSettingsAndroid/src/main/kotlin/com/keynumber/folino/settings/SettingsJNI.kt`
- Modify: `Android/FolinoSettingsAndroid/src/main/kotlin/com/keynumber/folino/settings/VersionHistory.kt`

- [ ] **Step 1: Update the Swift JNI entry**

Replace the contents of `JNISymbols.swift`:

```swift
import Foundation
import SettingsLogic

/// swift-java entry point for Kotlin `SettingsJNI.nativeLoadVersionHistory`.
/// Takes the `VersionHistory.yml` asset bytes, returns the wirelet-encoded entry list.
public func nativeLoadVersionHistory(ymlBytes: Data) -> Data {
    versionHistoryWirePayload(ymlData: ymlBytes)
}
```

- [ ] **Step 2: Update the Kotlin façade**

In `SettingsJNI.kt`, rename the parameter and fix the doc comment:

```kotlin
    /**
     * Hands the raw `VersionHistory.yml` bytes to Swift, which decodes
     * them, resolves localized descriptions, and re-encodes the result as
     * a wirelet-format `VersionHistoryWireList` payload. Returns the
     * encoded bytes (decode via [VersionHistoryWireListCodec]).
     */
    fun nativeLoadVersionHistory(ymlBytes: ByteArray): ByteArray {
        val arena = SwiftMemoryManagement.DEFAULT_SWIFT_JAVA_AUTO_ARENA
        return SwiftJavaJNI.nativeLoadVersionHistory(SwiftData.fromByteArray(ymlBytes, arena), arena).toByteArray()
    }
```

Note: the regenerated jextract binding (`FolinoSettingsJNI.java`) will reflect the `ymlBytes` parameter name after Task 6 rebuilds it. Until then the Android module will not compile — that is expected; the Kotlin app build happens in Task 6/7.

- [ ] **Step 3: Update the `VersionHistoryBridge` façade parameter**

In `VersionHistory.kt`, rename the parameter and fix the doc comment:

```kotlin
/**
 * Loads the version history by round-tripping the `VersionHistory.yml` asset
 * bytes through Swift: [SettingsJNI.nativeLoadVersionHistory] returns a
 * wirelet-encoded `VersionHistoryWireList`, which [VersionHistoryWireListCodec]
 * decodes back into Kotlin model objects.
 */
object VersionHistoryBridge {
    fun load(ymlBytes: ByteArray): List<VersionHistoryWire> =
        VersionHistoryWireListCodec.decode(SettingsJNI.nativeLoadVersionHistory(ymlBytes)).entries
}
```

- [ ] **Step 4: Commit (Swift + Kotlin source only)**

```bash
git add Packages/Features/Settings/Sources/FolinoSettingsJNI/JNISymbols.swift \
        Android/FolinoSettingsAndroid/src/main/kotlin/com/keynumber/folino/settings/SettingsJNI.kt \
        Android/FolinoSettingsAndroid/src/main/kotlin/com/keynumber/folino/settings/VersionHistory.kt
git commit -m "feat(version-history): JNI bridge accepts YAML bytes

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: Android YAML asset + MainActivity + validation gate

**Files:**
- Create: `Android/app/src/main/assets/VersionHistory.yml`
- Delete: `Android/app/src/main/assets/VersionHistory.json`
- Modify: `Android/app/src/main/kotlin/com/keynumber/folino/MainActivity.kt`
- Create: `Packages/Features/Settings/Tests/SettingsLogicTests/AndroidVersionHistoryAssetTests.swift`

- [ ] **Step 1: Create the Android YAML asset (seeded from the old JSON, 1.5.1 and earlier)**

Create `Android/app/src/main/assets/VersionHistory.yml` with the current Android content converted to the iOS schema. This is Android's independent source of truth from now on:

```yaml
- version: 1.5.1
  descriptions:
    - en: Minor bug fixes
      ja: 軽微なバグ修正
      ko: 사소한 버그 수정
      zh-Hans: 修复细微问题
      zh-Hant: 修正細微錯誤
    - en: Added crash report submission
      ja: クラッシュレポート送信機能の追加
      ko: 충돌 보고서 전송 기능 추가
      zh-Hans: 新增崩溃报告提交功能
      zh-Hant: 新增當機報告提交功能
- version: 1.5.0
  descriptions:
    - en: Added a page view mode
      ja: ページめくり表示モードを追加
      ko: 페이지 보기 모드 추가
      zh-Hans: 新增分页查看模式
      zh-Hant: 新增頁面檢視模式
    - en: Added a setting to prevent auto-lock
      ja: 自動ロックを抑止する設定を追加
      ko: 자동 잠금 방지 설정 추가
      zh-Hans: 新增防止自动锁屏的设置
      zh-Hant: 新增防止自動鎖定的設定
    - en: Improved score deletion
      ja: 楽譜の削除機能を改善
      ko: 악보 삭제 개선
      zh-Hans: 改进乐谱删除
      zh-Hant: 改善樂譜刪除
    - en: Improved file sharing from other apps
      ja: 他のアプリからのファイル共有機能を改善
      ko: 다른 앱에서의 파일 공유 개선
      zh-Hans: 改进从其他应用共享文件的体验
      zh-Hant: 改善從其他應用程式分享檔案的功能
    - en: Added support for tremolo and portamento
      ja: トレモロとポルタメントに対応
      ko: 트레몰로와 포르타멘토 지원 추가
      zh-Hans: 新增颤音与滑音支持
      zh-Hant: 新增顫音與滑音支援
- version: 1.4.0
  descriptions:
    - en: Fixed an issue where score files could not be imported on some devices
      ja: 一部の端末で楽譜ファイルを取り込めない不具合を修正
      ko: 일부 기기에서 악보 파일을 가져올 수 없던 문제 수정
      zh-Hans: 修复部分设备上无法导入乐谱文件的问题
      zh-Hant: 修正部分裝置上無法匯入樂譜檔案的問題
    - en: Added audio (.m4a) export
      ja: オーディオ (.m4a) 出力機能を追加
      ko: 오디오(.m4a) 내보내기 추가
      zh-Hans: 新增音频（.m4a）导出功能
      zh-Hant: 新增音訊（.m4a）匯出功能
- version: 1.3.1
  descriptions:
    - en: Minor bug fixes
      ja: 軽微なバグの修正
      ko: 사소한 버그 수정
      zh-Hans: 小问题修复
      zh-Hant: 修正細微錯誤
- version: 1.3.0
  descriptions:
    - en: Added support for Picture in Picture
      ja: ピクチャインピクチャ機能を追加
      ko: Picture in Picture 지원 추가
      zh-Hans: 新增画中画支持
      zh-Hant: 新增子母畫面支援
    - en: Added the ability to collapse multi-measure rests
      ja: 多小節休符をまとめる機能を追加
      ko: 다단 쉼표 접기 기능 추가
      zh-Hans: 新增折叠多小节休止符的功能
      zh-Hant: 新增摺疊多小節休止符的功能
    - en: Minor bug fixes
      ja: 軽微なバグを修正
      ko: 사소한 버그 수정
      zh-Hans: 修复细微问题
      zh-Hant: 修正細微錯誤
- version: 1.2.0
  descriptions:
    - en: Fixed a crash that occurred when deleting a score
      ja: 楽譜削除でクラッシュする不具合を修正
      ko: 악보 삭제 시 발생하던 충돌 수정
      zh-Hans: 修复删除乐谱时崩溃的问题
      zh-Hant: 修正刪除樂譜時的閃退問題
    - en: Added the ability to change clefs per staff
      ja: 譜表ごとの音部記号変更機能を追加
      ko: 보표별 음자리표 변경 기능 추가
      zh-Hans: 新增按谱表更改谱号的功能
      zh-Hant: 新增依譜表變更譜號的功能
    - en: Added the ability to rename files
      ja: ファイル名変更機能を追加
      ko: 파일 이름 변경 기능 추가
      zh-Hans: 新增重命名文件的功能
      zh-Hant: 新增重新命名檔案的功能
    - en: Improved scroll and zoom controls for scores
      ja: 楽譜のスクロール・ズームの操作性を改善
      ko: 악보 스크롤과 확대/축소 조작 개선
      zh-Hans: 改进乐谱滚动与缩放的操作
      zh-Hant: 改善樂譜捲動與縮放的操作
- version: 1.1.1
  descriptions:
    - en: Fixed an import error that occurred with some files
      ja: 一部のファイルで発生する取り込みエラーを修正
      ko: 일부 파일에서 발생하던 가져오기 오류 수정
      zh-Hans: 修复部分文件导入时发生的错误
      zh-Hant: 修正部分檔案匯入時發生的錯誤
    - en: Improved score display and playback
      ja: 楽譜の表示・再生を改善
      ko: 악보 표시와 재생 개선
      zh-Hans: 改进乐谱显示与播放
      zh-Hant: 改善樂譜顯示與播放
- version: 1.1.0
  descriptions:
    - en: Added support for importing MIDI files
      ja: MIDIファイルの取り込みに対応
      ko: MIDI 파일 가져오기 지원 추가
      zh-Hans: 新增 MIDI 文件导入支持
      zh-Hant: 新增 MIDI 檔案匯入支援
    - en: Improved score recognition accuracy
      ja: 楽譜読み込み精度の向上
      ko: 악보 인식 정확도 향상
      zh-Hans: 提升乐谱识别精度
      zh-Hant: 提升樂譜辨識精度
    - en: Overall UI/UX refinements
      ja: 全体的なUI/UXの改善
      ko: 전반적인 UI/UX 개선
      zh-Hans: 整体 UI/UX 优化
      zh-Hant: 整體 UI/UX 改善
```

- [ ] **Step 2: Delete the old JSON asset**

```bash
git rm Android/app/src/main/assets/VersionHistory.json
```

- [ ] **Step 3: Point MainActivity at the YAML asset**

In `Android/app/src/main/kotlin/com/keynumber/folino/MainActivity.kt`, line ~74, change the asset name and the local variable:

```kotlin
        val yml = assets.open("VersionHistory.yml").readBytes()
        val versionItems = VersionHistoryBridge.load(yml)
            .map { VersionHistoryItem(it.version, it.descriptions) }
```

(`VersionHistoryBridge.load(ymlBytes:)` — renamed in Task 4 — passes the bytes straight to `SettingsJNI.nativeLoadVersionHistory`.)

- [ ] **Step 4: Add the asset-validation gate test**

Create `Packages/Features/Settings/Tests/SettingsLogicTests/AndroidVersionHistoryAssetTests.swift`. It locates the committed asset relative to this source file (stable `#filePath`, independent of the build dir):

```swift
import Domain
import Foundation
@testable import SettingsLogic
import Testing

/// Guards the hand-authored Android `VersionHistory.yml` asset: it must decode to at least one entry with the
/// shared loader, so a typo in the asset is caught in CI rather than shipping an empty "What's New" list.
struct AndroidVersionHistoryAssetTests {
    @Test func `android asset decodes to at least one entry`() throws {
        // <root>/Packages/Features/Settings/Tests/SettingsLogicTests/AndroidVersionHistoryAssetTests.swift
        // → delete 6 path components to reach the repository root.
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 6 { root.deleteLastPathComponent() }
        let assetURL = root.appendingPathComponent("Android/app/src/main/assets/VersionHistory.yml")

        let data = try Data(contentsOf: assetURL)
        let entries = try YAMLVersionHistoryLoader(data: data).load()
        #expect(!entries.isEmpty)
        // Every entry should carry at least one localized description string.
        #expect(entries.allSatisfy { !$0.descriptions.isEmpty })
    }
}
```

- [ ] **Step 5: Run the validation test**

From `Packages/Features/Settings`:
```
xcodebuild test -scheme Settings-Package -destination 'platform=iOS Simulator,name=iPhone 17' -skipPackagePluginValidation -only-testing:SettingsLogicTests/AndroidVersionHistoryAssetTests
```
Expected: PASS. If it fails with a file-not-found, print `#filePath` in the test and adjust the component count.

- [ ] **Step 6: Commit**

```bash
git add Android/app/src/main/assets/VersionHistory.yml \
        Android/app/src/main/kotlin/com/keynumber/folino/MainActivity.kt \
        Packages/Features/Settings/Tests/SettingsLogicTests/AndroidVersionHistoryAssetTests.swift
git add -A Android/app/src/main/assets
git commit -m "feat(version-history): Android YAML asset as independent source of truth

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: Rebuild the JNI `.so` (both ABIs) + stage bindings

**Files:** regenerates `Android/FolinoSettingsAndroid/src/main/jniLibs/{arm64-v8a,x86_64}/` and `src/main/java-generated/`.

- [ ] **Step 1: Build both ABIs and stage artifacts**

From the worktree root:
```
PATH=/Library/Developer/Toolchains/swift-6.3.2-RELEASE.xctoolchain/usr/bin:$PATH /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/version-history-split/Scripts/android-build-libs.sh
```
Expected: builds `libFolinoSettingsJNI.so` for `arm64-v8a` and `x86_64`, stages runtime stubs + `libc++_shared.so`, and copies regenerated Java bindings. This explicitly confirms the **arm64-v8a** cross-compile (the spike only covered x86_64).

- [ ] **Step 2: Confirm libyaml landed in both ABIs and bindings show `ymlBytes`**

```
ls Packages/Features/Settings/.build/aarch64-unknown-linux-android28/release/CYaml.build/src/
grep -rn "ymlBytes" Android/FolinoSettingsAndroid/src/main/java-generated/
```
Expected: the six libyaml `.o` files exist for aarch64; the generated `FolinoSettingsJNI.java` names the parameter `ymlBytes`.

- [ ] **Step 3: Commit the regenerated artifacts**

```bash
git add Android/FolinoSettingsAndroid/src/main/jniLibs \
        Android/FolinoSettingsAndroid/src/main/java-generated
git commit -m "build(version-history): rebuild JNI .so + bindings with YAML loader (libyaml)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 7: Build, install, and verify on a device

Per project convention, Android changes are verified by installing and launching on a connected device/emulator.

- [ ] **Step 1: Assemble + install the debug app**

```
PATH=/Library/Developer/Toolchains/swift-6.3.2-RELEASE.xctoolchain/usr/bin:$PATH /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/version-history-split/Android/gradlew -p /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/version-history-split/Android :app:installDebug --no-daemon
```
Expected: `BUILD SUCCESSFUL`, APK installed. If the Kotlin app fails to compile on `ymlBytes`, re-run Task 6 Step 1 (stale bindings).

- [ ] **Step 2: Launch and open the version-history screen**

```
adb shell am start -n com.KeyNumber.Folino/com.keynumber.folino.MainActivity
```
Then navigate to Settings → version history. Expected: the list renders the YAML-sourced entries (1.5.1 → 1.1.0) with descriptions in the device locale. No crash, no empty list.

- [ ] **Step 3: Record the result**

Note the device model and that the version list rendered from the YAML asset. (No commit — verification step.)

---

## Task 8: `.release.yml` — android section for future tooling

**Files:**
- Modify: `.release.yml`

- [ ] **Step 1: Add the android section**

Edit `.release.yml` to:

```yaml
app_name: Folino
history_yml: App/Resources/VersionHistory.yml
extra_locales:
  - ko
  - zh-Hans
  - zh-Hant
android:
  history_yml: Android/app/src/main/assets/VersionHistory.yml
```

- [ ] **Step 2: Confirm `ios-release` still parses the file**

Run the release tool's read-only/validation path (e.g. a dry-run or the notes-authoring step that loads `.release.yml`) and confirm it ignores the unknown `android:` key rather than erroring. If `ios-release` rejects unknown keys, move the Android config to a separate `.release.android.yml` instead and note that in the file. Do not alter the iOS top-level keys.

- [ ] **Step 3: Commit**

```bash
git add .release.yml
git commit -m "chore(version-history): .release.yml android source path for future android-release

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Final verification

- [ ] Full Settings package test pass: from `Packages/Features/Settings`,
  `xcodebuild test -scheme Settings-Package -destination 'platform=iOS Simulator,name=iPhone 17' -skipPackagePluginValidation` → all green.
- [ ] `Scripts/android-build-libs.sh` completed for arm64-v8a + x86_64 with no errors.
- [ ] Android app installed and the version-history list rendered the YAML content on a device.
- [ ] `git grep -n "JSONVersionHistoryLoader\|jsonData\|VersionHistory.json"` returns nothing under `Packages/` / `Android/.../src` / `App/` (no stale references).
- [ ] iOS app behavior unchanged (its `VersionHistory.yml` and `VersionHistoryPresenter` untouched).

## Post-merge note

After merging to `main`, regenerate the primary worktree's Library/Settings `.so` files (per the prior native-drift incident) so the installed app does not hit `UnsatisfiedLinkError` from a stale `.so`.
