package com.keynumber.folino.reader

import io.github.jiyimeta.sheetmusic.compose.draw.model.DrawProgram

sealed interface ReaderState {
    data object Loading : ReaderState
    data class Error(val message: String) : ReaderState
    data class Ready(val program: DrawProgram) : ReaderState
}
