package com.keynumber.folino.reader

import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.unit.dp

/**
 * A | B capsule. Each half is accent-tinted while its endpoint is unset and neutral once set; tapping
 * toggles (set/clear) that endpoint. Mirrors iOS ABEndpointPill, adapted to Material.
 */
@Composable
fun AbEndpointButtons(
    aSet: Boolean,
    bSet: Boolean,
    enabled: Boolean,
    onSetA: () -> Unit,
    onSetB: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Row(modifier.height(40.dp)) {
        AbHalf("A", set = aSet, enabled = enabled, onClick = onSetA,
            shape = RoundedCornerShape(topStart = 20.dp, bottomStart = 20.dp))
        AbHalf("B", set = bSet, enabled = enabled, onClick = onSetB,
            shape = RoundedCornerShape(topEnd = 20.dp, bottomEnd = 20.dp))
    }
}

@Composable
private fun AbHalf(label: String, set: Boolean, enabled: Boolean, onClick: () -> Unit, shape: Shape) {
    val container = if (set) MaterialTheme.colorScheme.surfaceVariant else MaterialTheme.colorScheme.primary
    val content = if (set) MaterialTheme.colorScheme.onSurfaceVariant else MaterialTheme.colorScheme.onPrimary
    Button(
        onClick = onClick,
        enabled = enabled,
        shape = shape,
        contentPadding = PaddingValues(horizontal = 14.dp),
        colors = ButtonDefaults.buttonColors(containerColor = container, contentColor = content),
    ) { Text(label) }
}
