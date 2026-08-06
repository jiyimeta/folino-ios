import Domain // AnalyticsEvent factories + AnalyticsSource / ScoreShareFormat / ScoreFormat / RepeatMode / etc.
import Observation
import UtilityCore // AnalyticsEvent, AnalyticsValue (the shared catalog types)
import Wirelet
import WireletObservable

/// Builds `AnalyticsEventWire` payloads for the Android Firebase Analytics client (`AndroidAnalytics.kt`) from the
/// SHARED catalog. Event names, parameter keys, count bucketing, and the `analyticsValue` mappings all live in
/// Domain/UtilityCore — identical to iOS, never reimplemented in Kotlin — so this bridge only marshals an
/// `AnalyticsEvent` into the JNI wire shape. Kotlin owns the actual Firebase SDK call; the bridge is one-directional.
///
/// **Wire strings stay 100% Swift.** Enum/source parameters cross the boundary as Swift *case-name tokens* (e.g.
/// `"scoreRowMenu"`, `"loopAll"`) — never as the wire `rawValue` — and the private mappers below resolve each token
/// back to the Domain enum, whose factory emits the stable wire value. Fixed-string parameters (transport actions,
/// tempo/transpose direction) are baked into dedicated builders so Kotlin never literals a wire string at all.
///
/// Stateless by design: no observable stored property, only `@WireletExpose` builder methods. The generated Kotlin
/// `AnalyticsBridgeViewModel` therefore has no `StateFlow` — just the builder methods plus a no-arg `create()`.
@WireletObservable
@Observable
public final class AnalyticsBridge {
    public init() {}

    // MARK: Library

    /// Score opened (`select_content`). `from` is an `AnalyticsSource` case-name token for the originating surface.
    @WireletExpose
    public func scoreOpened(from: String) -> AnalyticsEventWire {
        Self.encode(.scoreOpened(from: Self.source(from)))
    }

    @WireletExpose
    public func search() -> AnalyticsEventWire {
        Self.encode(.search())
    }

    @WireletExpose
    public func favoriteToggled(enabled: Bool, source: String, mode: String) -> AnalyticsEventWire {
        Self.encode(.favoriteToggled(enabled: enabled, source: Self.source(source), mode: Self.mode(mode)))
    }

    /// `count` crosses as a raw `Int32`; the Domain factory buckets it (privacy contract) before it reaches analytics.
    @WireletExpose
    public func scoreDeleted(source: String, mode: String, count: Int32) -> AnalyticsEventWire {
        Self.encode(.scoreDeleted(source: Self.source(source), mode: Self.mode(mode), count: Int(count)))
    }

    // MARK: Playlists & tags

    @WireletExpose
    public func playlistCreated(source: String) -> AnalyticsEventWire {
        Self.encode(.playlistCreated(source: Self.source(source)))
    }

    @WireletExpose
    public func playlistRenamed(source: String) -> AnalyticsEventWire {
        Self.encode(.playlistRenamed(source: Self.source(source)))
    }

    @WireletExpose
    public func playlistDeleted(source: String) -> AnalyticsEventWire {
        Self.encode(.playlistDeleted(source: Self.source(source)))
    }

    @WireletExpose
    public func playlistReordered() -> AnalyticsEventWire {
        Self.encode(.playlistReordered())
    }

    @WireletExpose
    public func scoreAddedToPlaylist(source: String, count: Int32) -> AnalyticsEventWire {
        Self.encode(.scoreAddedToPlaylist(source: Self.source(source), count: Int(count)))
    }

    @WireletExpose
    public func scoreRemovedFromPlaylist(source: String, count: Int32) -> AnalyticsEventWire {
        Self.encode(.scoreRemovedFromPlaylist(source: Self.source(source), count: Int(count)))
    }

    @WireletExpose
    public func tagCreated(source: String) -> AnalyticsEventWire {
        Self.encode(.tagCreated(source: Self.source(source)))
    }

    @WireletExpose
    public func tagDeleted(source: String) -> AnalyticsEventWire {
        Self.encode(.tagDeleted(source: Self.source(source)))
    }

    @WireletExpose
    public func tagAssigned(source: String, count: Int32) -> AnalyticsEventWire {
        Self.encode(.tagAssigned(source: Self.source(source), count: Int(count)))
    }

