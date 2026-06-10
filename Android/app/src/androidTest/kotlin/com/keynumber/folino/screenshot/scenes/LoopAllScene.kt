package com.keynumber.folino.screenshot.scenes

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Repeat
import androidx.compose.material.icons.filled.Speed
import androidx.compose.material.icons.filled.Timer
import androidx.compose.material.icons.filled.VolumeUp
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Slider
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.keynumber.folino.reader.LayoutOptions
import com.keynumber.folino.reader.R
import com.keynumber.folino.reader.RepeatMode
import com.keynumber.folino.reader.RepeatModePicker
import com.keynumber.folino.screenshot.fixtures.MarketingStrings
import com.keynumber.folino.screenshot.fixtures.ReaderSceneContent
import com.keynumber.folino.screenshot.fixtures.SCREENSHOT_STAFF_SIZE
import com.keynumber.folino.screenshot.fixtures.rememberReaderSceneState
import com.keynumber.folino.screenshot.frame.ScreenshotFrame
import com.keynumber.folino.screenshot.frame.ScreenshotLayout
import com.keynumber.folino.ui.theme.FolinoTheme

// Whole-piece-repeat scene: the score behind, with the playback inspector's General section open over
// the bottom showing the repeat control set to LOOP_ALL ("1曲リピート" / "Repeat one"), NON-grayed.
//
// The real `PlaybackInspectorSheet` is a `ModalBottomSheet` (a separate dialog window — invisible to
// the single-node static capture) AND grays every control out when no audio engine is bound. Since the
// scene has no live engine, we host a focused, static stand-in of the inspector's General section in a
// bottom Surface: the same row layout (leading icon + label + control) and the SAME real
// `RepeatModePicker` the production sheet uses — rendered with `enabled = true` so the whole-piece
// option reads clearly instead of being disabled. Volume / tempo / metronome rows carry representative
// static values so the panel reads as the real inspector.
@Composable
fun LoopAllScene(layout: ScreenshotLayout, tag: String) {
    val copy = MarketingStrings.forScene("LoopAll", tag)
    ScreenshotFrame(title = copy.title, subtitle = copy.subtitle, layout = layout) {
        FolinoTheme {
            val scene = rememberReaderSceneState {
                LayoutOptions.DEFAULT.copy(staffSize = SCREENSHOT_STAFF_SIZE)
            }
            Box(Modifier.fillMaxSize()) {
                if (scene != null) {
                    ReaderSceneContent(
                        state = scene.state,
                        scoreHandle = scene.scoreHandle,
                        layoutOptions = scene.layoutOptions,
                        withCursor = false,
                    )
                    Surface(
                        modifier = Modifier
                            .align(Alignment.BottomCenter)
                            .fillMaxWidth(),
                        shape = RoundedCornerShape(topStart = 16.dp, topEnd = 16.dp),
                        tonalElevation = 4.dp,
                        shadowElevation = 12.dp,
                        color = MaterialTheme.colorScheme.surface,
                    ) {
                        InspectorGeneralPanel()
                    }
                }
            }
        }
    }
}

// Static reproduction of PlaybackInspectorSheet's General section: a "General" header followed by the
// Volume / Tempo / Metronome rows (representative static values) and the Repeat row hosting the real
// RepeatModePicker set to LOOP_ALL. Mirrors the production rows' icon + label + trailing-control layout.
@Composable
private fun InspectorGeneralPanel() {
    Column(
        Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp)
            .padding(top = 12.dp, bottom = 24.dp),
        verticalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        Text(
            "General",
            style = MaterialTheme.typography.titleSmall,
            modifier = Modifier.padding(vertical = 6.dp),
        )
        IconSliderRow(
            icon = Icons.Default.VolumeUp,
            label = "Volume",
            value = 0.8f,
            readout = "80%",
        )
        IconSliderRow(
            icon = Icons.Default.Speed,
            label = "Tempo",
            value = 0.5f,
            // Engraved-style readout (quarter-note glyph + BPM), matching the real inspector.
            readout = "♩ = 124",
        )
        Row(
            Modifier.fillMaxWidth().padding(vertical = 2.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Icon(Icons.Default.Timer, contentDescription = null)
            Text("Metronome", Modifier.weight(1f), style = MaterialTheme.typography.bodyMedium)
            Switch(checked = false, onCheckedChange = {})
        }
        Row(
            Modifier.fillMaxWidth().padding(vertical = 2.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Icon(Icons.Default.Repeat, contentDescription = null)
            Text(
                stringResource(R.string.reader_repeat_label),
                Modifier.weight(1f),
                style = MaterialTheme.typography.bodyMedium,
            )
            // The real picker, set to whole-piece repeat and ENABLED so it isn't grayed out.
            RepeatModePicker(selected = RepeatMode.LOOP_ALL, enabled = true, onSelect = {})
        }
    }
}

// Mirror of PlaybackInspectorSheet's private IconSliderRow (icon + fixed-width label + slider + readout).
@Composable
private fun IconSliderRow(
    icon: ImageVector,
    label: String,
    value: Float,
    readout: String,
) {
    Row(
        Modifier.fillMaxWidth().padding(vertical = 2.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Icon(icon, contentDescription = null)
        Text(
            label,
            modifier = Modifier.width(76.dp),
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            style = MaterialTheme.typography.bodyMedium,
        )
        Slider(
            value = value,
            onValueChange = {},
            valueRange = 0f..1f,
            modifier = Modifier.weight(1f).height(24.dp),
        )
        Text(
            readout,
            modifier = Modifier.width(64.dp),
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            style = MaterialTheme.typography.bodySmall,
        )
    }
}
