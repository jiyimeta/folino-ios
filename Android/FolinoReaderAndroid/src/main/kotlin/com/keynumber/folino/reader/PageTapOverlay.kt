package com.keynumber.folino.reader

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.snap
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.ArrowForward
import androidx.compose.material.icons.automirrored.filled.LastPage
import androidx.compose.material.icons.filled.FirstPage
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.addOutline
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp

/** Translucent grey fill shared by the pressed tap-zone highlight and the page-position badge. */
private val HighlightFill = Color(0x80808080)

/**
 * Four page-navigation tap zones at the leading / trailing edges. Mirrors the iOS `TapOverlay`:
 * 12 %-wide columns split 3:7 (top = first/last, bottom = prev/next), a press lights every zone in
 * unison, a same-colour `n / m` badge fades with the zones, and a first-touch onboarding hint shows a
 * translucent accent fill + dashed accent border. The whole overlay is scaled/panned with the page
 * zoom by the caller (via [modifier]).
 */
@Composable
fun PageTapOverlay(
    viewportSize: IntSize,
    currentPage: Int,
    pageCount: Int,
    showsHint: Boolean,
    onAnyZoneTouchDown: () -> Unit,
    onFirst: () -> Unit,
    onPrev: () -> Unit,
    onNext: () -> Unit,
    onLast: () -> Unit,
    modifier: Modifier = Modifier,
) {
    var pressedCount by remember { mutableIntStateOf(0) }
    val highlighted = pressedCount > 0
    val density = LocalDensity.current
    val columnWidth = with(density) { (viewportSize.width * 0.12f).toDp() }

    // Appears instantly on touch-down, then fades out over 0.3 s after a 0.35 s hold so the user can
    // see which zone fired before it disappears (iOS uses `nil` in / `easeOut(0.3).delay(0.35)` out).
    val highlightAlpha by animateFloatAsState(
        targetValue = if (highlighted) 1f else 0f,
        animationSpec = if (highlighted) snap() else tween(durationMillis = 300, delayMillis = 350),
        label = "tapHighlightAlpha",
    )

    val onPress: (Boolean) -> Unit = { down ->
        pressedCount += if (down) 1 else -1
        if (down && pressedCount == 1) onAnyZoneTouchDown()
    }

    val radius = 12.dp
    // The side running along the screen edge stays square; the inner side rounds off, so the zone
    // reads as a tab tucked against the edge (iOS `cornerRadii`).
    val leadingShape = RoundedCornerShape(topStart = 0.dp, bottomStart = 0.dp, topEnd = radius, bottomEnd = radius)
    val trailingShape = RoundedCornerShape(topStart = radius, bottomStart = radius, topEnd = 0.dp, bottomEnd = 0.dp)

    Box(modifier.fillMaxSize()) {
        Row(Modifier.fillMaxSize()) {
            EdgeColumn(
                columnWidth, leadingShape,
                Icons.Filled.FirstPage, Icons.AutoMirrored.Filled.ArrowBack,
                "First", "Prev", highlightAlpha, showsHint, onFirst, onPrev, onPress,
            )
            Box(Modifier.weight(1f).fillMaxHeight())
            EdgeColumn(
                columnWidth, trailingShape,
                Icons.AutoMirrored.Filled.LastPage, Icons.AutoMirrored.Filled.ArrowForward,
                "Last", "Next", highlightAlpha, showsHint, onLast, onNext, onPress,
            )
        }
        if (highlightAlpha > 0f) {
            Text(
                "${currentPage + 1} / $pageCount",
                color = Color.White,
                style = MaterialTheme.typography.titleMedium,
                modifier = Modifier
                    .align(Alignment.BottomCenter)
                    .padding(bottom = 24.dp)
                    .alpha(highlightAlpha)
                    .background(HighlightFill, RoundedCornerShape(50))
                    .padding(horizontal = 14.dp, vertical = 6.dp),
            )
        }
    }
}

@Composable
private fun EdgeColumn(
    width: Dp,
    shape: RoundedCornerShape,
    topIcon: ImageVector,
    bottomIcon: ImageVector,
    topLabel: String,
    bottomLabel: String,
    highlightAlpha: Float,
    showsHint: Boolean,
    onTopTap: () -> Unit,
    onBottomTap: () -> Unit,
    onPress: (Boolean) -> Unit,
) {
    Column(Modifier.width(width).fillMaxHeight(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        TapZone(Modifier.weight(0.3f), shape, topIcon, topLabel, highlightAlpha, showsHint, onTopTap, onPress)
        TapZone(Modifier.weight(0.7f), shape, bottomIcon, bottomLabel, highlightAlpha, showsHint, onBottomTap, onPress)
    }
}

@Composable
private fun TapZone(
    modifier: Modifier,
    shape: RoundedCornerShape,
    icon: ImageVector,
    label: String,
    highlightAlpha: Float,
    showsHint: Boolean,
    onTap: () -> Unit,
    onPress: (Boolean) -> Unit,
) {
    val primaryColor = MaterialTheme.colorScheme.primary
    // Hint is mutually exclusive with the press visual — the moment a finger lands, the press layer
    // takes over.
    val hintVisible = showsHint && highlightAlpha == 0f
    Box(
        modifier
            .fillMaxWidth()
            .pointerInput(Unit) {
                detectTapGestures(
                    onPress = { onPress(true); tryAwaitRelease(); onPress(false) },
                    onTap = { onTap() },
                )
            },
        contentAlignment = Alignment.Center,
    ) {
        // Press-feedback layer: translucent grey fill + white icon/label, alpha-driven.
        Box(Modifier.matchParentSize().alpha(highlightAlpha), contentAlignment = Alignment.Center) {
            Box(Modifier.matchParentSize().background(HighlightFill, shape))
            ZoneLabel(icon, label, Color.White)
        }
        // Onboarding-hint layer: translucent accent fill + dashed accent border + accent icon/label.
        if (hintVisible) {
            Box(Modifier.matchParentSize(), contentAlignment = Alignment.Center) {
                Box(
                    Modifier
                        .matchParentSize()
                        .background(primaryColor.copy(alpha = 0.12f), shape)
                        .drawBehind {
                            val path = Path().apply {
                                addOutline(shape.createOutline(size, layoutDirection, this@drawBehind))
                            }
                            drawPath(
                                path = path,
                                color = primaryColor,
                                style = Stroke(
                                    width = 1.5.dp.toPx(),
                                    pathEffect = PathEffect.dashPathEffect(floatArrayOf(18f, 12f), 0f),
                                ),
                            )
                        },
                )
                ZoneLabel(icon, label, primaryColor)
            }
        }
    }
}

@Composable
private fun ZoneLabel(icon: ImageVector, label: String, tint: Color) {
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Icon(icon, contentDescription = label, tint = tint)
        Text(label, color = tint, style = MaterialTheme.typography.labelSmall)
    }
}
