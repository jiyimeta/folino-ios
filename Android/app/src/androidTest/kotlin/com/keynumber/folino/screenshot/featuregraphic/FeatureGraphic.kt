package com.keynumber.folino.screenshot.featuregraphic

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.scale
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import com.keynumber.folino.R
import com.keynumber.folino.reader.LayoutOptions
import com.keynumber.folino.reader.ReaderLayoutMode
import com.keynumber.folino.screenshot.fixtures.MarketingStrings
import com.keynumber.folino.screenshot.fixtures.ReaderSceneContent
import com.keynumber.folino.screenshot.fixtures.SCREENSHOT_STAFF_SIZE
import com.keynumber.folino.screenshot.fixtures.rememberReaderSceneState
import com.keynumber.folino.screenshot.frame.DeviceFrame
import com.keynumber.folino.ui.theme.FolinoTheme

// The 1024x500 Play Store feature graphic. Left: the folino wordmark logo (the adaptive-icon
// foreground art — the wordmark IS the brand mark, so no separate app-name text) + the localized
// tagline. Right: a real Reader sheet-music screen in a DeviceFrame, vertically centered and taller
// than the canvas so it bleeds slightly off the top/bottom (clipped at the capture bounds).
// Background: the brand gradient.
@Composable
fun FeatureGraphic(tag: String, layout: FeatureGraphicLayout = FeatureGraphicLayout.default()) {
    BoxWithConstraints(modifier = Modifier.fillMaxSize().background(layout.background)) {
        val canvasWidth = maxWidth
        val canvasHeight = maxHeight
        val frameHeight = canvasHeight * layout.frameHeightFraction
        val frameWidth = frameHeight * layout.frameAspectRatio

        // Left column: wordmark logo + tagline, vertically centered.
        Column(
            modifier = Modifier
                .align(Alignment.CenterStart)
                .padding(start = layout.horizontalPadding)
                .width(canvasWidth * layout.textColumnWidthFraction),
            verticalArrangement = Arrangement.Center,
        ) {
            Image(
                painter = painterResource(id = R.mipmap.ic_launcher_foreground),
                contentDescription = null,
                modifier = Modifier.height(layout.logoHeight).scale(layout.logoForegroundScale),
            )
            Spacer(modifier = Modifier.height(layout.verticalSpacing))
            Text(
                text = MarketingStrings.featureGraphicTagline(tag),
                color = layout.taglineColor,
                fontSize = layout.taglineFontSize,
                fontWeight = FontWeight.SemiBold,
                maxLines = 2,
            )
        }

        // Right: the Reader screen in a device frame, top-anchored so its rounded top edge stays
        // visible (only the bottom bleeds off), lifted off the light gradient by a soft drop shadow.
        Box(
            modifier = Modifier
                .align(Alignment.CenterEnd)
                .padding(end = layout.horizontalPadding)
                .fillMaxHeight(),
            contentAlignment = Alignment.TopEnd,
        ) {
            Box(
                modifier = Modifier
                    .padding(top = layout.frameTopMargin)
                    .shadow(
                        elevation = layout.frameElevation,
                        shape = RoundedCornerShape(
                            topStart = layout.frameCornerRadius,
                            topEnd = layout.frameCornerRadius,
                        ),
                        clip = false,
                    ),
            ) {
                DeviceFrame(
                    frameWidth = frameWidth,
                    frameHeight = frameHeight,
                    statusBarHeight = layout.statusBarHeight,
                    statusBarColor = layout.statusBarColor,
                    cornerRadius = layout.frameCornerRadius,
                    innerBackground = layout.innerBackground,
                    innerDesignWidth = layout.innerDesignWidth,
                ) {
                    FolinoTheme {
                        val scene = rememberReaderSceneState {
                            LayoutOptions.DEFAULT.copy(
                                mode = ReaderLayoutMode.VERTICAL,
                                staffSize = SCREENSHOT_STAFF_SIZE,
                            )
                        }
                        if (scene != null) {
                            ReaderSceneContent(
                                state = scene.state,
                                scoreHandle = scene.scoreHandle,
                                layoutOptions = scene.layoutOptions,
                                withCursor = true,
                                signalReadyWhenRendered = true,
                            )
                        }
                    }
                }
            }
        }
    }
}
