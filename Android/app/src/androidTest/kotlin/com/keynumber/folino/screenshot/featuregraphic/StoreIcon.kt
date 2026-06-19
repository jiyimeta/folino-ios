package com.keynumber.folino.screenshot.featuregraphic

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.scale
import androidx.compose.ui.res.painterResource
import com.keynumber.folino.R
import com.keynumber.folino.screenshot.frame.Brand

// Full-bleed 512x512 Play Store icon: the brand gradient edge-to-edge with the adaptive-icon foreground
// (the folino wordmark + staff) scaled up to crop its adaptive safe-zone padding, so the tile reads the
// way the launcher shows it after masking. NO rounded clip — Google's Play Console applies the rounded
// mask, so the source must be full-bleed with sharp corners.
@Composable
fun StoreIcon(foregroundScale: Float = 1.4f) {
    Box(
        modifier = Modifier.fillMaxSize().background(Brand.iconGradient),
        contentAlignment = Alignment.Center,
    ) {
        Image(
            painter = painterResource(id = R.mipmap.ic_launcher_foreground),
            contentDescription = null,
            modifier = Modifier.fillMaxSize().scale(foregroundScale),
        )
    }
}
