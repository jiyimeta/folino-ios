package com.keynumber.folino.reader

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowDropDown
import androidx.compose.material.icons.filled.ExpandLess
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material.icons.filled.Visibility
import androidx.compose.material.icons.filled.VisibilityOff
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SheetState
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Slider
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.PlatformTextStyle
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.LineHeightStyle
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlin.math.roundToInt

/** Compact slider height so the dense General section doesn't dominate the sheet. */
private val sliderHeight = 24.dp

/**
 * Display-settings panel for the Reader (Android port of the iOS display inspector).
 *
 * Pure UI over the [LayoutOptions] value type: every control edit produces a new options
 * snapshot via [onChange]; the caller owns persistence (DataStore) and re-rendering. This
 * keeps the library module free of any app-module / ViewModel / DataStore dependency.
 *
 * Layout is tuned for information density (mirroring the iOS Form inspector while staying
 * Material-idiomatic): whole-score controls live under a collapsible "General" header, and
 * the per-staff clef / visibility controls live under a collapsible "Parts" header. The clef
 * picker renders the actual SMuFL glyph via the bundled Bravura music font.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DisplayInspectorSheet(
    options: LayoutOptions,
    parts: List<PartDescriptor>,
    sheetState: SheetState,
    onDismiss: () -> Unit,
    onChange: (LayoutOptions) -> Unit,
) {
    var generalExpanded by rememberSaveable { mutableStateOf(true) }
    var partsExpanded by rememberSaveable { mutableStateOf(true) }
    val musicFont = rememberMusicFont()

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState) {
        LazyColumn(
            Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp)
                .padding(bottom = 24.dp),
        ) {
            // ── General (layout mode / staff size / display flags) ───
            item {
                CollapsibleHeader(
                    stringResource(R.string.reader_inspector_general),
                    generalExpanded,
                ) { generalExpanded = !generalExpanded }
            }
            if (generalExpanded) {
                item { LayoutModeRow(options.mode) { onChange(options.copy(mode = it)) } }
                item {
                    StaffSizeRow(options.staffSize) { onChange(options.copy(staffSize = it)) }
                }
                item {
                    SwitchRow(
                        label = stringResource(R.string.reader_pref_honor_breaks),
                        checked = options.honorLayoutBreaks,
                    ) { onChange(options.copy(honorLayoutBreaks = it)) }
                }
                item {
                    SwitchRow(
                        label = stringResource(R.string.reader_pref_collapse_rests),
                        checked = options.collapseMultiMeasureRests,
                    ) { onChange(options.copy(collapseMultiMeasureRests = it)) }
                }
                item {
                    SwitchRow(
                        label = stringResource(R.string.reader_pref_show_invisible),
                        checked = options.showInvisibleElements,
                    ) { onChange(options.copy(showInvisibleElements = it)) }
                }
            }

            item { HorizontalDivider(Modifier.padding(vertical = 4.dp)) }

            // ── Parts (per-staff clef + visibility) ──────────────────
            item {
                CollapsibleHeader(
                    stringResource(R.string.reader_inspector_parts),
                    partsExpanded,
                ) { partsExpanded = !partsExpanded }
            }
            if (partsExpanded) {
                parts.forEach { part ->
                    item {
                        Text(
                            part.name.ifEmpty { stringResource(R.string.reader_part_untitled) },
                            Modifier.fillMaxWidth().padding(top = 6.dp, bottom = 2.dp),
                            style = MaterialTheme.typography.labelLarge,
                        )
                    }
                    items(
                        part.staves,
                        key = { "${it.address.partIndex}-${it.address.staffIndexInPart}" },
                    ) { staff ->
                        StaffRow(
                            staff = staff,
                            options = options,
                            musicFont = musicFont,
                            onChange = onChange,
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun LayoutModeRow(mode: ReaderLayoutMode, onSelect: (ReaderLayoutMode) -> Unit) {
    val modes = listOf(
        ReaderLayoutMode.VERTICAL to R.string.reader_layout_vertical,
        ReaderLayoutMode.HORIZONTAL to R.string.reader_layout_horizontal,
        ReaderLayoutMode.PAGE to R.string.reader_layout_page,
    )
    Column(Modifier.fillMaxWidth().padding(vertical = 2.dp)) {
        Text(
            stringResource(R.string.reader_display_mode),
            style = MaterialTheme.typography.bodyMedium,
        )
        SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth().padding(top = 2.dp)) {
            modes.forEachIndexed { index, (m, labelRes) ->
                SegmentedButton(
                    selected = mode == m,
                    onClick = { onSelect(m) },
                    shape = SegmentedButtonDefaults.itemShape(index, modes.size),
                ) {
                    Text(stringResource(labelRes))
                }
            }
        }
    }
}

@Composable
private fun StaffSizeRow(staffSize: Double, onChange: (Double) -> Unit) {
    Row(
        Modifier.fillMaxWidth().padding(vertical = 2.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Text(
            stringResource(R.string.reader_pref_staff_size),
            modifier = Modifier.width(88.dp),
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            style = MaterialTheme.typography.bodyMedium,
        )
        Slider(
            value = staffSize.toFloat(),
            onValueChange = { onChange(it.toDouble()) },
            valueRange = 8f..28f,
            modifier = Modifier.weight(1f).height(sliderHeight),
        )
        Text(
            "${staffSize.roundToInt()} pt",
            modifier = Modifier.width(44.dp),
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            style = MaterialTheme.typography.bodySmall,
        )
    }
}

@Composable
private fun SwitchRow(label: String, checked: Boolean, onCheckedChange: (Boolean) -> Unit) {
    Row(
        Modifier.fillMaxWidth().padding(vertical = 2.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Text(label, Modifier.weight(1f), style = MaterialTheme.typography.bodyMedium)
        Switch(checked = checked, onCheckedChange = onCheckedChange)
    }
}

@Composable
private fun StaffRow(
    staff: StaffDescriptor,
    options: LayoutOptions,
    musicFont: FontFamily,
    onChange: (LayoutOptions) -> Unit,
) {
    val effectiveRaw = options.clefOverrides[staff.address] ?: staff.defaultClefRawType
    val hidden = staff.address in options.hiddenStaves
    Row(
        Modifier.fillMaxWidth().padding(vertical = 2.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        ClefGlyphPicker(
            currentRaw = effectiveRaw,
            musicFont = musicFont,
            modifier = Modifier.weight(1f),
            onSelect = { choice ->
                onChange(
                    options.copy(
                        clefOverrides = options.clefOverrides + (staff.address to choice.rawType),
                    ),
                )
            },
            onReset = {
                onChange(options.copy(clefOverrides = options.clefOverrides - staff.address))
            },
        )
        IconButton(
            onClick = {
                onChange(
                    options.copy(
                        hiddenStaves = options.hiddenStaves.toMutableSet().apply {
                            if (!add(staff.address)) remove(staff.address)
                        },
                    ),
                )
            },
        ) {
            Icon(
                if (hidden) Icons.Default.VisibilityOff else Icons.Default.Visibility,
                contentDescription = stringResource(
                    if (hidden) R.string.reader_staff_show else R.string.reader_staff_hide,
                ),
            )
        }
    }
}

/**
 * Text style for SMuFL clef glyphs. The Bravura font reports very large ascent/descent, which
 * otherwise inflates each row's height; trimming the line metrics to a fixed [lineHeight] keeps
 * the trigger button and dropdown rows compact.
 */
