package com.keynumber.folino.reader

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import io.github.jiyimeta.sheetmusic.compose.draw.model.DrawProgram
import io.github.jiyimeta.sheetmusic.compose.render.bundledFontProvider

/**
 * Minimal Picture-in-Picture surface: the score forced to horizontal single-system layout, with
 * the playback cursor following along — no toolbar, transport, inspector, or gestures. Reuses
 * [HorizontalScore] (ScorePage + PlaybackCursorOverlay + JNI auto-scroll) on a dedicated horizontal
 * program so it stays horizontal even when the user's normal layout mode is page/vertical.
 */
@Composable
internal fun ReaderPipContent(
    readerVm: ReaderViewModel,
    audioVm: ReaderAudioViewModel,
) {
    val context = LocalContext.current
    val fontProvider = remember(context) { bundledFontProvider(context) }
    val scoreHandle by readerVm.scoreHandle.collectAsStateWithLifecycle()
    val layoutOptions by readerVm.layoutOptions.collectAsStateWithLifecycle()

    var program by remember { mutableStateOf<DrawProgram?>(null) }
    // Recompute the horizontal program whenever the score or display options change.
    LaunchedEffect(scoreHandle, layoutOptions) {
        program = readerVm.horizontalProgram()
    }

    Box(
        Modifier
            .fillMaxSize()
            .background(Color.White),
        contentAlignment = Alignment.Center,
    ) {
        val p = program
        if (p != null && p.pages.isNotEmpty()) {
            HorizontalScore(
                state = ReaderState.Ready(p),
                scoreHandle = scoreHandle,
                fontProvider = fontProvider,
                audioVm = audioVm,
                layoutOptions = layoutOptions.copy(mode = ReaderLayoutMode.HORIZONTAL),
                pipFit = true,
            )
        }
    }
}
