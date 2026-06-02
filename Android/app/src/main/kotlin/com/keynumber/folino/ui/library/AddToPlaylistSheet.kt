package com.keynumber.folino.ui.library

import androidx.compose.foundation.clickable
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
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
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
fun AddToPlaylistSheet(
    viewModel: LibraryAndroidStoreViewModel,
    /** Non-null = single-score (checkbox toggle); null = bulk (tap-to-add). */
    scoreId: String?,
    bulkScoreIds: List<String>,
    onDismiss: () -> Unit,
) {
    val picks by viewModel.addSheetPlaylists.collectAsStateWithLifecycle()
    var showCreate by remember { mutableStateOf(false) }

    ModalBottomSheet(onDismissRequest = onDismiss) {
        ListItem(
            headlineContent = { Text(stringResource(R.string.playlists_create)) },
            leadingContent = { Icon(Icons.Filled.Add, contentDescription = null) },
            modifier = Modifier.clickable { showCreate = true },
        )
        LazyColumn(
            Modifier
                .fillMaxWidth()
                .padding(bottom = 24.dp),
        ) {
            items(picks, key = { it.id }) { pick ->
                if (scoreId != null) {
                    ListItem(
                        headlineContent = { Text(pick.name) },
                        trailingContent = { Checkbox(checked = pick.contains, onCheckedChange = null) },
                        modifier = Modifier.clickable {
                            if (pick.contains) {
                                viewModel.removeFromPlaylist(scoreId, pick.id)
                            } else {
                                viewModel.addToPlaylist(scoreId, pick.id)
                            }
                        },
                    )
                } else {
                    ListItem(
                        headlineContent = { Text(pick.name) },
                        modifier = Modifier.clickable {
                            viewModel.bulkAddToPlaylist(pick.id, bulkScoreIds)
                            onDismiss()
                        },
                    )
                }
            }
        }
    }

    if (showCreate) {
        NameDialog(
            title = stringResource(R.string.playlists_create),
            confirmLabel = stringResource(R.string.create),
            onConfirm = { name ->
                val ids = if (scoreId != null) listOf(scoreId) else bulkScoreIds
                viewModel.createPlaylistWithScores(name, ids)
                showCreate = false
                onDismiss()
            },
            onDismiss = { showCreate = false },
        )
    }
}