@Composable
private fun clefGlyphStyle() = MaterialTheme.typography.titleLarge.copy(
    platformStyle = PlatformTextStyle(includeFontPadding = false),
    lineHeightStyle = LineHeightStyle(
        alignment = LineHeightStyle.Alignment.Center,
        trim = LineHeightStyle.Trim.Both,
    ),
    lineHeight = 22.sp,
)

@Composable
private fun ClefGlyphPicker(
    currentRaw: String,
    musicFont: FontFamily,
    modifier: Modifier = Modifier,
    onSelect: (ClefChoice) -> Unit,
    onReset: () -> Unit,
) {
    var expanded by remember { mutableStateOf(false) }
    val glyphStyle = clefGlyphStyle()
    val currentChoice = ClefChoice.fromRawType(currentRaw)
    val currentGlyph = currentChoice?.glyph?.let { String(Character.toChars(it)) }
    // Always show a textual name so the button is meaningful even if the glyph font is unavailable.
    val currentName = currentChoice?.let { localizedClefLabel(it) } ?: currentRaw
    // Family order: treble, bass, c, percussion (matches iOS ClefMenuChoice grouping).
    val choices = remember {
        ClefChoice.trebleFamily +
            ClefChoice.bassFamily +
            ClefChoice.cFamily +
            ClefChoice.percussionFamily
    }
    val rowPadding = PaddingValues(horizontal = 12.dp, vertical = 2.dp)
    Column(modifier) {
        TextButton(
            onClick = { expanded = true },
            modifier = Modifier.fillMaxWidth(),
        ) {
            if (currentGlyph != null) {
                Text(text = currentGlyph, fontFamily = musicFont, style = glyphStyle)
                Spacer(Modifier.width(8.dp))
            }
            Text(
                text = currentName,
                style = MaterialTheme.typography.bodyMedium,
                modifier = Modifier.weight(1f),
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Icon(
                Icons.Default.ArrowDropDown,
                contentDescription = stringResource(R.string.reader_clef_choose),
            )
        }
        DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            choices.forEach { choice ->
                val glyphString = String(Character.toChars(choice.glyph))
                DropdownMenuItem(
                    contentPadding = rowPadding,
                    text = {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(12.dp),
                        ) {
                            Text(glyphString, fontFamily = musicFont, style = glyphStyle)
                            Text(localizedClefLabel(choice), style = MaterialTheme.typography.bodyMedium)
                        }
                    },
                    onClick = {
                        onSelect(choice)
                        expanded = false
                    },
                )
            }
            DropdownMenuItem(
                contentPadding = rowPadding,
                text = {
                    Text(
                        stringResource(R.string.reader_clef_reset),
                        style = MaterialTheme.typography.bodyMedium,
                    )
                },
                onClick = {
                    onReset()
                    expanded = false
                },
            )
        }
    }
}

