package com.keynumber.folino.ui.debug

import android.os.Process
import android.widget.Toast
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import com.keynumber.folino.diagnostics.CrashReporting

/**
 * Debug-only screen for exercising the Crashlytics pipeline. Reached from a drawer entry that is
 * shown only in debug builds (see MainActivity). Never ships in release builds.
 *
 * Crash reports upload on the *next* launch, and only while the "Send crash reports" toggle is on.
 */
@Composable
fun DebugScreen() {
    val context = LocalContext.current
    Column(
        Modifier
            .fillMaxWidth()
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Text("Crashlytics", style = MaterialTheme.typography.titleSmall)
        Text(
            "Reports upload on the next launch, and only while \"Send crash reports\" is enabled.",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )

        Button(
            onClick = {
                // Uncaught exception on the main thread → captured by Crashlytics' default handler.
                throw RuntimeException("folino debug menu: forced JVM crash")
            },
            modifier = Modifier.fillMaxWidth(),
        ) { Text("Force JVM crash") }

        Button(
            onClick = {
                // SIGSEGV to our own process — caught by the firebase-crashlytics-ndk signal
                // handler and reported as a native crash. No JNI shim needed.
                Process.sendSignal(Process.myPid(), 11)
            },
            modifier = Modifier.fillMaxWidth(),
        ) { Text("Force native crash (NDK)") }

        Button(
            onClick = {
                CrashReporting.recordNonFatal(
                    RuntimeException("folino debug menu: recorded non-fatal"),
                )
                Toast.makeText(context, "Non-fatal recorded (uploads next launch)", Toast.LENGTH_SHORT).show()
            },
            modifier = Modifier.fillMaxWidth(),
        ) { Text("Record non-fatal") }
    }
}
