import Domain
import Foundation
import Observation
import SheetMusicMSCX
import Wirelet
import WireletObservable

/// Android-facing Library store. The single screen consumes `scores` as a
/// Kotlin `StateFlow<List<ScoreRowWire>>`; `importScore`/`delete`/`insert`
/// cross the JNI boundary as synchronous methods.
///
/// `scores` is a *stored* property reassigned wholesale on every mutation
/// (the Observable bridge's supported StateFlow path). No injected
/// `@Observable` repository, so the bridge's nested-observable limitation
/// never applies.
///
/// `scores` is a plain `public var` (not `private(set)`): the
/// `WireletObservableBridges` plugin emits a `_scores_set` write-back bridge
/// for every `var` and does not honor `private(set)`, so the generated
/// `me.scores = …` needs an accessible setter. This matches the framework
/// convention (the observable-counter example uses plain `public var`).
/// Mutation still flows only through the `@WireletExpose` methods in practice.
@WireletObservable
@Observable
public final class LibraryAndroidStore {
    public var scores: [ScoreRowWire] = []

    public init() {}

    /// Parse the `.mscz` at `path` (a filesystem path — the Kotlin side copies
    /// the picked document into the app cache dir and passes its absolute
    /// path) and append a row. Foundation-only (zlib + XMLParser); unparseable
    /// / unreadable input is ignored (no crash, no row).
    @WireletExpose
    public func importScore(_ path: String) {
        let url = URL(fileURLWithPath: path)
        guard let score = try? MSCZReader.parse(contentsOf: url) else { return }
        // Derive the row fields via the shared Domain presenter so this matches
        // the iOS Library exactly (title = file name, subtitle = title-frame
        // subtitle, composer = metaTag). The Kotlin side names the cache file
        // with the original picked document's display name, so `lastPathComponent`
        // is that original name.
        let fields = ScorePresentation.displayFields(sourceFilename: url.lastPathComponent, score: score)
        scores.append(ScoreRowWire(
            id: UUID().uuidString,
            title: fields.title,
            subtitle: fields.subtitle ?? "",
            composer: fields.composer ?? "",
        ))
    }

    @WireletExpose
    public func delete(_ id: String) {
        scores.removeAll { $0.id == id }
    }

    /// Re-insert a previously-removed row (drives the Compose "Undo" Snackbar).
    @WireletExpose
    public func insert(_ row: ScoreRowWire) {
        scores.append(row)
    }
}
