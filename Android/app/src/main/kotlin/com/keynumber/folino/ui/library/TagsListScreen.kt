package com.keynumber.folino.ui.library

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Menu
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.automirrored.outlined.Label
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FloatingActionButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.keynumber.folino.R
import com.keynumber.folino.library.TagRowWire
import com.keynumber.folino.library.generated.LibraryAndroidStoreViewModel

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TagsListScreen(
    viewModel: LibraryAndroidStoreViewModel,
    onOpenTag: (String, String) -> Unit,
    onOpenDrawer: () -> Unit,
) {
    val tags by viewModel.tags.collectAsStateWithLifecycle()
    var showCreate by remember { mutableStateOf(false) }
    var pendingDelete by remember { mutableStateOf<TagRowWire?>(null) }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(stringResource(R.string.tags_title)) },
                navigationIcon = {
                    IconButton(onClick = onOpenDrawer) {
                        Icon(Icons.Filled.Menu, contentDescription = stringResource(R.string.nav_open_menu))
                    }
                },
            )
        },
        floatingActionButton = {
            FloatingActionButton(onClick = { showCreate = true }) {
                Icon(Icons.Filled.Add, contentDescription = stringResource(R.string.tags_create))
            }
        },
    ) { padding ->
        if (tags.isEmpty()) {
            Box(
                Modifier
                    .padding(padding)
                    .fillMaxSize(),
                contentAlignment = Alignment.Center,
            ) {
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    Text(stringResource(R.string.tags_empty_title), style = MaterialTheme.typography.titleMedium)
                    Text(stringResource(R.string.tags_empty_hint), style = MaterialTheme.typography.bodyMedium)
                }
            }
        } else {
            LazyColumn(
                Modifier
                    .padding(padding)
                    .fillMaxSize(),
            ) {
                items(tags, key = { it.id }) { row ->
                    TagRow(
                        row = row,
                        onClick = { onOpenTag(row.id, row.name) },
                        onRequestDelete = { pendingDelete = row },
                    )
                }
            }
        }
    }

    if (showCreate) {
        NameDialog(
            title = stringResource(R.string.tags_create),
            confirmLabel = stringResource(R.string.create),
            nameHint = R.string.tags_name_hint,
            onConfirm = { name ->
                viewModel.createTag(name)
                showCreate = false
            },
            onDismiss = { showCreate = false },
        )
    }

    pendingDelete?.let { row ->
        AlertDialog(
            onDismissRequest = { pendingDelete = null },
            title = { Text(stringResource(R.string.tags_delete_confirm_title, row.name)) },
            text = { Text(stringResource(R.string.tags_delete_confirm_message)) },
            confirmButton = {
                TextButton(onClick = {
                    viewModel.deleteTag(row.id)
                    pendingDelete = null
                }) {
                    Text(stringResource(R.string.tags_delete))
                }
            },
            dismissButton = {
                TextButton(onClick = { pendingDelete = null }) { Text(stringResource(R.string.cancel)) }
            },
        )
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun TagRow(row: TagRowWire, onClick: () -> Unit, onRequestDelete: () -> Unit) {
    var menu by remember { mutableStateOf(false) }
    ListItem(
        headlineContent = { Text(row.name.ifEmpty { "Untitled" }) },
        supportingContent = { Text(stringResource(R.string.tags_member_count, row.memberCount)) },
        leadingContent = { Icon(Icons.AutoMirrored.Outlined.Label, contentDescription = null) },
        trailingContent = {
            Box {
                IconButton(onClick = { menu = true }) {
                    Icon(Icons.Filled.MoreVert, contentDescription = stringResource(R.string.more))
                }
                DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                    DropdownMenuItem(
                        text = { Text(stringResource(R.string.tags_delete)) },
                        onClick = {
                            menu = false
                            onRequestDelete()
                        },
                    )
                }
            }
        },
        modifier = Modifier.clickable(onClick = onClick),
    )
}
