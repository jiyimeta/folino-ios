package com.keynumber.folino.reader.pdf

import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.res.stringResource
import com.keynumber.folino.reader.R

/**
 * The PDF-playback caveat: folino reads (parses) the original PDF to play it and follow along, that reading isn't
 * always right, and it works best with PDFs exported from MuseScore or folino. Mirrors iOS's `PDFPlaybackNotice`
 * one-for-one in CONTENT (same four strings, same two actions, same choice of body copy) while presenting as a
 * Material [AlertDialog] rather than a `.alert`.
 *
 * Deliberately NOT a per-document diagnostics report: the importer's own diagnostics are recorded for us, never
 * listed in the UI — on either platform. This is one fixed caveat about OMR accuracy in general.
 *
 * [unavailable] picks the body: the "couldn't read this PDF" copy when the parse failed, the best-effort caveat
 * otherwise (parsing or ready) — the same split iOS's `pdfPlaybackNoticeBodyKey` makes.
 *
 * Two actions. [onDismiss] backs the confirming **OK**, which only closes it for now, and is also what a scrim tap /
 * back press does. [onDontShowAgain] backs "Don't show again", which additionally sets the shared preference that
 * stops the automatic presentation for good; the caveat stays reachable afterwards from the reader's PDF label, which
 * is what makes that action safe to offer.
 */
@Composable
internal fun PdfPlaybackNoticeDialog(
    unavailable: Boolean,
    onDismiss: () -> Unit,
    onDontShowAgain: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.reader_pdf_playback_notice_title)) },
        text = {
            Text(
                stringResource(
                    if (unavailable) {
                        R.string.reader_pdf_playback_unavailable_body
                    } else {
                        R.string.reader_pdf_playback_notice_body
                    },
                ),
            )
        },
        // Material puts the affirming action last (trailing); "Don't show again" is the secondary one, so it takes
        // the dismiss slot — the Android placement of iOS's plain-vs-`.confirm` button pair. The OK label is the
        // platform string (localized in every locale the system ships), matching how iOS reuses its own shared
        // `L10n.Common.ok` rather than minting per-dialog copy.
        confirmButton = {
            TextButton(onClick = onDismiss) { Text(stringResource(android.R.string.ok)) }
        },
        dismissButton = {
            TextButton(onClick = onDontShowAgain) {
                Text(stringResource(R.string.reader_pdf_playback_notice_dismiss))
            }
        },
    )
}
