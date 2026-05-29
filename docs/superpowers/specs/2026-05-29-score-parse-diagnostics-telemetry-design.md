# Score parse diagnostics telemetry — design

**Status:** approved 2026-05-29
**Scope:** folino Infrastructure (`ScoreFiles`) + composition root wiring. Telemetry only, no UI.
**Depends on (not yet released):** `swift-sheet-music` `feature/parser-diagnostics` — adds `ScoreDiagnostic` (`SheetMusicCore`) and `MSCXParser.parseWithDiagnostics` / `MSCZReader.parseWithDiagnostics`. See that repo's `docs/superpowers/specs/2026-05-29-mscx-parser-diagnostics-design.md`.

## Motivation

`swift-sheet-music` is gaining a non-fatal diagnostics channel: instead of throwing on an unrecognised embellishment (the real-world `Tremolo unknown <subtype> r64` bug), the parser now drops the decoration, loads the score, and records a `ScoreDiagnostic`. The point of that work is to learn *which* anomalies real users hit so the parser can be hardened.

folino is where those users are. This spec builds the folino-side plumbing that, on every successful parse, forwards any diagnostics to Firebase Crashlytics as non-fatals — so the diagnostic `code` (e.g. `mscx.tremolo.unknownSubtype`), its full English `message`, and `location` show up in the Crashlytics dashboard, grouped by code.

We build this **before** the upstream branch lands. The diagnostic data source is behind a one-function seam that returns an empty array today; activating it later is a dependency bump plus a small mapping change, with all the carrying logic already implemented and tested.

## Goals

1. On a successful score parse, forward `warning`-severity diagnostics to Crashlytics as non-fatals, grouped by `code`, carrying the full untruncated `message` and `location`.
2. Reuse the existing `CrashReporter` abstraction and the existing `crashReportingEnabled` opt-out — no new protocol, no new privacy setting, no new dependency.
3. Implement and test the entire carrying pipeline now, against a folino-owned seam type, so nothing is blocked on the upstream branch.
4. Make activation (once upstream lands) a small, well-marked change: bump the dependency, swap the seam to `parseWithDiagnostics`, add one end-to-end test.

## Non-goals (deferred)

- **User-facing UI.** No banner, no "this file had issues" surface. Telemetry only. The diagnostics never flow out to Features.
- **`.info`-severity reporting.** The upstream `Severity` enum has an `info` case ("notable but expected", e.g. an MS2 compatibility path), but no decoder emits it yet, and by definition it is an expected, potentially high-volume path that would only add noise to the non-fatal dashboard. The value type carries `info` faithfully; the reporter filters to `warning` only via one explicit, documented line.
- **MusicXML / MIDI diagnostics.** Upstream scopes diagnostics to the MSCX/MSCZ decoder path only. folino's MusicXML / MXL / MIDI branches report no diagnostics.
- **Firebase Analytics.** Crashlytics is the right tool for reading per-occurrence free-text messages grouped by code. If frequency aggregation is later wanted, Analytics can be added then (a dependency addition, decided separately).
- **A dedicated opt-out toggle.** Diagnostics telemetry rides the existing `PrivacySettingsKey.crashReportingEnabled` opt-out, enforced by Crashlytics' own collection flag.

## Architecture

### Data flow

```
LiveScoreFileGateway.loadScore(fileURL:)            Infrastructure / ScoreFiles — the single parse chokepoint
  └─ parse → (Score, [ScoreParseDiagnostic])        seam: returns [] today; parseWithDiagnostics later
       └─ ScoreDiagnosticReporter.report(_:)         dedupe-by-code + cap + warning-only filter
            └─ ScoreParseDiagnostic.asNSError()       domain = code, userInfo carries message/location/severity
                 └─ any CrashReporter.record(error:)  existing; no-op when collection disabled
```

Diagnostics are reported as a side effect of a successful parse. They never appear in the gateway's return value, so Features and Domain are untouched. A throwing parse produces no diagnostics (the file failed to load).

### Layering note

Everything new lives in `Infrastructure/ScoreFiles`, which already imports `Domain`, `SheetMusic`, and (transitively, used by `LiveScoreShareService`) `SheetMusicMSCX`. The reporter depends on `any CrashReporter` from `UtilityCore`, reachable from any layer. No new layer boundary is crossed; the architecture rules in `docs/engineering/module-architecture.md` are unaffected.

### New type — `ScoreParseDiagnostic` (folino-owned seam type)

`Packages/Infrastructure/Sources/ScoreFiles/ScoreParseDiagnostic.swift`, Foundation-only:

```swift
/// folino-owned mirror of swift-sheet-music's `ScoreDiagnostic`, used as the seam between the (not-yet-released)
/// parser diagnostics API and folino's telemetry pipeline. Owned by folino so the whole pipeline can be built and
/// tested before the upstream branch lands; once it does, add `init(_ ssm: ScoreDiagnostic)` to bridge.
struct ScoreParseDiagnostic: Sendable, Hashable {
    enum Severity: Sendable, Hashable { case warning, info }
    let severity: Severity
    let code: String        // e.g. "mscx.tremolo.unknownSubtype"
    let message: String     // full English message, never truncated
    let location: String?   // e.g. "measure 12, voice 1, Tremolo"
}
```

Kept in `ScoreFiles` (not Domain) because it is telemetry-only — no Feature or Domain consumer references it. Severity is carried faithfully; the reporting policy decides what to forward.

### Mapping — `ScoreParseDiagnostic.asNSError()`

`Packages/Infrastructure/Sources/ScoreFiles/ScoreParseDiagnostic+NSError.swift`, pure and fully testable today:

```swift
extension ScoreParseDiagnostic {
    func asNSError() -> NSError {
        NSError(domain: code, code: 0, userInfo: [
            NSLocalizedDescriptionKey: message,
            "diagnosticCode": code,
            "severity": severity.rawTelemetryValue,   // "warning" / "info"
            "location": location ?? "",
        ])
    }
}
```

- `domain = code` makes Crashlytics group non-fatals **per code** (e.g. all `mscx.tremolo.unknownSubtype` events under one issue). Crashlytics groups recorded `NSError`s by `domain` + `code` (the integer); all diagnostics share the same call site, so `domain` is the discriminator.
- `message` lands in `NSLocalizedDescriptionKey`, shown per occurrence with no length limit (the reason Crashlytics beats Analytics here).
- **Privacy boundary:** only `code`, `message`, `location`, and `severity` are sent. No filename, no file bytes, no user content. `code`/`message` are English templates from the parser; `location` is an in-score position string (`"measure 12, voice 1, Tremolo"`). None are PII.

### Reporter — `ScoreDiagnosticReporter`

`Packages/Infrastructure/Sources/ScoreFiles/ScoreDiagnosticReporter.swift`:

```swift
struct ScoreDiagnosticReporter: Sendable {
    let crashReporter: any CrashReporter

    /// Per-parse policy:
    /// - forward only `.warning` (see "Non-goals: .info");
    /// - dedupe by `code` so one file that trips the same anomaly N times reports once;
    /// - cap at `maxPerParse` distinct codes as a flooding safety net.
    func report(_ diagnostics: [ScoreParseDiagnostic]) {
        let warnings = diagnostics.filter { $0.severity == .warning }   // the single policy line
        var seen = Set<String>()
        for diagnostic in warnings where seen.insert(diagnostic.code).inserted {
            guard seen.count <= Self.maxPerParse else { break }
            crashReporter.record(error: diagnostic.asNSError())
        }
    }

    private static let maxPerParse = 10
}
```

No explicit opt-out check: `CrashReporter.record(error:)` is already a no-op when Crashlytics collection is disabled (`crashReportingEnabled == false`), keeping a single source of truth for the privacy preference rather than re-reading the flag here.

### Changed file — `LiveScoreFileGateway`

`Packages/Infrastructure/Sources/ScoreFiles/LiveScoreFileGateway.swift`:

- Add `init(crashReporter: any CrashReporter = NoopCrashReporter())`, storing it.
- Restructure the per-format `switch` to yield `(Score, [ScoreParseDiagnostic])`. **Every branch returns `[]` today.** The MSCX and MSCZ branches carry a marker:

```swift
let (score, diagnostics): (Score, [ScoreParseDiagnostic]) = switch format {
case .mscx:
    // TODO(parser-diagnostics): swap to MSCXParser.parseWithDiagnostics once the dependency lands.
    (try SheetMusic.loadScore(mscxData: data), [])
case .mscz:
    // TODO(parser-diagnostics): swap to MSCZReader.parseWithDiagnostics once the dependency lands.
    (try SheetMusic.loadScore(msczData: data), [])
case .musicXML: (try SheetMusic.loadScore(musicXMLData: data), [])
case .mxl:      (try SheetMusic.loadScore(mxlData: data), [])
case .midi:     (try SheetMusic.loadScore(midiData: data, sourceFilename: …), [])
}
ScoreDiagnosticReporter(crashReporter: crashReporter).report(diagnostics)
return (score, ScoreFileSummary(score: score))
```

The reporting happens inside the existing `Task.detached`; `crashReporter` is `Sendable` and captured safely. Reporting only after a successful parse (a throw skips it).

### Changed file — `AppBootstrap`

`App/AppBootstrap.swift`: the gateway is built in `start()` after `crashReporter` is configured. Change:

