package com.keynumber.folino.screenshot.scenes

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.keynumber.folino.reader.DisplayInspectorContent
import com.keynumber.folino.reader.LayoutOptions
import com.keynumber.folino.reader.PartDescriptor
import com.keynumber.folino.reader.ReaderLayoutMode
import com.keynumber.folino.reader.ReaderTopBar
import com.keynumber.folino.reader.StaffAddress
import com.keynumber.folino.screenshot.fixtures.MarketingStrings
import com.keynumber.folino.screenshot.fixtures.READER_SCENE_TITLE
import com.keynumber.folino.screenshot.fixtures.ReaderSceneContent
import com.keynumber.folino.screenshot.fixtures.SCREENSHOT_STAFF_SIZE
import com.keynumber.folino.screenshot.fixtures.rememberReaderSceneState
import com.keynumber.folino.screenshot.frame.ScreenshotFrame
import com.keynumber.folino.screenshot.frame.ScreenshotLayout
import com.keynumber.folino.ui.theme.FolinoTheme

// The flattened staff order is Lead(0), Top(1), 2nd(2), 3rd(3), Bass(4), V.P.(5). The user's
// "staff 2,3,4" means the 2nd/3rd/4th staves counting from one — flattened indices 1,2,3.
internal val HIDDEN_FLAT_INDICES = setOf(1, 2, 3)

// Map flattened staff indices to their positional StaffAddress(partIndex, staffIndexInPart) by
// walking the parts in the same order the inspector enumerates them.
internal fun List<PartDescriptor>.addressesForFlatIndices(flatIndices: Set<Int>): Set<StaffAddress> {
    val addresses = flatMap { it.staves }.map { it.address }
    return flatIndices.mapNotNull { addresses.getOrNull(it) }.toSet()
}

// Display-inspector scene: the score is rendered with staves 2/3/4 hidden, and the real display
// inspector content is laid open over the bottom of the screen (the inspector's Parts rows show those
// three staves toggled to VisibilityOff). Because the static-capture harness photographs a single
// Compose node — not the window — a real `ModalBottomSheet` (a separate dialog window) would be
// invisible in the bitmap, so we host the SAME `DisplayInspectorContent` the production sheet uses in
// a bottom-aligned Surface that lives inside the captured tree (DRY: identical control list).
@Composable
fun DisplayHiddenScene(layout: ScreenshotLayout, tag: String) {
    val copy = MarketingStrings.forScene("DisplayHidden", tag)
    ScreenshotFrame(title = copy.title, subtitle = copy.subtitle, layout = layout, subtitleBullet = copy.bullet) {
        FolinoTheme {
            val scene = rememberReaderSceneState { parts ->
                val hidden = parts?.addressesForFlatIndices(HIDDEN_FLAT_INDICES) ?: emptySet()
                LayoutOptions.DEFAULT.copy(
                    mode = ReaderLayoutMode.VERTICAL,
                    staffSize = SCREENSHOT_STAFF_SIZE,
                    hiddenStaves = hidden,
                )
            }
            Column(Modifier.fillMaxSize()) {
                // Real Reader top app bar; static screenshot, callbacks are no-ops.
                ReaderTopBar(
                    onBack = {},
                    onShare = {},
                    onEditInfo = {},
                    onPlaybackControls = {},
                    onDisplaySettings = {},
                    windowInsets = WindowInsets(0, 0, 0, 0),
                )
                Box(Modifier.fillMaxSize().weight(1f)) {
                    if (scene != null) {
                        ReaderSceneContent(
                            state = scene.state,
                            scoreHandle = scene.scoreHandle,
                            layoutOptions = scene.layoutOptions,
                            withCursor = false,
                        )
                        // Bottom sheet stand-in: a rounded top surface, bottom-aligned, holding the
                        // real inspector content. `heightIn(max = …)` keeps it as a partial overlay so
                        // the (staff-reduced) score behind it stays visible above the sheet. The max is
                        // sized so the expanded General section AND at least two Parts rows both fit.
                        Surface(
                            modifier = Modifier
                                .align(Alignment.BottomCenter)
                                .fillMaxWidth()
                                .heightIn(max = 560.dp),
                            shape = RoundedCornerShape(topStart = 16.dp, topEnd = 16.dp),
                            tonalElevation = 4.dp,
                            shadowElevation = 12.dp,
                            color = MaterialTheme.colorScheme.surface,
                        ) {
                            DisplayInspectorContent(
                                options = scene.layoutOptions,
                                parts = scene.parts,
                                onChange = {},
                                // Show BOTH sections expanded: the General controls at the top and the
                                // Parts rows (with the staff visibility toggles — the point of this
                                // scene) below. The enlarged Surface above gives the Parts rows room.
                                initialGeneralExpanded = true,
                            )
                        }
                    }
                }
            }
        }
    }
}
