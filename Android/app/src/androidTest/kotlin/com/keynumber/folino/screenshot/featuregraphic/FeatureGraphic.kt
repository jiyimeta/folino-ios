package com.keynumber.folino.screenshot.featuregraphic

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import com.keynumber.folino.R
import com.keynumber.folino.reader.LayoutOptions
import com.keynumber.folino.reader.ReaderLayoutMode
import com.keynumber.folino.screenshot.fixtures.MarketingStrings
import com.keynumber.folino.screenshot.fixtures.ReaderSceneContent
import com.keynumber.folino.screenshot.fixtures.SCREENSHOT_STAFF_SIZE
import com.keynumber.folino.screenshot.fixtures.rememberReaderSceneState
import com.keynumber.folino.screenshot.frame.DeviceFrame
import com.keynumber.folino.screenshot.scenes.addressesForFlatIndices
import com.keynumber.folino.ui.theme.FolinoTheme

// The 1024x500 Play Store feature graphic. Left: the folino wordmark logo (the icon's title layer,
// drawable folino_wordmark) over the localized tagline — the logo already reads as the brand name, so it
// stands in for both an app-icon and an app-name (no redundant pairing). Right: the real Reader
// sheet-music screen, live-rendered into a device frame (top-anchored so its rounded top stays visible
// and the bottom bleeds off, lifted off the light brand gradient by a soft shadow). `innerDesignWidth`
// controls how zoomed the score reads inside the frame.

// folino_wordmark.png is 1000x512 px; pinning the logo box to that aspect lets ContentScale.Fit render the
// full mark (including the f's long curling descender) without clipping or distortion.
private const val WORDMARK_ASPECT = 1000f / 512f

@Composable
fun FeatureGraphic(tag: String, layout: FeatureGraphicLayout = FeatureGraphicLayout.default()) {
    BoxWithConstraints(modifier = Modifier.fillMaxSize().background(layout.background)) {
        val canvasWidth = maxWidth
        val canvasHeight = maxHeight
        val frameHeight = canvasHeight * layout.frameHeightFraction
        val frameWidth = frameHeight * layout.frameAspectRatio

        // Left column: the folino wordmark logo over the tagline, both centered on a shared X axis and the
        // block vertically centered.
        Column(
            modifier = Modifier
                .align(Alignment.CenterStart)
                .padding(start = layout.horizontalPadding)
                .width(canvasWidth * layout.textColumnWidthFraction),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Image(
                painter = painterResource(id = R.drawable.folino_wordmark),
                contentDescription = "folino",
                contentScale = ContentScale.Fit,
                colorFilter = ColorFilter.tint(layout.logoColor),
                // Pin the box to the wordmark's own aspect so Fit renders the full mark (incl. the f's
                // long descender). offset nudges it off the column's center axis for visual balance.
                modifier = Modifier
                    .offset(x = layout.logoOffsetX)
                    .height(layout.logoHeight)
                    .aspectRatio(WORDMARK_ASPECT),
            )
            Spacer(modifier = Modifier.height(layout.verticalSpacing))
            Text(
                text = MarketingStrings.featureGraphicTagline(tag),
                color = layout.taglineColor,
                fontSize = layout.taglineFontSize,
                fontWeight = FontWeight.SemiBold,
                textAlign = TextAlign.Center,
                maxLines = 2,
            )
        }

        // Right: the live Reader score in a device frame — top-anchored so its rounded top stays visible
        // and only the bottom bleeds off, lifted off the light gradient by a soft shadow.
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
                        val scene = rememberReaderSceneState { parts ->
                            // Hide Top/2nd/3rd. Flattened staff order is Lead(0), Top(1), 2nd(2), 3rd(3),
                            // Bass(4), V.P.(5), so the hidden flat indices are 1, 2, 3 — leaving Lead, Bass,
                            // and V.P. visible.
                            val hidden = parts?.addressesForFlatIndices(setOf(1, 2, 3)) ?: emptySet()
                            LayoutOptions.DEFAULT.copy(
                                mode = ReaderLayoutMode.VERTICAL,
                                staffSize = SCREENSHOT_STAFF_SIZE,
                                hiddenStaves = hidden,
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
