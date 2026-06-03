@file:OptIn(ExperimentalMaterial3Api::class)

package com.keynumber.folino.ui.library

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ListItem
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.keynumber.folino.R
import com.keynumber.folino.library.ScoreExportFormatWire

private fun labelFor(token: String): Int = when (token) {
    "museScoreV4" -> R.string.export_format_musescore4
    "museScoreV3" -> R.string.export_format_musescore3
    "pdf" -> R.string.export_format_pdf
    "midi" -> R.string.export_format_midi
    "audioM4A" -> R.string.export_format_audio
    else -> R.string.export
}

@Composable
fun ExportFormatSheet(
    formats: List<ScoreExportFormatWire>,
    onPick: (token: String) -> Unit,
    onDismiss: () -> Unit,
) {
    ModalBottomSheet(onDismissRequest = onDismiss) {
        LazyColumn(
            Modifier
                .fillMaxWidth()
                .padding(bottom = 24.dp),
        ) {
            items(formats, key = { it.format }) { f ->
                ListItem(
                    headlineContent = { Text(stringResource(labelFor(f.format))) },
                    trailingContent = if (f.isOriginal) {
                        { Text(stringResource(R.string.export_original_badge)) }
                    } else {
                        null
                    },
                    modifier = Modifier.clickable { onPick(f.format) },
                )
            }
        }
    }
}
