package com.keynumber.folino.ui.library

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material3.Checkbox
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.ListItem
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.keynumber.folino.R
import com.keynumber.folino.library.generated.LibraryAndroidStoreViewModel

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun EditTagsSheet(
    viewModel: LibraryAndroidStoreViewModel,
    /** Non-null = single-score (live checkbox toggle); null = bulk (multi-select + Apply). */
    scoreId: String?,
    bulkScoreIds: List<String>,
    onDismiss: () -> Unit,
) {
    val picks by viewModel.editSheetTags.collectAsStateWithLifecycle()
    var showCreate by remember { mutableStateOf(false) }
    // Bulk-mode local selection (single mode toggles the store directly).
    val bulkSelected = remember { mutableStateListOf<String>() }

    ModalBottomSheet(onDismissRequest = onDismiss) {
        ListItem(
            headlineContent = { Text(stringResource(R.string.tags_create)) },
            leadingContent = { Icon(Icons.Filled.Add, contentDescription = null) },
            modifier = Modifier.clickable { showCreate = true },
        )
        LazyColumn(
            Modifier
                .fillMaxWidth()
                .padding(bottom = 8.dp),
        ) {
            items(picks, key = { it.id }) { pick ->
                if (scoreId != null) {
                    ListItem(
                        headlineContent = { Text(pick.name) },
                        trailingContent = { Checkbox(checked = pick.contains, onCheckedChange = null) },
                        modifier = Modifier.clickable {
                            viewModel.setTagAssigned(scoreId, pick.id, !pick.contains)
                        },
                    )
                } else {
                    val checked = bulkSelected.contains(pick.id)
                    ListItem(
                        headlineContent = { Text(pick.name) },
                        trailingContent = { Checkbox(checked = checked, onCheckedChange = null) },
                        modifier = Modifier.clickable {
                            if (checked) bulkSelected.remove(pick.id) else bulkSelected.add(pick.id)
                        },
                    )
                }
            }
        }
        if (scoreId == null) {
            Row(
                Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp, vertical = 8.dp),
                horizontalArrangement = Arrangement.End,
            ) {
                TextButton(
                    enabled = bulkSelected.isNotEmpty(),
                    onClick = {
                        // Union-add each selected tag across all selected scores.
                        bulkSelected.forEach { tagId -> viewModel.bulkAddTag(tagId, bulkScoreIds) }
                        onDismiss()
                    },
                ) {
                    Text(stringResource(R.string.edit_tags_apply))
                }
            }
        }
    }

    if (showCreate) {
        NameDialog(
            title = stringResource(R.string.tags_create),
            confirmLabel = stringResource(R.string.create),
            onConfirm = { name ->
                viewModel.createTag(name)
                showCreate = false
            },
            onDismiss = { showCreate = false },
        )
    }
}
