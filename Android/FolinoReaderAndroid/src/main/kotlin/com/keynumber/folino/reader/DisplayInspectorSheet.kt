package com.keynumber.folino.reader

import android.graphics.Paint
import android.graphics.Typeface
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AutoStories
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.SwapHoriz
import androidx.compose.material.icons.filled.SwapVert
import androidx.compose.material.icons.filled.UnfoldMore
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
import androidx.compose.material3.SheetState
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
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.drawIntoCanvas
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.layout.layout
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.keynumber.folino.reader.ui.CollapsibleHeader
import com.keynumber.folino.reader.ui.InspectorRow
import com.keynumber.folino.reader.ui.InspectorSliderHeight
import kotlin.math.roundToInt

/**
 * Vertical inset by which the (deliberately tall) clef tile under-reports its layout height, so the
 * Parts rows stay compact even though each tile is sized to clear its octave numerals. The popup
 * tiles add an equal `padding(vertical = clefTileInset)` to keep the glyph inside their border.
 */
private val clefTileInset = 11.dp

/**
 * Compose analogue of SwiftUI `.padding(.vertical, -inset)`: the content is still measured and drawn
 * at its full height, but reports `2 * inset` less to its parent and is offset up by `inset`. A clef
 * tile tall enough to show its "8" / "15" octave numerals thus occupies a compact row, drawing its
 * overflow into the surrounding space instead of inflating every Parts row. Must sit inside a parent
 * that does not clip (the trigger uses a plain `clickable` row, not a `TextButton`, for this reason).
 */
private fun Modifier.negativeVerticalPadding(inset: Dp) = layout { measurable, constraints ->
    val placeable = measurable.measure(constraints)
    val dy = inset.roundToPx()
    val height = (placeable.height - dy * 2).coerceAtLeast(0)
    layout(placeable.width, height) { placeable.place(0, -dy) }
}

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
    showSeekBar: Boolean = true,
    onShowSeekBarChange: (Boolean) -> Unit = {},
    transposeSemitones: Int = 0,
    onTransposeChange: (Int) -> Unit = {},
) {
    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState) {
        DisplayInspectorContent(
            options = options,
            parts = parts,
            onChange = onChange,
            showSeekBar = showSeekBar,
            onShowSeekBarChange = onShowSeekBarChange,
            transposeSemitones = transposeSemitones,
            onTransposeChange = onTransposeChange,
        )
    }
}

