package com.keynumber.folino.reader

import io.github.jiyimeta.sheetmusic.compose.draw.model.DrawProgram

sealed interface ReaderState {
    data object Loading : ReaderState
    data class Error(val message: String) : ReaderState
    data class Ready(val program: DrawProgram) : ReaderState

    /**
     * A fixed-layout PDF. Carries only what the surfaces need to lay pages out before any bitmap is
     * rendered; the pixels come from [PdfPageSource]. Page sizes are PDF points, as `PdfRenderer`
     * reports them.
     */
    data class ReadyPdf(
        val pageCount: Int,
        val pageWidthsPt: List<Double>,
        val pageHeightsPt: List<Double>,
    ) : ReaderState
}
