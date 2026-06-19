package com.keynumber.folino.screenshot.frame

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign

// Port of iOS Screenshot/ScreenshotFrameView.swift. Lays out, top to bottom:
// background gradient -> bold title -> subtitle -> a rounded-corner device frame (fake status bar
// + the app screen) -> overlay() drawn on top of the frame. The device frame may extend past the
// bottom of the canvas (clipped there) so the app screen reads larger.
@Composable
fun ScreenshotFrame(
    title: String,
    subtitle: String?,
    layout: ScreenshotLayout,
    subtitleBullet: Boolean = false,
    overlay: @Composable () -> Unit = {},
    inner: @Composable () -> Unit,
) {
    BoxWithConstraints(modifier = Modifier.fillMaxSize().background(layout.background)) {
        val h = maxHeight
        val frameTop = h * layout.frameTopFraction
        val frameHeight = h * layout.frameHeightFraction
        val frameWidth = frameHeight * layout.frameAspectRatio

        // Title (top band)
        Text(
            text = title,
            color = layout.titleColor,
            fontSize = layout.titleFontSize,
            fontWeight = FontWeight.Bold,
            textAlign = TextAlign.Center,
            maxLines = 1,
            modifier = Modifier
                .align(Alignment.TopCenter)
                .padding(top = h * layout.titleTopFraction)
                .fillMaxWidth()
                .padding(horizontal = layout.horizontalPadding),
        )

        // Subtitle (top-anchored just below the title so 1- to 3-line copy grows downward into the
        // gap above the device frame instead of overlapping it). When `subtitleBullet` is true the
        // copy renders as a left-aligned bulleted list, matching iOS ScreenshotKit: each non-empty
        // line becomes "•  <line>" (U+2022 + two spaces), empty lines stay empty, joined by "\n", and
        // text is left-aligned (TextAlign.Start). Otherwise the raw subtitle renders centered.
        if (subtitle != null) {
            val subtitleText = if (subtitleBullet) {
                subtitle.split("\n").joinToString("\n") { line ->
                    if (line.isEmpty()) "" else "•  $line"
                }
            } else {
                subtitle
            }
            // Bulleted copy: the text stays left-aligned INTERNALLY, but the block itself is
            // centered as a unit — so we size the Text to its content (widthIn cap, no fillMaxWidth)
            // under a TopCenter alignment. Non-bullet copy fills the width and centers each line.
            val subtitleModifier = Modifier
                .align(Alignment.TopCenter)
                .padding(top = h * layout.subtitleTopFraction)
                .then(
                    if (subtitleBullet) {
                        Modifier.widthIn(max = maxWidth - layout.horizontalPadding * 2)
                    } else {
                        Modifier.fillMaxWidth().padding(horizontal = layout.horizontalPadding)
                    },
                )
            Text(
                text = subtitleText,
                color = layout.subtitleColor,
                fontSize = layout.subtitleFontSize,
                textAlign = if (subtitleBullet) TextAlign.Start else TextAlign.Center,
                maxLines = 3,
                modifier = subtitleModifier,
            )
        }

        // Device frame: app screen clipped to rounded corners, overlay on top.
        Box(
            modifier = Modifier
                .align(Alignment.TopCenter)
                .padding(top = frameTop)
                .height(frameHeight)
                .width(frameWidth),
        ) {
            DeviceFrame(
                frameWidth = frameWidth,
                frameHeight = frameHeight,
                statusBarHeight = layout.statusBarHeight,
                statusBarColor = layout.statusBarColor,
                cornerRadius = layout.frameCornerRadius,
                innerBackground = layout.innerBackground,
                innerDesignWidth = layout.innerDesignWidth,
                overlay = overlay,
                inner = inner,
            )
        }
    }
}
