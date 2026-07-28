package com.keynumber.folino.reader.pdf

import io.github.jiyimeta.sheetmusic.PdfScoreHandle

/**
 * Background OMR-playback readiness of an opened PDF (Task 12). The PDF's own pages are displayed
 * immediately ([com.keynumber.folino.reader.ReaderState.ReadyPdf]); in parallel the PDF is parsed off
 * the main thread into a playable score plus the on-PDF geometry side-car carried by [PdfScoreHandle].
 * This tracks that parse so the transport is only enabled once it succeeds — mirrors iOS's
 * `PDFPlaybackState`.
 */
internal sealed interface PdfPlaybackState {
    /** Not a PDF, or the parse hasn't started. */
    data object Idle : PdfPlaybackState

    /** OMR is running in the background. The document is already on screen; the transport stays
     * disabled (not hidden) while this is active. */
    data object Parsing : PdfPlaybackState

    /** Parse succeeded: [handle] carries the reconstructed score and the geometry that maps score
     * positions back to rectangles on the original PDF pages (Task 13's cursor, Task 14's tap-to-seek). */
    data class Ready(val handle: PdfScoreHandle) : PdfPlaybackState

    /** The parse failed or yielded nothing playable. The PDF stays display-only and silent — never
     * surfaced as a load error, since the document is already shown. */
    data object Unavailable : PdfPlaybackState
}
