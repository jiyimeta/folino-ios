package com.keynumber.folino.reader.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ExpandLess
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.unit.dp

/** Minimum height of a single-line inspector/settings row (Material one-line touch target). */
val InspectorRowMinHeight = 48.dp

/** Standard slider height shared by every slider-bearing row, so they read consistently. */
val InspectorSliderHeight = 24.dp

/**
 * A single-line control row with a uniform min height. Optional [leadingIcon], a [label] taking the
 * remaining width, and a [trailing] control slot. Every single-line control row (Switch, dropdown
 * trigger, +/- stepper, value+chevron) uses this so heights stay uniform across Settings and both
 * Reader inspectors. Pass [subtitle] for a two-line row (it grows taller; never forced to one line).
 * Pass [onClick] to make the whole row tappable (e.g. a chevron navigation row).
 */
@Composable
fun InspectorRow(
    label: String,
    modifier: Modifier = Modifier,
    leadingIcon: ImageVector? = null,
    leadingIconTint: Color? = null,
    subtitle: String? = null,
    onClick: (() -> Unit)? = null,
    trailing: @Composable () -> Unit = {},
) {
    val rowModifier = modifier
        .fillMaxWidth()
        .then(if (onClick != null) Modifier.clickable(onClick = onClick) else Modifier)
        .heightIn(min = InspectorRowMinHeight)
    Row(
        rowModifier,
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        if (leadingIcon != null) {
            Icon(
                leadingIcon,
                contentDescription = null,
                tint = leadingIconTint ?: androidx.compose.material3.LocalContentColor.current,
            )
        }
        if (subtitle != null) {
            Column(Modifier.weight(1f).padding(vertical = 8.dp)) {
                Text(label, style = MaterialTheme.typography.bodyMedium)
                Text(
                    subtitle,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        } else {
            Text(label, Modifier.weight(1f), style = MaterialTheme.typography.bodyMedium)
        }
        trailing()
    }
}

/**
 * A slider-bearing row — the documented exception to uniform single-line height. Optional
 * [leadingIcon], optional fixed-width [label], the [slider] slot (caller sets `Modifier.weight(1f)`
 * and `.height(InspectorSliderHeight)`), and an optional fixed-width [trailing] readout.
 */
@Composable
fun InspectorSliderRow(
    modifier: Modifier = Modifier,
    leadingIcon: ImageVector? = null,
    leadingIconTint: Color? = null,
    label: (@Composable () -> Unit)? = null,
    trailing: (@Composable () -> Unit)? = null,
    slider: @Composable () -> Unit,
) {
    Row(
        modifier.fillMaxWidth().heightIn(min = InspectorRowMinHeight),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        if (leadingIcon != null) {
            Icon(
                leadingIcon,
                contentDescription = null,
                tint = leadingIconTint ?: androidx.compose.material3.LocalContentColor.current,
            )
        }
        label?.invoke()
        slider()
        trailing?.invoke()
    }
}

/** Non-collapsible section header (Settings). */
@Composable
fun InspectorSectionHeader(title: String, modifier: Modifier = Modifier) {
    Text(
        title,
        modifier.fillMaxWidth().padding(top = 16.dp, bottom = 4.dp),
        style = MaterialTheme.typography.titleSmall,
    )
}

/** Collapsible section header (both Reader inspectors). Replaces the per-file copies. */
@Composable
fun CollapsibleHeader(title: String, expanded: Boolean, onToggle: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().clickable(onClick = onToggle).padding(vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(title, Modifier.weight(1f), style = MaterialTheme.typography.titleSmall)
        Icon(
            if (expanded) Icons.Default.ExpandLess else Icons.Default.ExpandMore,
            contentDescription = if (expanded) "Collapse" else "Expand",
        )
    }
}