/**
 * The scrollable body of the display inspector, factored out of [DisplayInspectorSheet] so the same
 * control list can be hosted either inside the production `ModalBottomSheet` or — for static capture
 * harnesses, which can't render a separate sheet window into a node bitmap — directly in a plain
 * surface. The sheet wrapper owns the modal chrome; this composable owns only the control rows.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DisplayInspectorContent(
    options: LayoutOptions,
    parts: List<PartDescriptor>,
    onChange: (LayoutOptions) -> Unit,
    modifier: Modifier = Modifier,
    showSeekBar: Boolean = true,
    onShowSeekBarChange: (Boolean) -> Unit = {},
    initialGeneralExpanded: Boolean = true,
    initialPartsExpanded: Boolean = true,
    transposeSemitones: Int = 0,
    onTransposeChange: (Int) -> Unit = {},
) {
    var generalExpanded by rememberSaveable { mutableStateOf(initialGeneralExpanded) }
    var partsExpanded by rememberSaveable { mutableStateOf(initialPartsExpanded) }
    val typeface = rememberBravuraTypeface()
    LazyColumn(
        modifier
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
                item { StaffSizeRow(options.staffSize) { onChange(options.copy(staffSize = it)) } }
                item {
                    TransposeRow(
                        semitones = transposeSemitones,
                        enabled = true,
                        onChange = onTransposeChange,
                        showLeadingIcon = false,
                    )
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
                item {
                    SwitchRow(
                        label = stringResource(R.string.reader_pref_show_seek_bar),
                        checked = showSeekBar,
                    ) { onShowSeekBarChange(it) }
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
                parts.forEachIndexed { index, part ->
                    item(key = "part-$index") {
                        PartRow(
                            part = part,
                            options = options,
                            typeface = typeface,
                            onChange = onChange,
                        )
                    }
                }
            }
        }
}

@Composable
private fun LayoutModeRow(mode: ReaderLayoutMode, onSelect: (ReaderLayoutMode) -> Unit) {
    val modes = listOf(
        Triple(ReaderLayoutMode.VERTICAL, R.string.reader_layout_vertical, Icons.Default.SwapVert),
        Triple(ReaderLayoutMode.HORIZONTAL, R.string.reader_layout_horizontal, Icons.Default.SwapHoriz),
        Triple(ReaderLayoutMode.PAGE, R.string.reader_layout_page, Icons.Default.AutoStories),
    )
    var expanded by remember { mutableStateOf(false) }
    val current = modes.first { it.first == mode }
    InspectorRow(label = stringResource(R.string.reader_display_mode)) {
        Box {
            // Trigger mirrors the clef picker: a plain clickable row (icon + label + chevron) that
            // opens an anchored DropdownMenu — the Android equivalent of the iOS layout-mode picker.
            Row(
                Modifier.clickable { expanded = true }.padding(horizontal = 4.dp, vertical = 4.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                Icon(current.third, contentDescription = null, modifier = Modifier.size(20.dp))
                Text(stringResource(current.second), style = MaterialTheme.typography.bodyMedium)
                Icon(Icons.Default.UnfoldMore, contentDescription = null, modifier = Modifier.size(16.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
                modes.forEach { (m, labelRes, icon) ->
                    DropdownMenuItem(
                        text = { Text(stringResource(labelRes)) },
                        leadingIcon = {
                            Icon(icon, contentDescription = null, modifier = Modifier.size(20.dp))
                        },
                        trailingIcon = if (m == mode) {
                            { Icon(Icons.Default.Check, contentDescription = null, modifier = Modifier.size(18.dp)) }
                        } else {
                            null
                        },
                        onClick = {
                            onSelect(m)
                            expanded = false
                        },
                    )
                }
            }
        }
    }
}

@Composable
private fun StaffSizeRow(staffSize: Double, onChange: (Double) -> Unit) {
    Row(
        Modifier.fillMaxWidth(),
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
            modifier = Modifier.weight(1f).height(InspectorSliderHeight),
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
    InspectorRow(label = label) {
        Switch(checked = checked, onCheckedChange = onCheckedChange)
    }
}

/**
 * One part: its name on the left, a right-aligned column of per-staff [clef, visibility] rows.
 * Mirrors the iOS `VisualInspectorScreen` Parts layout (HStack { Text(name); VStack { staffRows } }).
 */
@Composable
private fun PartRow(
    part: PartDescriptor,
    options: LayoutOptions,
    typeface: Typeface,
    onChange: (LayoutOptions) -> Unit,
) {
    Row(
        Modifier.fillMaxWidth().padding(vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            part.name.ifEmpty { stringResource(R.string.reader_part_untitled) },
            modifier = Modifier.weight(1f),
            style = MaterialTheme.typography.bodyMedium,
        )
        Column(
            horizontalAlignment = Alignment.End,
            verticalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            part.staves.forEach { staff ->
                StaffControls(staff, options, typeface, onChange)
            }
        }
    }
}

