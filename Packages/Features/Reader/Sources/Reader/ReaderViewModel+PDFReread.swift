import Domain
import Foundation

// MARK: - Reading the original PDF again

extension ReaderViewModel {
    /// Any item with an original PDF can be read again — including one folino failed to read, where this doubles as
    /// the retry. Worth offering because the importer keeps getting better at reading PDFs.
    var canReReadPDF: Bool {
        scoreItem.sourcePDFFileName != nil && pdfConversion != nil
    }

    /// Whether re-reading would discard work the user did on top of the previous read, and so has to ask first.
    var reReadNeedsConfirmation: Bool {
        PDFReparsePolicy.needsConfirmation(
            isScoreEdited: scoreItem.isPDFDerivedScoreEdited,
            hasStaffBoundPreferences: preferences.hasStaffBoundOverrides,
            hasMusicalAnnotations: !annotationDrawings.isEmpty,
        )
    }

    /// Read the original PDF again, replacing the notation with a fresh parse. Writes to a scratch file and swaps it
    /// in only on success, so a failed re-read leaves the score the user has exactly as it was.
    ///
    /// Staff-bound settings are reset afterwards: a better parse can renumber staves, and a clef override or hidden
    /// staff pointing at a different staff than the user picked is worse than no override at all. Ink anchored to the
    /// notation is kept — it may shift, which the confirmation says, and erasing a user's annotations to spare them an
    /// offset is the worse failure.
    func reReadPDF() async {
        guard let sidecarName = scoreItem.sourcePDFFileName, let pdfConversion else { return }
        reReadError = nil
        isConvertingPDF = true
        defer { isConvertingPDF = false }

        let scratch = scoresDirectory.appending(path: "\(scoreItem.id.rawValue.uuidString).reread.mscz")
        guard let facts = await pdfConversion(scoresDirectory.appending(path: sidecarName), scratch) else {
            try? FileManager.default.removeItem(at: scratch)
            reReadError = String(localized: "reader.pdf.reread.failed", bundle: .module)
            return
        }

        let msczName = "\(scoreItem.id.rawValue.uuidString).\(ScoreFormat.mscz.canonicalExtension)"
        let destination = scoresDirectory.appending(path: msczName)
        guard swapIn(scratch, over: destination) else {
            try? FileManager.default.removeItem(at: scratch)
            reReadError = String(localized: "reader.pdf.reread.failed", bundle: .module)
            return
        }

        let rewritten = PDFConversionFacts(
            fileName: msczName,
            contentHash: facts.contentHash,
            sizeBytes: facts.sizeBytes,
            summary: facts.summary,
        )
        let updated = scoreItem.adoptingPDFConversion(
            rewritten,
            sourcePDFFileName: sidecarName,
            sourcePDFContentHash: scoreItem.sourcePDFContentHash,
        )
        scoreItem = updated
        try? await repository.saveScoreItem(updated)

        await resetStaffBoundPreferences()
        // The geometry belongs to the parse we just replaced; the next switch to the original re-derives it.
        pdfPlayback = .idle
        setDisplaySource(.score)
        await load()
    }

    /// Moves `scratch` over `destination`, creating it if there was nothing there. `replaceItemAt` needs an existing
    /// item to replace, which a re-read of a never-converted PDF doesn't have.
    private func swapIn(_ scratch: URL, over destination: URL) -> Bool {
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: scratch)
            } else {
                try FileManager.default.moveItem(at: scratch, to: destination)
            }
            return true
        } catch {
            return false
        }
    }

    private func resetStaffBoundPreferences() async {
        await mutatePreferences { prefs in
            let cleared = prefs.clearingStaffBoundOverrides()
            prefs.hiddenStaves = cleared.hiddenStaves
            prefs.staffProgramOverrides = cleared.staffProgramOverrides
            prefs.staffVolumeOverrides = cleared.staffVolumeOverrides
            prefs.staffClefOverrides = cleared.staffClefOverrides
            prefs.transposeSemitones = cleared.transposeSemitones
            prefs.hasSeededAuthoredVisibility = cleared.hasSeededAuthoredVisibility
        }
    }
}
