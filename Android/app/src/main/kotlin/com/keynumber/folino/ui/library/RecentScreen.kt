package com.keynumber.folino.ui.library

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Menu
import androidx.compose.material.icons.filled.MusicNote
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.keynumber.folino.R
import com.keynumber.folino.library.ScoreRowWire
import com.keynumber.folino.library.generated.LibraryAndroidStoreViewModel

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun RecentScreen(
    viewModel: LibraryAndroidStoreViewModel,
    onOpenScore: (ScoreRowWire) -> Unit,
    onOpenDrawer: () -> Unit,
) {
    val today by viewModel.recentToday.collectAsStateWithLifecycle()
    val thisWeek by viewModel.recentThisWeek.collectAsStateWithLifecycle()
    val earlier by viewModel.recentEarlier.collectAsStateWithLifecycle()

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(stringResource(R.string.nav_recent)) },
                navigationIcon = {
                    IconButton(onClick = onOpenDrawer) {
                        Icon(Icons.Filled.Menu, contentDescription = stringResource(R.string.nav_open_menu))
                    }
                },
            )
        },
    ) { padding ->
        if (today.isEmpty() && thisWeek.isEmpty() && earlier.isEmpty()) {
            Box(
                Modifier
                    .fillMaxSize()
                    .padding(padding),
                contentAlignment = Alignment.Center,
            ) {
                Text(stringResource(R.string.recent_empty), style = MaterialTheme.typography.bodyLarge)
            }
            return@Scaffold
        }
        LazyColumn(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding),
        ) {
            recentSection(R.string.recent_today, today, onOpenScore)
            recentSection(R.string.recent_this_week, thisWeek, onOpenScore)
            recentSection(R.string.recent_earlier, earlier, onOpenScore)
        }
    }
}

private fun LazyListScope.recentSection(
    headerRes: Int,
    rows: List<ScoreRowWire>,
    onOpenScore: (ScoreRowWire) -> Unit,
) {
    if (rows.isEmpty()) return
    item {
        Text(
            stringResource(headerRes),
            style = MaterialTheme.typography.titleSmall,
            modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
        )
    }
    items(rows, key = { it.id }) { row ->
        RecentScoreRow(row = row, onClick = { onOpenScore(row) })
    }
}

@Composable
private fun RecentScoreRow(
    row: ScoreRowWire,
    onClick: () -> Unit,
) {
    val title = row.title.ifEmpty { "Untitled" }
    val headline = if (row.subtitle.isEmpty()) title else "$title ${row.subtitle}"
    ListItem(
        headlineContent = { Text(headline) },
        supportingContent = { if (row.composer.isNotEmpty()) Text(row.composer) },
        leadingContent = { Icon(Icons.Filled.MusicNote, contentDescription = null) },
        modifier = Modifier.clickable(onClick = onClick),
    )
}
