package com.keynumber.folino.ui.library

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Sort
import androidx.compose.material.icons.filled.Check
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.res.stringResource
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.keynumber.folino.R
import com.keynumber.folino.library.generated.LibraryAndroidStoreViewModel
import com.keynumber.folino.ui.settings.SettingsPrefs
import kotlinx.coroutines.launch

/**
 * The library sort orders, paired with their labels. The raw strings are Swift's
 * `Domain.ScoreItemSort` cases — Kotlin only names them, it never orders anything itself: the store
 * applies the shared comparators on the Swift side (see `LibraryAndroidStore.setSortOrder`).
 *
 * Ordered as iOS lists them in its sort menu.
 */
private val SORT_OPTIONS = listOf(
    "dateAddedDesc" to R.string.library_sort_by_date_added,
    "titleAsc" to R.string.library_sort_by_title,
    "composerAsc" to R.string.library_sort_by_composer,
    "lastOpenedDesc" to R.string.library_sort_by_last_opened,
)

/**
 * Top-bar sort control for the All / Favorites / Tag score lists: an overflow-style icon opening a
 * checkmark-free dropdown whose active row is the one the store reports.
 *
 * Android idiom rather than the iOS layout — a toolbar `DropdownMenu`, not a segmented picker in a
 * sheet — while the *content* (the four orders and their wording) matches iOS exactly.
 *
 * The choice round-trips through DataStore so it survives relaunch, matching iOS's
 * `LibrarySettingsKey.sortOrder`; the same key name is used on both platforms. Persisting is Kotlin's
 * job, applying it is Swift's.
 */
@Composable
internal fun SortMenuAction(
    viewModel: LibraryAndroidStoreViewModel,
    prefs: SettingsPrefs,
) {
    var expanded by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    val active by viewModel.sortOrder.collectAsStateWithLifecycle()

    IconButton(onClick = { expanded = true }) {
        Icon(
            Icons.AutoMirrored.Filled.Sort,
            contentDescription = stringResource(R.string.library_sort_menu),
        )
    }
    DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
        SORT_OPTIONS.forEach { (raw, labelRes) ->
            DropdownMenuItem(
                text = { Text(stringResource(labelRes)) },
                trailingIcon = {
                    if (raw == active) {
                        Icon(
                            Icons.Filled.Check,
                            contentDescription = null,
                        )
                    }
                },
                onClick = {
                    expanded = false
                    // Apply immediately (the store re-projects every list it governs), then persist.
                    viewModel.setSortOrder(raw)
                    scope.launch { prefs.setLibrarySortOrder(raw) }
                },
            )
        }
    }
}