    @WireletExpose
    public func tagUnassigned(source: String, count: Int32) -> AnalyticsEventWire {
        Self.encode(.tagUnassigned(source: Self.source(source), count: Int(count)))
    }

    // MARK: Import (share extension)
    //
    // The manual file-picker import event is built by `LibraryAndroidStore.importScore` (it owns the parsed score, so
    // it knows the format + MuseScore version). These two builders cover the share-extension path: `importShared`
    // returns per-file `ScoreFormat` case-name tokens + already-resolved reason tokens, and Kotlin relays each here.

    /// One successfully share-imported file. `format` is a `ScoreFormat` case-name token derived from the shared
    /// file's name; `source` is fixed to `"share_ext"`, `is_duplicate` to `false` (duplicates are skipped, not logged).
    @WireletExpose
    public func scoreImportedShareExt(format: String) -> AnalyticsEventWire {
        let detected = Self.scoreFormat(format) ?? .mscz
        return Self.encode(.scoreImported(
            format: detected, source: "share_ext", isDuplicate: false, museScoreMajorVersion: nil,
        ))
    }

    /// One failed share-import. `format` is a `ScoreFormat` case-name token (or `""` when undetectable → `"unknown"`);
    /// `reason` is the wire reason string `importShared` already resolved from the shared coordinator's skip reason.
    @WireletExpose
    public func scoreImportFailedShareExt(format: String, reason: String) -> AnalyticsEventWire {
        Self.encode(.scoreImportFailed(format: Self.scoreFormat(format)?.analyticsValue ?? "unknown", reason: reason))
    }

    // MARK: Reader / playback

    /// Playback transitioned to playing. `layoutMode` is a `ReaderLayoutMode` case-name token; `from` an
    /// `AnalyticsSource` case-name token carried from where the score was opened.
    @WireletExpose
    public func playbackStarted(layoutMode: String, from: String) -> AnalyticsEventWire {
        Self.encode(.playbackStarted(layoutMode: Self.layoutMode(layoutMode), from: Self.source(from)))
    }

    @WireletExpose
    public func playbackCompleted() -> AnalyticsEventWire {
        Self.encode(.playbackCompleted())
    }

    /// `playback_control` with `action="pause"`. The transport actions are split into dedicated builders so the wire
    /// action strings ("pause"/"next"/"previous"/"seek") are authored only here in Swift, never literalled in Kotlin.
    @WireletExpose
    public func playbackPaused() -> AnalyticsEventWire {
        Self.encode(.playbackControl(action: "pause"))
    }

    @WireletExpose
    public func transportNext() -> AnalyticsEventWire {
        Self.encode(.playbackControl(action: "next"))
    }

    @WireletExpose
    public func transportPrevious() -> AnalyticsEventWire {
        Self.encode(.playbackControl(action: "previous"))
    }

    @WireletExpose
    public func seek() -> AnalyticsEventWire {
        Self.encode(.playbackControl(action: "seek"))
    }

    /// `mode` is a `RepeatMode` case-name token (`off`/`loopAll`/`abLoop`).
    @WireletExpose
    public func repeatModeChanged(mode: String) -> AnalyticsEventWire {
        Self.encode(.repeatModeChanged(Self.repeatMode(mode)))
    }

    @WireletExpose
    public func tempoIncreased() -> AnalyticsEventWire {
        Self.encode(.tempoChanged(direction: "increase"))
    }

    @WireletExpose
    public func tempoDecreased() -> AnalyticsEventWire {
        Self.encode(.tempoChanged(direction: "decrease"))
    }

    /// `mode` is a `ReaderLayoutMode` case-name token.
    @WireletExpose
    public func layoutModeChanged(mode: String) -> AnalyticsEventWire {
        Self.encode(.layoutModeChanged(Self.layoutMode(mode)))
    }

    @WireletExpose
    public func transposeUp() -> AnalyticsEventWire {
        Self.encode(.transposeChanged(direction: "up"))
    }

    @WireletExpose
    public func transposeDown() -> AnalyticsEventWire {
        Self.encode(.transposeChanged(direction: "down"))
    }

    @WireletExpose
    public func scoreInfoOpened(source: String) -> AnalyticsEventWire {
        Self.encode(.scoreInfoOpened(source: Self.source(source)))
    }