@Composable
private fun CollapsibleHeader(title: String, expanded: Boolean, onToggle: () -> Unit) {
    Row(
        Modifier
            .fillMaxWidth()
            .clickable(onClick = onToggle)
            .padding(vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(title, Modifier.weight(1f), style = MaterialTheme.typography.titleSmall)
        Icon(
            if (expanded) Icons.Default.ExpandLess else Icons.Default.ExpandMore,
            contentDescription = if (expanded) "Collapse" else "Expand",
        )
    }
}

/** Map a [ClefChoice] to its localized display name. */
@Composable
private fun localizedClefLabel(choice: ClefChoice): String = stringResource(
    when (choice) {
        ClefChoice.TREBLE_G -> R.string.reader_clef_treble
        ClefChoice.TREBLE_G8VA -> R.string.reader_clef_treble8va
        ClefChoice.TREBLE_G8VB -> R.string.reader_clef_treble8vb
        ClefChoice.TREBLE_G15MA -> R.string.reader_clef_treble15ma
        ClefChoice.TREBLE_G15MB -> R.string.reader_clef_treble15mb
        ClefChoice.BASS_F -> R.string.reader_clef_bass
        ClefChoice.BASS_F8VA -> R.string.reader_clef_bass8va
        ClefChoice.BASS_F8VB -> R.string.reader_clef_bass8vb
        ClefChoice.SOPRANO_C1 -> R.string.reader_clef_soprano
        ClefChoice.ALTO_C3 -> R.string.reader_clef_alto
        ClefChoice.TENOR_C4 -> R.string.reader_clef_tenor
        ClefChoice.BARITONE_C5 -> R.string.reader_clef_baritone
        ClefChoice.PERCUSSION -> R.string.reader_clef_percussion
        ClefChoice.PERCUSSION2 -> R.string.reader_clef_percussion2
    },
)

/**
 * The bundled SMuFL music font (Bravura). The asset ships in the SheetMusicComposeAndroid
 * dependency at `fonts/Bravura.otf` and merges into the app's assets at build time, so the
 * library module resolves it at runtime via the app context's AssetManager.
 */
@Composable
private fun rememberMusicFont(): FontFamily {
    val ctx = LocalContext.current
    return remember(ctx) {
        FontFamily(Font(path = "fonts/Bravura.otf", assetManager = ctx.assets))
    }
}
