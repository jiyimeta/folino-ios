import Domain
import Foundation
import Wirelet

/// @WireFormat mirror of `Domain.ReaderCapabilities` — what a reader session may do, crossing the JNI boundary.
/// Output of `nativeReaderCapabilities`. `layoutModes` carries `ReaderLayoutMode.rawValue` strings
/// (`"vertical" | "horizontal" | "page"`) so Kotlin's existing `ReaderLayoutMode.fromPref` maps them with no new
/// parsing. Kotlin renders exactly what this struct says — it never re-derives any of these fields from the item's
/// format (parity — no divergent Kotlin decision).
@WireFormat
public struct ReaderCapabilitiesWire: Equatable {
    public let canPlay: Bool
    public let canChangeLayout: Bool
    public let canTranspose: Bool
    public let canEditStaves: Bool
    public let layoutModes: [String]

    public init(
        canPlay: Bool, canChangeLayout: Bool, canTranspose: Bool, canEditStaves: Bool, layoutModes: [String],
    ) {
        self.canPlay = canPlay
        self.canChangeLayout = canChangeLayout
        self.canTranspose = canTranspose
        self.canEditStaves = canEditStaves
        self.layoutModes = layoutModes
    }
}

// swift-java (jextract) entry points for the Android Reader's capability gating. Pure delegation to the shared
// `Domain.ReaderCapabilities` so iOS and Android decide what a session may do from one implementation (parity — no
// divergent Kotlin port). See `ReaderCapabilitiesWire` above for the wire shape.

/// The reader capabilities for a session opened on a PDF (`isPdf == true`) vs. a native score. Pure delegation to
/// `Domain.ReaderCapabilities.resolve(format:)`.
public func nativeReaderCapabilities(isPdf: Bool) -> Data {
    let capabilities = ReaderCapabilities.resolve(format: isPdf ? .pdf : nil)
    return ReaderCapabilitiesWire(
        canPlay: capabilities.canPlay,
        canChangeLayout: capabilities.canChangeLayout,
        canTranspose: capabilities.canTranspose,
        canEditStaves: capabilities.canEditStaves,
        layoutModes: capabilities.availableLayoutModes.map(\.rawValue),
    ).encodeToData()
}

/// Whether a reader session may play right now — native scores always, PDFs once their background OMR parse
/// succeeds. Pure delegation to `Domain.ReaderCapabilities.canPlayNow(capabilities:isPDFPlaybackReady:)`; only
/// `canPlay` of the capabilities matters to that rule, so the other fields are filled with placeholders.
public func nativeCanPlayNow(canPlay: Bool, isPdfPlaybackReady: Bool) -> Bool {
    var capabilities = ReaderCapabilities.forPDF
    capabilities.canPlay = canPlay
    return ReaderCapabilities.canPlayNow(capabilities: capabilities, isPDFPlaybackReady: isPdfPlaybackReady)
}

/// Whether a PDF's background OMR parse yielded enough to call itself playable, given
/// `PdfParseResultWire.playableElementCount` — swift-sheet-music's own count of the chords carrying at
/// least one note that the importer reconstructed across every staff and voice, computed independently
/// there since Android never materializes a `Score` locally. It applies the same predicate as
/// `Score.playableElementCount`, so the two agree exactly rather than merely on zero-vs-nonzero. Pure
/// delegation to
/// `Domain.ReaderCapabilities.isPlayableElementCount(_:)` — the SAME threshold `Score.hasPlayableContent`
/// applies on iOS — so Kotlin never hardcodes its own `count > 0`; the one place that decides "worth
/// playing" is Domain.
public func nativeIsPlayableElementCount(_ count: Int32) -> Bool {
    ReaderCapabilities.isPlayableElementCount(Int(count))
}