/** Per-staff clef picker + visibility toggle, sized to wrap content (right-aligned in [PartRow]). */
@Composable
private fun StaffControls(
    staff: StaffDescriptor,
    options: LayoutOptions,
    typeface: Typeface,
    onChange: (LayoutOptions) -> Unit,
) {
    // Mirror iOS `LayoutSettingsModel.effectiveClef`: a staff with no authored opening clef (the
    // JNI descriptor encodes that as an empty rawType) falls back to treble "G", matching what the
    // layout engine synthesizes for such a staff. Without this the trigger would render blank.
    val effectiveRaw =
        options.clefOverrides[staff.address] ?: staff.defaultClefRawType.ifEmpty { "G" }
    val hasOverride = staff.address in options.clefOverrides
    val hidden = staff.address in options.hiddenStaves
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        ClefGlyphPicker(
            currentRaw = effectiveRaw,
            hasOverride = hasOverride,
            typeface = typeface,
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
 * One clef "tile": a 5-line staff with the SMuFL glyph drawn at the staff line it anchors to.
 * The staff background plus the anchor position are what distinguish the C-clef family (Soprano /
 * Alto / Tenor / Baritone all share the cClef glyph). Mirrors the iOS ClefMenu tile. Drawn small
 * via a native Canvas so the glyph's own large vertical metrics don't bloat the layout box.
 */
@Composable
private fun ClefTile(
    choice: ClefChoice,
    typeface: Typeface,
    modifier: Modifier = Modifier,
    glyphColor: Color = MaterialTheme.colorScheme.onSurface,
) {
    val lineColor = MaterialTheme.colorScheme.onSurfaceVariant
    // Height must clear the glyph's full ink box, not just the 5-line staff: octave clefs draw an
    // "8" / "15" above (8va/15ma) or below (8vb/15mb) the clef, so a box only as tall as the staff
    // clips them. The staff stays vertically centered (see staffTop below), giving symmetric room
    // for the octave numerals. Mirrors the iOS ClefMenu tile (40×52pt). [negativeVerticalPadding]
    // then claws back the extra height from the layout footprint so the Parts rows stay compact —
    // the Compose equivalent of the iOS tile's `.padding(.vertical, -8)`.
    Canvas(
        modifier
            .negativeVerticalPadding(clefTileInset)
            .size(width = 36.dp, height = 60.dp),
    ) {
        val sp = 5.dp.toPx()
        val staffHeight = sp * 4 // 5 lines = 4 spaces
        val staffTop = (size.height - staffHeight) / 2f
        for (i in 0..4) {
            val y = staffTop + sp * i
            drawLine(lineColor, Offset(0f, y), Offset(size.width, y), strokeWidth = 1f)
        }
        // Anchor: +Y is downward from the middle line; mirrors iOS ClefMenu's yOffset table.
        val middleY = staffTop + sp * 2
        val centerY = middleY + choice.anchorFromMiddleSp * sp
        val paint = Paint().apply {
            isAntiAlias = true
            this.typeface = typeface
            textSize = sp * 4 // SMuFL em = 4 staff spaces, so one space matches the drawn staff
            color = glyphColor.toArgb()
            textAlign = Paint.Align.CENTER
        }
        val fm = paint.fontMetrics
        // Center the glyph box on centerY (matches iOS's anchor: .center) by deriving the baseline.
        val baseline = centerY - (fm.ascent + fm.descent) / 2f
        drawIntoCanvas {
            it.nativeCanvas.drawText(
                String(Character.toChars(choice.glyph)),
                size.width / 2f,
                baseline,
                paint,
            )
        }
    }
}

/**
 * Per-staff clef picker. The trigger shows only the current clef glyph tile plus an up/down
 * chevron (no textual name); tapping opens an anchored [DropdownMenu] — the Android equivalent of
 * the iOS `.popover` — holding family-grouped rows of horizontally-scrolling clef tiles. Pitched
 * staves show treble / bass / C families (with dividers); a percussion staff shows only the
 * percussion family, mirroring iOS `ClefMenu`. The selected tile is highlighted, and a reset row
 * appears only when this staff has an explicit override.
 */
@Composable
private fun ClefGlyphPicker(
    currentRaw: String,
    hasOverride: Boolean,
    typeface: Typeface,
    modifier: Modifier = Modifier,
    onSelect: (ClefChoice) -> Unit,
    onReset: () -> Unit,
) {
    var expanded by remember { mutableStateOf(false) }
    val currentChoice = ClefChoice.fromRawType(currentRaw)
    val isPercussion = currentChoice?.isPercussion == true
    // Tint the trigger glyph with the accent color while an override is active (iOS parity).
    val triggerTint =
        if (hasOverride) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurface
    Box(modifier) {
        // A plain clickable row (not a TextButton) so the tile's octave-numeral overflow is not
        // clipped to a button surface; see [negativeVerticalPadding].
        Row(
            Modifier
                .clickable { expanded = true }
                .padding(horizontal = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            if (currentChoice != null) {
                ClefTile(choice = currentChoice, typeface = typeface, glyphColor = triggerTint)
            } else {
                Text(
                    text = currentRaw,
                    style = MaterialTheme.typography.bodyMedium,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            Icon(
                Icons.Default.UnfoldMore,
                contentDescription = stringResource(R.string.reader_clef_choose),
                modifier = Modifier.size(16.dp),
            )
        }
        DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            Column(Modifier.width(264.dp).padding(vertical = 4.dp)) {
                // Percussion staves stay on percussion clefs and pitched staves on pitched clefs;
                // mixing the two would engrave nonsense, so each staff only sees its own family set.
                if (isPercussion) {
                    ClefTileRow(ClefChoice.percussionFamily, currentRaw, typeface) {
                        onSelect(it)
                        expanded = false
                    }
                } else {
                    ClefTileRow(ClefChoice.trebleFamily, currentRaw, typeface) {
                        onSelect(it)
                        expanded = false
                    }
                    HorizontalDivider(Modifier.padding(vertical = 4.dp))
                    ClefTileRow(ClefChoice.bassFamily, currentRaw, typeface) {
                        onSelect(it)
                        expanded = false
                    }
                    HorizontalDivider(Modifier.padding(vertical = 4.dp))
                    ClefTileRow(ClefChoice.cFamily, currentRaw, typeface) {
                        onSelect(it)
                        expanded = false
                    }
                }
                if (hasOverride) {
                    HorizontalDivider(Modifier.padding(vertical = 4.dp))
                    TextButton(
                        onClick = {
                            onReset()
                            expanded = false
                        },
                        modifier = Modifier.padding(horizontal = 12.dp),
                    ) {
                        Text(
                            stringResource(R.string.reader_clef_reset),
                            style = MaterialTheme.typography.bodyMedium,
                        )
                    }
                }
            }
        }
    }
}

/**
 * One family's clef tiles in a horizontally-scrolling row (mirrors the iOS popover's per-family
 * `ScrollView(.horizontal)`). The currently-selected tile gets an accent border + fill.
 */
@Composable
private fun ClefTileRow(
    choices: List<ClefChoice>,
    currentRaw: String,
    typeface: Typeface,
    onSelect: (ClefChoice) -> Unit,
) {
    Row(
        Modifier
            .horizontalScroll(rememberScrollState())
            .padding(horizontal = 12.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        choices.forEach { choice ->
            val isCurrent = choice.rawType == currentRaw
            val label = localizedClefLabel(choice)
            val borderColor =
                if (isCurrent) {
                    MaterialTheme.colorScheme.primary
                } else {
                    MaterialTheme.colorScheme.outline.copy(alpha = 0.3f)
                }
            val background =
                if (isCurrent) {
                    MaterialTheme.colorScheme.primary.copy(alpha = 0.18f)
                } else {
                    Color.Transparent
                }
            ClefTile(
                choice = choice,
                typeface = typeface,
                modifier = Modifier
                    .clip(RoundedCornerShape(6.dp))
                    .clickable { onSelect(choice) }
                    .semantics { contentDescription = label }
                    .background(background)
                    .border(
                        width = if (isCurrent) 2.dp else 1.dp,
                        color = borderColor,
                        shape = RoundedCornerShape(6.dp),
                    )
                    // Add back the height [ClefTile] withholds via negativeVerticalPadding so the
                    // octave numerals stay inside this tile's border (mirrors iOS tile padding).
                    .padding(horizontal = 4.dp, vertical = clefTileInset),
            )
        }
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
 * The bundled SMuFL music typeface (Bravura). The asset ships in the SheetMusicComposeAndroid
 * dependency at `fonts/Bravura.otf` and merges into the app's assets at build time, so the
 * library module resolves it at runtime via the app context's AssetManager. Returned as an
 * android.graphics.Typeface so the clef tiles can draw glyphs through a native Canvas.
 */
@Composable
private fun rememberBravuraTypeface(): Typeface {
    val ctx = LocalContext.current
    return remember(ctx) {
        Typeface.createFromAsset(ctx.assets, "fonts/Bravura.otf")
    }
}
