import Wirelet
import WireletProvided

/// Draws a score to a PDF file. Implemented in Kotlin (loads the score, computes the shared `DrawProgram` layout, and
/// draws each page into an `android.graphics.pdf.PdfDocument`). Swift owns the routing + filename; this is the
/// irreducible Android-only rasterization step.
@WireletProvided
public protocol ScorePdfRenderer {
    /// Render the score at `scoreFilePath` (absolute `.mscz`) to `outPath` (.pdf). Returns `true` on success.
    func renderPdf(_ scoreFilePath: String, _ outPath: String) -> Bool
}

/// Encodes a score to an M4A file. Implemented in Kotlin via `AndroidPlaybackEngine.exportAudioFile`. The irreducible
/// Android-only audio codec step.
@WireletProvided
public protocol ScoreAudioFileExporter {
    /// Render the score at `scoreFilePath` (absolute `.mscz`) to `outPath` (.m4a). Returns `true` on success.
    func exportAudio(_ scoreFilePath: String, _ outPath: String) -> Bool
}