    // MARK: Share

    /// `method` is a `ScoreShareFormat` case-name token (the same token the export sheet uses); `source`/`mode` are
    /// `AnalyticsSource` / `AnalyticsActionMode` case-name tokens.
    @WireletExpose
    public func share(method: String, source: String, mode: String) -> AnalyticsEventWire {
        Self.encode(.share(
            method: Self.shareFormat(method).analyticsValue,
            source: Self.source(source),
            mode: Self.mode(mode),
        ))
    }

    // MARK: Settings / app

    /// `setting_changed` for a boolean toggle. `key` is a `SettingKey` case-name token; the wire key + `"true"`/
    /// `"false"` value are authored in the shared Domain catalog.
    @WireletExpose
    public func settingChangedToggle(key: String, on: Bool) -> AnalyticsEventWire {
        let wireKey = SettingKey(caseToken: key)?.rawValue ?? key
        return Self.encode(.settingChanged(key: wireKey, value: on ? "true" : "false"))
    }

    /// `setting_changed` for the repeat-mode picker. `mode` is a `RepeatMode` case-name token.
    @WireletExpose
    public func settingChangedRepeatMode(mode: String) -> AnalyticsEventWire {
        Self.encode(.settingChanged(key: SettingKey.repeatMode.rawValue, value: Self.repeatMode(mode).analyticsValue))
    }

    /// `setting_changed` for the layout-mode picker. `mode` is a `ReaderLayoutMode` case-name token.
    @WireletExpose
    public func settingChangedLayoutMode(mode: String) -> AnalyticsEventWire {
        Self.encode(.settingChanged(key: SettingKey.layoutMode.rawValue, value: Self.layoutMode(mode).analyticsValue))
    }

    /// `setting_changed` for the playlist-continuation picker. `mode` is a `PlaylistContinuationMode` case-name token.
    @WireletExpose
    public func settingChangedPlaylistContinuation(mode: String) -> AnalyticsEventWire {
        Self.encode(.settingChanged(
            key: SettingKey.playlistContinuation.rawValue, value: Self.continuationMode(mode).analyticsValue,
        ))
    }

    /// `setting_changed` for the A4 reference slider. Matches iOS, which logs the committed integer Hz as a string.
    @WireletExpose
    public func settingChangedA4(hz: Double) -> AnalyticsEventWire {
        Self.encode(.settingChanged(key: SettingKey.a4Reference.rawValue, value: String(Int(hz.rounded()))))
    }

    /// Settings screen opened (the Task 18 end-to-end smoke event; iOS logs the same `settings_opened`).
    @WireletExpose
    public func settingsOpened() -> AnalyticsEventWire {
        Self.encode(.settingsOpened())
    }

    // MARK: Screen views

    /// Manual `screen_view` (Compose, like SwiftUI, is a single host, so screen views are not auto-collected). `name`
    /// is an `AnalyticsScreen` case-name token; the wire `screen_name` value stays in the Domain enum.
    @WireletExpose
    public func screen(name: String) -> AnalyticsEventWire {
        Self.encode(.screen(Self.screen(name)))
    }

    // MARK: Launch snapshots (events-first replacement for user properties)

    /// One-per-launch `settings_snapshot` of durable settings, mirroring iOS `AppBootstrap`. Raw values — bucket at
    /// analysis time. Kotlin reads DataStore and passes the values; enum params cross as case-name tokens. The
    /// companion `library_snapshot` is built by `LibraryAndroidStore.librarySnapshot()` (it owns the score records).
    @WireletExpose
    public func settingsSnapshot(
        metronome: Bool,
        pictureInPicture: Bool,
        collapseMultiMeasureRests: Bool,
        showInvisibles: Bool,
        keepScreenAwake: Bool,
        showSeekBar: Bool,
        repeatMode: String,
        playlistContinuation: String,
        a4ReferenceHz: Double,
        layoutMode: String,
        crashReportingEnabled: Bool,
        soundfontPreset: String,
    ) -> AnalyticsEventWire {
        Self.encode(.settingsSnapshot(
            metronome: metronome,
            pictureInPicture: pictureInPicture,
            collapseMultiMeasureRests: collapseMultiMeasureRests,
            showInvisibles: showInvisibles,
            keepScreenAwake: keepScreenAwake,
            showSeekBar: showSeekBar,
            repeatMode: Self.repeatMode(repeatMode),
            playlistContinuation: Self.continuationMode(playlistContinuation),
            a4ReferenceHz: a4ReferenceHz,
            layoutMode: Self.layoutMode(layoutMode),
            crashReportingEnabled: crashReportingEnabled,
            soundfontPreset: soundfontPreset,
        ))
    }

