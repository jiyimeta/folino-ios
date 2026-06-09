package com.keynumber.folino.share

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.viewModels
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.selection.selectable
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.lifecycle.lifecycleScope
import com.keynumber.folino.LibraryVMFactory
import com.keynumber.folino.MainActivity
import com.keynumber.folino.R
import com.keynumber.folino.library.generated.LibraryAndroidStoreViewModel
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

class ShareTargetActivity : ComponentActivity() {

    private val vm: LibraryAndroidStoreViewModel by viewModels { LibraryVMFactory(applicationContext) }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val uris = extractUris(intent)
        if (uris.isEmpty()) { finish(); return }

        setContent {
            MaterialTheme {
                var staged by remember { mutableStateOf<List<StagedShareFile>?>(null) }
                var unsupported by remember { mutableIntStateOf(0) }

                LaunchedEffect(Unit) {
                    val (files, bad) = withContext(Dispatchers.IO) { stageSharedUris(this@ShareTargetActivity, uris) }
                    staged = files
                    unsupported = bad
                }

                val playlists by vm.playlists.collectAsState()
                val files = staged
                when {
                    files == null -> Unit // still staging
                    files.isEmpty() -> LaunchedEffect(Unit) {
                        Toast.makeText(
                            this@ShareTargetActivity,
                            getString(R.string.share_no_supported_files),
                            Toast.LENGTH_LONG,
                        ).show()
                        finish()
                    }
                    else -> ShareImportSheet(
                        fileCount = files.size,
                        unsupportedCount = unsupported,
                        playlists = playlists.map { it.id to it.name },
                        onCancel = { cleanupStaged(files); finish() },
                        onConfirm = { mode, playlistId, newName, openAfter ->
                            performImport(files, mode, playlistId, newName, openAfter)
                        },
                    )
                }
            }
        }
    }

    private fun performImport(
        files: List<StagedShareFile>,
        mode: Int,
        playlistId: String,
        newName: String,
        openAfter: Boolean,
    ) {
        lifecycleScope.launch {
            val result = withContext(Dispatchers.IO) {
                vm.importShared(
                    files.map { it.path },
                    files.map { it.originalName },
                    mode,
                    playlistId,
                    newName,
                    openAfter,
                )
            }
            cleanupStaged(files)
            val openId = result.openAfterId
            if (openAfter && openId.isNotEmpty()) {
                val openTitle = vm.scores.value.firstOrNull { it.id == openId }?.title.orEmpty()
                startActivity(
                    Intent(this@ShareTargetActivity, MainActivity::class.java).apply {
                        putExtra(MainActivity.EXTRA_OPEN_SCORE_ID, openId)
                        putExtra(MainActivity.EXTRA_OPEN_SCORE_TITLE, openTitle)
                        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
                    },
                )
            } else {
                val msg = if (result.importedCount > 0) {
                    getString(R.string.share_imported_count, result.importedCount)
                } else {
                    getString(R.string.share_nothing_imported)
                }
                Toast.makeText(this@ShareTargetActivity, msg, Toast.LENGTH_LONG).show()
            }
            finish()
        }
    }

    private fun extractUris(intent: Intent): List<Uri> = when (intent.action) {
        Intent.ACTION_SEND -> listOfNotNull(
            if (Build.VERSION.SDK_INT >= 33) {
                intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
            } else {
                @Suppress("DEPRECATION") intent.getParcelableExtra(Intent.EXTRA_STREAM)
            },
        )
        Intent.ACTION_SEND_MULTIPLE ->
            (
                if (Build.VERSION.SDK_INT >= 33) {
                    intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java)
                } else {
                    @Suppress("DEPRECATION") intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM)
                }
                )?.filterNotNull() ?: emptyList()
        Intent.ACTION_VIEW -> listOfNotNull(intent.data)
        else -> emptyList()
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ShareImportSheet(
    fileCount: Int,
    unsupportedCount: Int,
    playlists: List<Pair<String, String>>,
    onCancel: () -> Unit,
    onConfirm: (mode: Int, playlistId: String, newName: String, openAfter: Boolean) -> Unit,
) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    var mode by remember { mutableIntStateOf(0) } // 0 library, 1 existing, 2 new
    var selectedPlaylist by remember { mutableStateOf(playlists.firstOrNull()?.first ?: "") }
    var newName by remember { mutableStateOf("") }

    ModalBottomSheet(onDismissRequest = onCancel, sheetState = sheetState) {
        Column(
            Modifier
                .padding(horizontal = 24.dp)
                .padding(bottom = 32.dp),
        ) {
            Text(
                text = stringResource(R.string.share_import_count, fileCount),
                style = MaterialTheme.typography.titleLarge,
            )
            if (unsupportedCount > 0) {
                Text(
                    text = stringResource(R.string.share_unsupported_skipped, unsupportedCount),
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            Spacer(Modifier.height(16.dp))
            Text(stringResource(R.string.share_add_to), style = MaterialTheme.typography.titleSmall)

            DestinationRow(stringResource(R.string.share_dest_library), selected = mode == 0) { mode = 0 }
            if (playlists.isNotEmpty()) {
                DestinationRow(stringResource(R.string.share_dest_existing), selected = mode == 1) { mode = 1 }
                if (mode == 1) {
                    Column(Modifier.padding(start = 32.dp)) {
                        playlists.forEach { (id, name) ->
                            DestinationRow(name, selected = selectedPlaylist == id) { selectedPlaylist = id }
                        }
                    }
                }
            }
            DestinationRow(stringResource(R.string.share_dest_new), selected = mode == 2) { mode = 2 }
            if (mode == 2) {
                OutlinedTextField(
                    value = newName,
                    onValueChange = { newName = it },
                    label = { Text(stringResource(R.string.share_new_playlist_name)) },
                    singleLine = true,
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(start = 32.dp, top = 4.dp),
                )
            }

            Spacer(Modifier.height(24.dp))
            val enabled = mode != 2 || newName.isNotBlank()
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                OutlinedButton(
                    onClick = { onConfirm(mode, if (mode == 1) selectedPlaylist else "", newName.trim(), false) },
                    enabled = enabled,
                    modifier = Modifier.weight(1f),
                ) { Text(stringResource(R.string.share_save)) }
                Button(
                    onClick = { onConfirm(mode, if (mode == 1) selectedPlaylist else "", newName.trim(), true) },
                    enabled = enabled,
                    modifier = Modifier.weight(1f),
                ) { Text(stringResource(R.string.share_save_and_open)) }
            }
        }
    }
}

@Composable
private fun DestinationRow(label: String, selected: Boolean, onSelect: () -> Unit) {
    Row(
        Modifier
            .fillMaxWidth()
            .selectable(selected = selected, onClick = onSelect)
            .padding(vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        RadioButton(selected = selected, onClick = onSelect)
        Spacer(Modifier.width(8.dp))
        Text(label, style = MaterialTheme.typography.bodyLarge)
    }
}
