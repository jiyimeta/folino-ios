package com.keynumber.folino.ui.scoreinfo

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.keynumber.folino.R
import com.keynumber.folino.library.EditScoreInfoWire
import java.text.DateFormat
import java.util.Date

/** Immutable snapshot of the six editable fields; used for change detection. */
private data class CreditFields(
    val title: String,
    val subtitle: String,
    val composer: String,
    val arranger: String,
    val lyricist: String,
    val copyright: String,
)

private fun EditScoreInfoWire.toFields() =
    CreditFields(title, subtitle, composer, arranger, lyricist, copyright)

/** Output payload handed to the wirelet `saveScoreInfo` call. */
data class CreditFieldsOut(
    val title: String,
    val subtitle: String,
    val composer: String,
    val arranger: String,
    val lyricist: String,
    val copyright: String,
)

/**
 * Material full-screen edit screen for a score's credit metadata. Loads the pre-filled snapshot via [load], persists
 * via [onSave]. Explicit Save (disabled on blank title); unsaved exit prompts a discard dialog. Mirrors iOS content;
 * Android placement (top-app-bar Save/Close, full-screen destination).
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun EditScoreInfoScreen(
    load: () -> EditScoreInfoWire,
    onSave: (CreditFieldsOut) -> Unit,
    onClose: () -> Unit,
) {
    val initial = remember { load() }
    val baseline = remember { initial.toFields() }

    var title by remember { mutableStateOf(initial.title) }
    var subtitle by remember { mutableStateOf(initial.subtitle) }
    var composer by remember { mutableStateOf(initial.composer) }
    var arranger by remember { mutableStateOf(initial.arranger) }
    var lyricist by remember { mutableStateOf(initial.lyricist) }
    var copyright by remember { mutableStateOf(initial.copyright) }
    var showDiscard by remember { mutableStateOf(false) }

    val current = CreditFields(title, subtitle, composer, arranger, lyricist, copyright)
    val hasChanges = current != baseline
    val canSave = title.isNotBlank()

    fun attemptClose() {
        if (hasChanges) showDiscard = true else onClose()
    }

    BackHandler(enabled = true) { attemptClose() }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(stringResource(R.string.edit_info)) },
                navigationIcon = {
                    IconButton(onClick = { attemptClose() }) {
                        Icon(Icons.Filled.Close, contentDescription = stringResource(R.string.edit_info_close))
                    }
                },
                actions = {
                    TextButton(
                        enabled = canSave,
                        onClick = {
                            onSave(
                                CreditFieldsOut(
                                    title = title, subtitle = subtitle, composer = composer,
                                    arranger = arranger, lyricist = lyricist, copyright = copyright,
                                ),
                            )
                            onClose()
                        },
                    ) { Text(stringResource(R.string.edit_info_save)) }
                },
            )
        },
    ) { padding ->
        Column(
            Modifier
                .fillMaxSize()
                .padding(padding)
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 16.dp),
        ) {
            SectionHeader(stringResource(R.string.edit_info_section_credits))
            Field(stringResource(R.string.edit_info_field_title), title, singleLine = true) { title = it }
            Field(stringResource(R.string.edit_info_field_subtitle), subtitle, singleLine = true) { subtitle = it }
            Field(stringResource(R.string.edit_info_field_composer), composer, singleLine = true) { composer = it }
            Field(stringResource(R.string.edit_info_field_arranger), arranger, singleLine = true) { arranger = it }
            Field(stringResource(R.string.edit_info_field_lyricist), lyricist, singleLine = true) { lyricist = it }
            Field(stringResource(R.string.edit_info_field_copyright), copyright, singleLine = false) { copyright = it }

            Spacer(Modifier.height(16.dp))
            SectionHeader(stringResource(R.string.edit_info_section_info))
            ReadOnlyRow(
                stringResource(R.string.edit_info_info_source),
                initial.source.ifBlank { stringResource(R.string.edit_info_source_unknown) },
            )
            if (initial.addedAt > 0) {
                ReadOnlyRow(
                    stringResource(R.string.edit_info_info_date_added),
                    DateFormat.getDateInstance().format(Date((initial.addedAt * 1000).toLong())),
                )
            }
            Spacer(Modifier.height(24.dp))
        }
    }

    if (showDiscard) {
        AlertDialog(
            onDismissRequest = { showDiscard = false },
            title = { Text(stringResource(R.string.edit_info_discard_title)) },
            confirmButton = {
                TextButton(onClick = { showDiscard = false; onClose() }) {
                    Text(stringResource(R.string.edit_info_discard_confirm))
                }
            },
            dismissButton = {
                TextButton(onClick = { showDiscard = false }) {
                    Text(stringResource(R.string.edit_info_discard_keep))
                }
            },
        )
    }
}

@Composable
private fun SectionHeader(text: String) {
    Spacer(Modifier.height(8.dp))
    Text(text, style = MaterialTheme.typography.labelLarge)
    HorizontalDivider(Modifier.padding(vertical = 4.dp))
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun Field(label: String, value: String, singleLine: Boolean, onChange: (String) -> Unit) {
    OutlinedTextField(
        value = value,
        onValueChange = onChange,
        label = { Text(label) },
        singleLine = singleLine,
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 4.dp),
    )
}

@Composable
private fun ReadOnlyRow(label: String, value: String) {
    ListItem(
        headlineContent = { Text(label) },
        trailingContent = { Text(value, textAlign = TextAlign.End) },
    )
}
