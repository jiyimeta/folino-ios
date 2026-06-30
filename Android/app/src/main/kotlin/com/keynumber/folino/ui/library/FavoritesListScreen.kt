package com.keynumber.folino.ui.library

import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.keynumber.folino.R
import com.keynumber.folino.library.ScoreRowWire
import com.keynumber.folino.library.generated.LibraryAndroidStoreViewModel

/**
 * Favorites screen — the same scores list surface as All Scores, fed by the
 * store's `favorites` flow and without the import FAB.
 */
@Composable
fun FavoritesListScreen(
    viewModel: LibraryAndroidStoreViewModel,
    onOpenScore: (ScoreRowWire) -> Unit,
    onOpenDrawer: () -> Unit,
    onEditInfoForScore: (String) -> Unit,
) {
    val favorites by viewModel.favorites.collectAsStateWithLifecycle()
    ScoreListScaffold(
        viewModel = viewModel,
        scores = favorites,
        titleRes = R.string.nav_favorites,
        emptyTitleRes = R.string.favorites_empty_title,
        emptyHintRes = R.string.favorites_empty_hint,
        listSource = "favorites",
        onOpenScore = onOpenScore,
        onOpenDrawer = onOpenDrawer,
        onEditInfoForScore = onEditInfoForScore,
        importAction = null,
    )
}
