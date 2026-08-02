import Domain
import Foundation
import SheetMusicCore

/// Background OMR-playback readiness of an opened PDF. The document is displayed immediately
/// (`ReaderViewModel.loadState == .loadedPDF`); in parallel the PDF is parsed into a playable `Score`
/// plus the on-PDF geometry side-car. This tracks that parse so the UI can reveal playback + the
/// cursor only once it succeeds.
enum PDFPlaybackState {
    /// Not a PDF, or the parse hasn't started.
    case idle
    /// OMR is running in the background.
    case parsing
    /// Parse succeeded: the PDF is playable with an on-PDF cursor.
    case ready(PDFPlaybackData)
    /// No parser was injected, or the parse failed / yielded nothing playable. The PDF stays
    /// display-only.
    case unavailable
}

/// The playable product of parsing a PDF: the reconstructed score, the geometry linking it to the
/// original PDF pages, and the importer's best-effort diagnostics.
struct PDFPlaybackData {
    let score: Score
    let geometry: any PDFPlaybackGeometry
    let diagnostics: [PDFParseDiagnostic]
}

extension ReaderViewModel {
    /// The score that drives playback: the PDF's parsed score when ready, otherwise the natively
    /// loaded score. The playback session reads this through its `scoreProvider`, so all transport /
    /// cursor / seek machinery works for PDFs unchanged.
    var playbackScore: Score? {
        if case let .ready(data) = pdfPlayback { return data.score }
        return loadState.score
    }

    /// The parsed-PDF playback payload when ready, else `nil`. The PDF reader views read this to draw
    /// the on-PDF cursor and to resolve taps.
    var pdfPlaybackData: PDFPlaybackData? {
        if case let .ready(data) = pdfPlayback { return data }
        return nil
    }

    var isPDFPlaybackReady: Bool {
        if case .ready = pdfPlayback { return true }
        return false
    }

    /// Whether the transport + cursor should be active now: native scores always (per their
    /// capabilities), PDFs once their background parse succeeds. Delegates to the shared
    /// `ReaderCapabilities.canPlayNow` rule so iOS and Android apply the identical policy.
    var canPlayNow: Bool {
        ReaderCapabilities.canPlayNow(capabilities: capabilities, isPDFPlaybackReady: isPDFPlaybackReady)
    }

    /// The on-PDF cursor rect (top-left mediaBox space) for the current display cursor, or `nil` when
    /// there's nothing to draw (not a playable PDF, or no live cursor). PDF reader views project this
    /// into their page-frame space.
    var pdfDisplayCursorRect: PDFCursorRect? {
        pdfCursorRect(for: playbackSession.displayCursor)
    }

    /// The on-PDF cursor rect for an arbitrary cursor — e.g. an auto-follow lookahead anchor
    /// (`scrollAnchorCursor` / `pageAnchorCursor`). `nil` when the PDF isn't playable or `cursor` is nil.
    func pdfCursorRect(for cursor: ScoreCursor?) -> PDFCursorRect? {
        guard let cursor, let data = pdfPlaybackData, let score = playbackScore else { return nil }
        return data.geometry.cursorRect(for: cursor, in: score)
    }

    /// Parse the opened PDF for playback off the main actor, then prime the engine with the parsed
    /// score. Best-effort: a missing parser, any parse failure, or a parse that succeeds but yields
    /// nothing playable (e.g. an OMR pass over a raster "print to PDF" that reads staff lines but
    /// decodes no noteheads — every measure comes back full of rests) all leave the PDF display-only
    /// via `.unavailable` (never surfaces as a load error — the document is already shown). The
    /// "yielded nothing playable" half of this contract is `Score.hasPlayableContent`, shared with
    /// Android so a structurally-complete-but-silent parse never reports a playable transport on
    /// either platform.
    func parsePDFForPlayback(url: URL) async {
        guard let parser = pdfPlaybackParser else {
            pdfPlayback = .unavailable
            return
        }
        pdfPlayback = .parsing
        do {
            let result = try await parser.parse(pdfURL: url)
            guard result.score.hasPlayableContent else {
                pdfPlayback = .unavailable
                return
            }
            pdfPlayback = .ready(
                PDFPlaybackData(
                    score: result.score,
                    geometry: result.geometry,
                    diagnostics: result.diagnostics,
                ),
            )
            // The parsed score is what the transport's seek card reads through `seekTimeline`; derive its marks and
            // duration once here rather than per frame in the card.
            recomputeSeekTimeline()
            // The parsed score is now reachable via `playbackScore`; prime the engine. Idempotent —
            // the session guards re-entry — and a no-op earlier in `.task` when the parse wasn't ready.
            await playbackSession.prepareForPlayback()
        } catch {
            pdfPlayback = .unavailable
        }
    }
}
