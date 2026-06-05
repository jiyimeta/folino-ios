package com.keynumber.folino.ui.library

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.automirrored.outlined.Label
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.keynumber.folino.R
import com.keynumber.folino.library.ScoreRowWire
import com.keynumber.folino.library.generated.LibraryAndroidStoreViewModel

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TagDetailScreen(
    viewModel: LibraryAndroidStoreViewModel,
    tagId: String,
    tagName: String,
    onOpenScore: (ScoreRowWire) -> Unit,
    onBack: () -> Unit,
) {
    LaunchedEffect(tagId) { viewModel.selectTag(tagId) }
    val items by viewModel.selectedTagItems.collectAsStateWithLifecycle()
    var searchQuery by remember { mutableStateOf("") }
    LaunchedEffect(searchQuery) { viewModel.setSearchQuery(searchQuery) }
    androidx.compose.runtime.DisposableEffect(Unit) { onDispose { viewModel.setSearchQuery("") } }

    var showRename by remember { mutableStateOf(false) }
    var showDelete by remember { mutableStateOf(false) }
    var menu by remember { mutableStateOf(false) }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(tagName) },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = stringResource(R.string.cancel))
                    }
                },
                actions = {
                    Box {
                        IconButton(onClick = { menu = true }) {
                            Icon(Icons.Filled.MoreVert, contentDescription = stringResource(R.string.more))
                        }
                        DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                            DropdownMenuItem(
                                text = { Text(stringResource(R.string.tags_rename)) },
                                onClick = {
                                    menu = false
                                    showRename = true
                                },
                            )
                            DropdownMenuItem(
                                text = { Text(stringResource(R.string.tags_delete)) },
                                onClick = {
                                    menu = false
                                    showDelete = true
                                },
                            )
                        }
                    }
                },
            )
        },
    ) { padding ->
        androidx.compose.foundation.layout.Column(
            Modifier
                .padding(padding)
                .fillMaxSize(),
        ) {
            LibrarySearchField(query = searchQuery, onQueryChange = { searchQuery = it })
            if (items.isEmpty()) {
                Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    Text(
                        stringResource(
                            if (searchQuery.isBlank()) R.string.tags_empty_hint else R.string.search_no_results,
                        ),
                        style = MaterialTheme.typography.bodyMedium,
                    )
                }
            } else {
                LazyColumn(Modifier.fillMaxSize()) {
                    items(items, key = { it.id }) { row ->
                        var rowMenu by remember { mutableStateOf(false) }
                        val title = row.title.ifEmpty { "Untitled" }
                        val headline = if (row.subtitle.isEmpty()) title else "$title ${row.subtitle}"
                        ListItem(
                            headlineContent = { Text(headline) },
                            supportingContent = { if (row.composer.isNotEmpty()) Text(row.composer) },
                            leadingContent = { Icon(Icons.AutoMirrored.Outlined.Label, contentDescription = null) },
                            trailingContent = {
                                Box {
                                    IconButton(onClick = { rowMenu = true }) {
                                        Icon(Icons.Filled.MoreVert, contentDescription = stringResource(R.string.more))
                                    }
                                    DropdownMenu(expanded = rowMenu, onDismissRequest = { rowMenu = false }) {
                                        DropdownMenuItem(
                                            text = { Text(stringResource(R.string.tag_remove_from)) },
                                            onClick = {
                                                rowMenu = false
                                                viewModel.setTagAssigned(row.id, tagId, false)
                                            },
                                        )
                                    }
                                }
                            },
                            modifier = Modifier.clickable { onOpenScore(row) },
                        )
                    }
                }
            }
        }
    }

    if (showRename) {
        NameDialog(
            title = stringResource(R.string.tags_rename),
            confirmLabel = stringResource(R.string.rename),
            initial = tagName,
            nameHint = R.string.tags_name_hint,
            onConfirm = { name ->
                viewModel.renameTag(tagId, name)
                showRename = false
            },
            onDismiss = { showRename = false },
        )
    }
    if (showDelete) {
        AlertDialog(
            onDismissRequest = { showDelete = false },
            title = { Text(stringResource(R.string.tags_delete_confirm_title, tagName)) },
            text = { Text(stringResource(R.string.tags_delete_confirm_message)) },
            confirmButton = {
                TextButton(onClick = {
                    viewModel.deleteTag(tagId)
                    showDelete = false
                    onBack()
                }) {
                    Text(stringResource(R.string.tags_delete))
                }
            },
            dismissButton = { TextButton(onClick = { showDelete = false }) { Text(stringResource(R.string.cancel)) } },
        )
    }
}