```swift
let gateway = LiveScoreFileGateway(crashReporter: crashReporter ?? NoopCrashReporter())
```

## Test strategy

New tests use Swift Testing. A `FakeCrashReporter` (records `record(error:)` calls; honours a `collectionEnabled` flag) lives in the Infrastructure test support.

Testable in full **today**, before the upstream branch:

- **`ScoreParseDiagnostic+NSError`** — `domain == code`; `message` in `NSLocalizedDescriptionKey`; `location`/`severity` present; nil `location` becomes `""`; asserts no filename / content keys exist (privacy guard).
- **`ScoreDiagnosticReporter`** — given synthetic diagnostics: only `.warning` recorded (`.info` skipped); duplicate codes deduped to one `record`; more than `maxPerParse` distinct codes capped; zero diagnostics → zero `record`. This proves the carrying logic end-to-end up to the Crashlytics boundary. The opt-out (`collectionEnabled == false` → nothing sent) is **not** re-tested here: the reporter unconditionally calls `record(error:)`, and suppression lives in `FirebaseCrashReporter` / the Crashlytics SDK, which is not unit-testable in folino. Keeping that gate in one place avoids drift.
- **`LiveScoreFileGateway`** — parsing a clean fixture results in **zero** `record` calls (regression guard against accidental emission), via injected `FakeCrashReporter`.

Added **with the dependency bump** (activation):

- **`LiveScoreFileGateway` end-to-end** — load a fixture containing an unknown tremolo subtype; assert exactly one `record(error:)` whose `domain == "mscx.tremolo.unknownSubtype"`. (Deferred because the non-empty path cannot be driven through the public gateway until `parseWithDiagnostics` exists; the reporter unit tests cover the carrying logic in the meantime.)

## Activation steps (once `swift-sheet-music` `feature/parser-diagnostics` is released)

1. Bump the `swift-sheet-music` revision in **both** `Packages/Infrastructure/Package.swift` and `project.yml` to the released revision (per `CLAUDE.md`).
2. Confirm `import SheetMusicMSCX` (and `SheetMusicCore` for `ScoreDiagnostic`) resolves in `ScoreFiles`. `SheetMusicMSCX` is currently used transitively by `LiveScoreShareService`; if the direct import does not resolve, add `.product(name: "SheetMusicMSCX", package: "swift-sheet-music")` (and `SheetMusicCore` if needed) to the `ScoreFiles` target dependencies, then `xcodegen generate`.
3. Add `init(_ ssm: ScoreDiagnostic)` to `ScoreParseDiagnostic` mapping `severity`/`code`/`message`/`location` one-to-one.
4. Swap the MSCX/MSCZ branches in `LiveScoreFileGateway` from `SheetMusic.loadScore(…)` to `MSCXParser.parseWithDiagnostics(…)` / `MSCZReader.parseWithDiagnostics(…)`, mapping the result's `diagnostics` through `ScoreParseDiagnostic.init(_:)`.
5. Add the end-to-end gateway test above.

## File layout summary

```
Packages/Infrastructure/Sources/ScoreFiles/
  ScoreParseDiagnostic.swift               (new — seam value type)
  ScoreParseDiagnostic+NSError.swift       (new — Crashlytics NSError mapping)
  ScoreDiagnosticReporter.swift            (new — warning-only, dedupe, cap)
  LiveScoreFileGateway.swift               (+ crashReporter init param; switch yields diagnostics; report call)

Packages/Infrastructure/Tests/InfrastructureTests/ScoreFiles/
  ScoreParseDiagnosticNSErrorTests.swift   (new)
  ScoreDiagnosticReporterTests.swift       (new)
  LiveScoreFileGatewayTests.swift          (+ zero-emission regression test)
  TestSupport/FakeCrashReporter.swift      (new or extended)

App/
  AppBootstrap.swift                       (pass crashReporter into LiveScoreFileGateway)
```

## Acceptance criteria

1. `ScoreParseDiagnostic.asNSError()` produces an `NSError` with `domain == code`, `message` under `NSLocalizedDescriptionKey`, and no filename/content keys.
2. `ScoreDiagnosticReporter.report(_:)` records only `.warning` diagnostics, deduped by `code`, capped at 10 distinct codes. (Opt-out enforcement stays in `FirebaseCrashReporter` / the Crashlytics SDK, not duplicated in the reporter.)
3. `LiveScoreFileGateway`, parsing a clean fixture, makes zero `record` calls.
4. The full Infrastructure test suite is green (`xcodebuild test` on the Infrastructure scheme, iOS Simulator).
5. SwiftLint reports zero warnings/errors on the new/changed files.
6. No new SwiftPM dependency is added; `crashReportingEnabled` remains the sole opt-out.
```
