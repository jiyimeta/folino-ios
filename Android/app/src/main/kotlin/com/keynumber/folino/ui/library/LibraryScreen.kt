package com.keynumber.folino.ui.library

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.platform.LocalContext
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.keynumber.folino.R
import com.keynumber.folino.diagnostics.AndroidAnalytics
import com.keynumber.folino.library.ScoreRowWire
import com.keynumber.folino.share.isAcceptedScoreFilename
import com.keynumber.folino.library.generated.LibraryAndroidStoreViewModel

@Composable
fun LibraryScreen(
    viewModel: LibraryAndroidStoreViewModel,
    onOpenScore: (ScoreRowWire) -> Unit,
    onOpenDrawer: () -> Unit,
    onEditInfoForScore: (String) -> Unit,
) {
    val scores by viewModel.scores.collectAsStateWithLifecycle()
    val context = LocalContext.current
    val picker = rememberLauncherForActivityResult(
        ActivityResultContracts.OpenDocument(),
    ) { uri ->
        if (uri != null) {
            val displayName = originalDisplayName(context, uri)
            // iOS parity (ShareImportPolicy): the picker is broad (Android MIME for .mscz is
            // unreliable), so gate the chosen file by its extension and reject non-scores.
            if (!isAcceptedScoreFilename(displayName)) {
                android.widget.Toast.makeText(
                    context,
                    context.getString(R.string.share_no_supported_files),
                    android.widget.Toast.LENGTH_LONG,
                ).show()
            } else {
                val cacheFile = java.io.File(context.cacheDir, displayName)
                context.contentResolver.openInputStream(uri)?.use { input ->
                    cacheFile.outputStream().use { output -> input.copyTo(output) }
                }
                // Surface import failures that were previously silent: a broken DB throws here
                // (Kotlin context, catchable — unlike inside the Swift->Kotlin JNI proxy), and a
                // no-op import (parse failure etc.) is caught by the count delta. Either way the
                // user is told and a Crashlytics non-fatal is logged instead of the import
                // silently doing nothing. The picker result callback runs on the main thread, so
                // the Toast is shown directly; RoomLibraryStore.loadAll() is a synchronous Room
                // query (allowMainThreadQueries), safe to call here.
                val store = com.keynumber.folino.library.RoomLibraryStore(context)
                try {
                    val before = store.loadAll().count { it.deletedAt <= 0.0 }
                    // importScore builds + returns the score_imported / score_import_failed analytics event itself;
                    // log it here (the picker callback runs on the main thread). Mirrors iOS LibraryViewModel.commit.
                    AndroidAnalytics.log(viewModel.importScore(cacheFile.absolutePath))
                    val after = store.loadAll().count { it.deletedAt <= 0.0 }
                    if (after <= before) {
                        com.keynumber.folino.diagnostics.CrashReporting.recordNonFatal(
                            IllegalStateException("Import produced no new score: ${cacheFile.name}"),
                        )
                        android.widget.Toast.makeText(
                            context,
                            context.getString(R.string.import_failed),
                            android.widget.Toast.LENGTH_LONG,
                        ).show()
                    }
                } catch (t: Throwable) {
                    com.keynumber.folino.diagnostics.CrashReporting.recordNonFatal(t)
                    android.widget.Toast.makeText(
                        context,
                        context.getString(R.string.import_failed),
                        android.widget.Toast.LENGTH_LONG,
                    ).show()
                }
            }
        }
    }

    ScoreListScaffold(
        viewModel = viewModel,
        scores = scores,
        titleRes = R.string.library_title,
        emptyTitleRes = R.string.library_empty_title,
        emptyHintRes = R.string.library_empty_hint,
        listSource = "libraryAll",
        onOpenScore = onOpenScore,
        onOpenDrawer = onOpenDrawer,
        onEditInfoForScore = onEditInfoForScore,
        importAction = { picker.launch(arrayOf("*/*")) },
    )
}

/// The picked document's original display name (e.g. "Now_is_the_time.mscz"),
/// used to name the cache file so the Swift side derives the title from it.
private fun originalDisplayName(context: android.content.Context, uri: android.net.Uri): String {
    var name: String? = null
    context.contentResolver.query(
        uri, arrayOf(android.provider.OpenableColumns.DISPLAY_NAME), null, null, null,
    )?.use { cursor ->
        if (cursor.moveToFirst()) {
            val idx = cursor.getColumnIndex(android.provider.OpenableColumns.DISPLAY_NAME)
            if (idx >= 0) name = cursor.getString(idx)
        }
    }
    return (name ?: "score.mscz").replace('/', '_')
}