    /// One `score_prefs` wire event from ONE stored preferences JSON blob. Kotlin's launch path enumerates its live
    /// blobs and relays each through this builder, skipping empty-named results (all-untouched rows and undecodable
    /// blobs). Event name, the presence-means-changed rule, and every bucket boundary live in the shared Domain
    /// factory — Kotlin authors no wire string. `widthDp` is Android's point-equivalent width; analysis never compares
    /// widths across platforms without the auto-attached `platform`. Deliberately a single-`String` argument per call:
    /// wirelet's `[String]` method-arg support is unreleased.
    ///
    /// **A legacy (pre-`schemaVersion`) blob never reports `staff_size`, whatever it stores.** Android's
    /// since-removed eager seed wrote the global staff size in effect when the score was first opened. The Reader's
    /// own decode demotes that value when it equals the frozen seed Android actually wrote
    /// (`ReaderPreferencesReducer.decode(_:)`), but the pre-`schemaVersion` world did not record the
    /// chosen-vs-seeded distinction at all, so anything else a legacy blob holds is ambiguous. Dropping the parameter
    /// under-reports, which is the direction this instrumentation errs everywhere else (spec §4, §6), and the
    /// population is self-limiting — the first mutation of any such score re-encodes it as `schemaVersion: 2`, after
    /// which its `staffSize` is authoritative and reported. iOS needs no such rule: its seed was the frozen constant
    /// `14`, so the v16 migration's `CASE WHEN staff_size = 14 THEN NULL` is exact.
    ///
    /// This is an **analytics-only** widening. `ReaderPreferencesBridge.open` renders from the decoded value, so what
    /// the Reader shows is unaffected.
    ///
    /// `defaultStaffSize` is the Reader's current *global* staff size — the same `prefs.staffSize` flow `MainActivity`
    /// hands to `ReaderPreferencesBridge.open`. With the rule above it no longer influences any parameter; it is kept
    /// in the signature so the JNI wire shape stays put and so the value is on hand if a later parameter needs it.
    @WireletExpose
    public func scorePrefs(prefsJson: String, widthDp: Double, defaultStaffSize: Double) -> AnalyticsEventWire {
        guard var prefs = ReaderPreferencesReducer.decode(prefsJson) else {
            return AnalyticsEventWire(name: "", params: [])
        }
        if ReaderPreferencesReducer.isLegacyBlob(prefsJson) { prefs.staffSize = nil }
        guard let event = AnalyticsEvent.scorePrefs(prefs, screenWidthPt: widthDp) else {
            return AnalyticsEventWire(name: "", params: [])
        }
        return Self.encode(event)
    }

    // MARK: - Marshaling

    /// Marshal a shared `AnalyticsEvent` into the JNI wire shape, mirroring iOS `FirebaseAnalyticsClient`'s
    /// `AnalyticsValue -> Firebase` mapping (.string -> String, .int -> Long, .double -> Double, .bool -> Bool).
    /// All four cases are handled: events-first logs raw counts as `.int` (e.g. `score_deleted.count`,
    /// `library_snapshot` totals) and `.double` for `a4_reference_hz` / `duration_sec`, so every payload kind is live.
    static func encode(_ event: AnalyticsEvent) -> AnalyticsEventWire {
        let params = event.parameters.map { key, value -> AnalyticsParamWire in
            switch value {
            case let .string(s):
                AnalyticsParamWire(key: key, kind: 0, stringValue: s)
            case let .int(i):
                AnalyticsParamWire(key: key, kind: 1, longValue: Int32(truncatingIfNeeded: i))
            case let .double(d):
                AnalyticsParamWire(key: key, kind: 2, doubleValue: d)
            case let .bool(b):
                AnalyticsParamWire(key: key, kind: 3, boolValue: b)
            }
        }
        return AnalyticsEventWire(name: event.name, params: params)
    }
}
