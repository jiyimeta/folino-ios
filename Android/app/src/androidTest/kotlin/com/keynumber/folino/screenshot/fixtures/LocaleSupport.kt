package com.keynumber.folino.screenshot.fixtures

import android.content.Context
import android.content.ContextWrapper
import android.content.res.Resources
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.remember
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext

// Re-localizes the wrapped app subtree to `tag`, independent of the emulator's system locale.
//
// The marketing frame's title/subtitle pull from MarketingStrings directly (so they're already in the
// scene's language), but the app UI inside the device frame resolves `stringResource` /
// `LocalConfiguration` against the ambient context — which is the emulator's system locale (English)
// for BOTH the en and ja captures. We override the locale for the wrapped content only.
//
// IMPORTANT: we do NOT use `createConfigurationContext`, which returns a fresh ContextImpl with no
// Activity ancestry. Replacing `LocalContext` with that breaks `ContextCompat.getActivity()` /
// `LocalActivityResultRegistryOwner` (LibraryScreen registers an activity-result launcher for its
// file picker), throwing "No ActivityResultRegistryOwner was provided". Instead we wrap the ORIGINAL
// context in a ContextWrapper whose base is unchanged (so unwrapping still reaches the Activity) and
// only override `getResources()` to return locale-overridden Resources. `stringResource` resolves
// against those Resources; `LocalConfiguration` is provided alongside for any direct reader. Labels
// with no ja translation fall back to the default strings.xml (English) — expected.
@Composable
fun WithAppLocale(tag: String, content: @Composable () -> Unit) {
    val ctx = LocalContext.current
    val config = remember(tag, ctx) {
        android.content.res.Configuration(ctx.resources.configuration).apply {
            setLocale(java.util.Locale.forLanguageTag(tag))
        }
    }
    val localized = remember(tag, ctx) { LocalizedContextWrapper(ctx, config) }
    CompositionLocalProvider(
        LocalContext provides localized,
        LocalConfiguration provides config,
    ) { content() }
}

// Delegates everything to `base` (preserving the Activity chain for owner lookups) except Resources,
// which are locale-overridden via a configuration context derived from `base`.
private class LocalizedContextWrapper(
    base: Context,
    config: android.content.res.Configuration,
) : ContextWrapper(base) {
    private val localizedResources: Resources =
        base.createConfigurationContext(config).resources

    override fun getResources(): Resources = localizedResources
}
