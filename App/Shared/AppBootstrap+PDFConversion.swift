import CrashReporting
import Domain
import ScoreFiles
import UtilityCore

/// Wiring for reading an imported PDF into notation. Split out of `AppBootstrap` so that file stays within its length
/// budget; it is a launch-time concern owned by the bootstrap.
extension AppBootstrap {
    /// Builds the closure that reads a PDF into notation, over the same gateway the importer already uses.
    ///
    /// A closure rather than the converter itself because both consumers sit above Infrastructure: the importer takes
    /// it as a Domain-level type, and the Reader feature — which must never import Infrastructure — takes the same one.
    func makePDFScoreConversion(gateway: LiveScoreFileGateway) -> PDFScoreConversion {
        let converter = PDFScoreConverter(
            parser: pdfPlaybackParser,
            gateway: gateway,
            crashReporter: crashReporter ?? NoopCrashReporter(),
        )
        return { pdfURL, destination in
            await converter.convert(pdfURL: pdfURL, destinationMSCZ: destination).facts
        }
    }
}
