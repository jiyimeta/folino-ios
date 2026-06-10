package com.keynumber.folino.screenshot.scenes

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.SkipNext
import androidx.compose.material.icons.filled.SkipPrevious
import androidx.compose.material3.Icon
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.keynumber.folino.reader.LayoutOptions
import com.keynumber.folino.screenshot.fixtures.MarketingStrings
import com.keynumber.folino.screenshot.fixtures.ReaderSceneContent
import com.keynumber.folino.screenshot.fixtures.rememberReaderSceneState
import com.keynumber.folino.screenshot.frame.ScreenshotFrame
import com.keynumber.folino.screenshot.frame.ScreenshotLayout
import com.keynumber.folino.ui.theme.FolinoTheme

// PiP scene: a faux Android home screen with a floating picture-in-picture card that plays the score
// showing ONLY staves 2/3/4 (Top/2nd/3rd). The card hides every staff EXCEPT flattened indices 1,2,3,
// the complement of the display-inspector scene's hidden set — so the same three staves the inspector
// scene toggles off are the only ones the PiP card keeps on.
@Composable
fun PipScene(layout: ScreenshotLayout, tag: String) {
    val copy = MarketingStrings.forScene("Pip", tag)
    ScreenshotFrame(title = copy.title, subtitle = copy.subtitle, layout = layout) {
        FolinoTheme {
            Box(Modifier.fillMaxSize()) {
                FauxHomeScreen()
                PipCard(Modifier.align(Alignment.BottomEnd).padding(16.dp))
            }
        }
    }
}

// Generic launcher backdrop: a wallpaper gradient, a faux status bar, and a 4×4 grid of rounded
// app-icon placeholders with tiny labels. No real branding — just enough to read as a home screen.
@Composable
private fun FauxHomeScreen() {
    val wallpaper = Brush.verticalGradient(
        listOf(Color(0xFF1B2A4A), Color(0xFF2E4374), Color(0xFF5A6FA8)),
    )
    Box(Modifier.fillMaxSize().background(wallpaper)) {
        Column(Modifier.fillMaxSize().padding(horizontal = 18.dp)) {
            FauxStatusBar()
            Spacer(Modifier.height(8.dp))
            val tints = listOf(
                Color(0xFFE57373), Color(0xFF64B5F6), Color(0xFF81C784), Color(0xFFFFB74D),
                Color(0xFFBA68C8), Color(0xFF4DD0E1), Color(0xFFFFD54F), Color(0xFF7986CB),
                Color(0xFFA1887F), Color(0xFF4DB6AC), Color(0xFFF06292), Color(0xFF9575CD),
                Color(0xFF90A4AE), Color(0xFFAED581), Color(0xFFFF8A65), Color(0xFF4FC3F7),
            )
            val labels = listOf(
                "Phone", "Mail", "Maps", "Clock",
                "Notes", "Photos", "Music", "Files",
                "Cal", "Weather", "Camera", "Store",
                "Chat", "Health", "Wallet", "Settings",
            )
            LazyVerticalGrid(
                columns = GridCells.Fixed(4),
                contentPadding = PaddingValues(vertical = 8.dp),
                horizontalArrangement = Arrangement.spacedBy(18.dp),
                verticalArrangement = Arrangement.spacedBy(20.dp),
                userScrollEnabled = false,
            ) {
                items(16) { i ->
                    Column(horizontalAlignment = Alignment.CenterHorizontally) {
                        Box(
                            Modifier
                                .size(52.dp)
                                .clip(RoundedCornerShape(14.dp))
                                .background(tints[i]),
                        )
                        Spacer(Modifier.height(5.dp))
                        Text(labels[i], color = Color.White.copy(alpha = 0.92f), fontSize = 10.sp, maxLines = 1)
                    }
                }
            }
        }
    }
}

// Faux status bar: a clock on the left and a couple of indicator dots on the right.
@Composable
private fun FauxStatusBar() {
    Row(
        Modifier.fillMaxWidth().padding(top = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text("9:41", color = Color.White, fontSize = 13.sp, fontWeight = FontWeight.Medium)
        Spacer(Modifier.weight(1f))
        repeat(3) {
            Box(
                Modifier
                    .padding(start = 5.dp)
                    .size(6.dp)
                    .clip(CircleShape)
                    .background(Color.White.copy(alpha = 0.85f)),
            )
        }
    }
}

// Floating PiP card: a rounded, shadowed surface holding the score (only staves 2/3/4) with a small
// translucent transport row (skip / pause / skip) over the bottom edge so it reads as PiP playback.
@Composable
private fun PipCard(modifier: Modifier = Modifier) {
    Surface(
        modifier = modifier
            .width(220.dp)
            .aspectRatio(4f / 3f),
        shape = RoundedCornerShape(14.dp),
        shadowElevation = 16.dp,
        color = Color.White,
    ) {
        Box(Modifier.fillMaxSize()) {
            val scene = rememberReaderSceneState { parts ->
                // Keep ONLY flattened indices 1,2,3 visible: hide every other staff in the score.
                val keep = HIDDEN_FLAT_INDICES
                val all = parts?.let { p ->
                    p.flatMap { it.staves }.indices.toSet()
                } ?: emptySet()
                val hidden = parts?.addressesForFlatIndices(all - keep) ?: emptySet()
                LayoutOptions.DEFAULT.copy(hiddenStaves = hidden)
            }
            if (scene != null) {
                ReaderSceneContent(
                    state = scene.state,
                    scoreHandle = scene.scoreHandle,
                    layoutOptions = scene.layoutOptions,
                    withCursor = false,
                )
            }
            // Translucent transport row pinned to the bottom of the card.
            Row(
                Modifier
                    .align(Alignment.BottomCenter)
                    .fillMaxWidth()
                    .background(Color.Black.copy(alpha = 0.32f))
                    .padding(vertical = 6.dp),
                horizontalArrangement = Arrangement.Center,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(Icons.Default.SkipPrevious, contentDescription = null, tint = Color.White, modifier = Modifier.size(22.dp))
                Spacer(Modifier.width(20.dp))
                Icon(Icons.Default.Pause, contentDescription = null, tint = Color.White, modifier = Modifier.size(26.dp))
                Spacer(Modifier.width(20.dp))
                Icon(Icons.Default.SkipNext, contentDescription = null, tint = Color.White, modifier = Modifier.size(22.dp))
            }
        }
    }
}
