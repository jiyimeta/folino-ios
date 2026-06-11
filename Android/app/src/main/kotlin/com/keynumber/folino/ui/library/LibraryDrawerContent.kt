package com.keynumber.folino.ui.library

import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.QueueMusic
import androidx.compose.material.icons.automirrored.outlined.Label
import androidx.compose.material.icons.filled.BugReport
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.LibraryMusic
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Star
import androidx.compose.material.icons.outlined.History
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalDrawerSheet
import androidx.compose.material3.NavigationDrawerItem
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.keynumber.folino.BuildConfig
import com.keynumber.folino.R

// The navigation drawer (sidebar) body, extracted from MainActivity so both the production
// `ModalNavigationDrawer` and the marketing screenshot scene render the *same* component.
// Mirrors the `DisplayInspectorContent` / `ReaderTopBar` extractions: production behavior is
// unchanged because `showDebug` defaults to `BuildConfig.DEBUG`, preserving the debug-only entry
// in debug builds. The screenshot capture passes `showDebug = false` to hide it from marketing.
@Composable
fun LibraryDrawerContent(
    currentRoute: String?,
    onNavigate: (String) -> Unit,
    onOpenSettings: () -> Unit,
    showDebug: Boolean = BuildConfig.DEBUG,
    onOpenDebug: () -> Unit = {},
) {
    ModalDrawerSheet {
        Spacer(Modifier.height(12.dp))
        Text(
            stringResource(R.string.library_title),
            style = MaterialTheme.typography.titleLarge,
            modifier = Modifier.padding(horizontal = 28.dp, vertical = 16.dp),
        )
        NavigationDrawerItem(
            icon = { Icon(Icons.Filled.LibraryMusic, contentDescription = null) },
            label = { Text(stringResource(R.string.nav_all_scores)) },
            selected = currentRoute == "list",
            onClick = { onNavigate("list") },
            modifier = Modifier.padding(horizontal = 12.dp),
        )
        NavigationDrawerItem(
            icon = { Icon(Icons.Outlined.History, contentDescription = null) },
            label = { Text(stringResource(R.string.nav_recent)) },
            selected = currentRoute == "recent",
            onClick = { onNavigate("recent") },
            modifier = Modifier.padding(horizontal = 12.dp),
        )
        NavigationDrawerItem(
            icon = { Icon(Icons.Filled.Star, contentDescription = null) },
            label = { Text(stringResource(R.string.nav_favorites)) },
            selected = currentRoute == "favorites",
            onClick = { onNavigate("favorites") },
            modifier = Modifier.padding(horizontal = 12.dp),
        )
        NavigationDrawerItem(
            icon = { Icon(Icons.AutoMirrored.Filled.QueueMusic, contentDescription = null) },
            label = { Text(stringResource(R.string.nav_playlists)) },
            selected = currentRoute == "playlists",
            onClick = { onNavigate("playlists") },
            modifier = Modifier.padding(horizontal = 12.dp),
        )
        NavigationDrawerItem(
            icon = { Icon(Icons.AutoMirrored.Outlined.Label, contentDescription = null) },
            label = { Text(stringResource(R.string.nav_tags)) },
            selected = currentRoute == "tags",
            onClick = { onNavigate("tags") },
            modifier = Modifier.padding(horizontal = 12.dp),
        )
        NavigationDrawerItem(
            icon = { Icon(Icons.Filled.Delete, contentDescription = null) },
            label = { Text(stringResource(R.string.library_recently_deleted)) },
            selected = currentRoute == "recentlyDeleted",
            onClick = { onNavigate("recentlyDeleted") },
            modifier = Modifier.padding(horizontal = 12.dp),
        )
        HorizontalDivider(Modifier.padding(vertical = 8.dp))
        NavigationDrawerItem(
            icon = { Icon(Icons.Filled.Settings, contentDescription = null) },
            label = { Text(stringResource(R.string.nav_settings)) },
            selected = false,
            onClick = onOpenSettings,
            modifier = Modifier.padding(horizontal = 12.dp),
        )
        // Debug-only entry to the Crashlytics test menu. Compiled out of release builds and hidden
        // when `showDebug` is false (e.g. the marketing screenshot capture).
        if (showDebug) {
            NavigationDrawerItem(
                icon = { Icon(Icons.Filled.BugReport, contentDescription = null) },
                label = { Text("Debug menu") },
                selected = currentRoute == "debug",
                onClick = onOpenDebug,
                modifier = Modifier.padding(horizontal = 12.dp),
            )
        }
    }
}
