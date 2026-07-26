package com.keynumber.folino

import android.app.Activity
import android.content.Context
import android.util.Log
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.intPreferencesKey
import com.google.android.play.core.ktx.launchReview
import com.google.android.play.core.ktx.requestReview
import com.google.android.play.core.review.ReviewManagerFactory
import com.keynumber.folino.settings.SettingsJNI
import com.keynumber.folino.ui.settings.dataStore
import kotlinx.coroutines.flow.first

/**
 * Cold-launch counter for the review prompt. Mirrors iOS's
 * `UserDefaults` key `ReviewPrompt.coldLaunchCount`.
 */
private val coldLaunchCountKey = intPreferencesKey("ReviewPrompt.coldLaunchCount")

/**
 * Counts this cold launch and, on a prompting launch, asks Play to show its in-app review flow.
 *
 * **Whether** to ask comes from the shared `Domain.ReviewPromptCadence` over JNI, so Android prompts on
 * exactly the launches iOS does (nothing before the 10th, then every 40th).
 *
 * **How** it is asked follows the Android idiom, not iOS's: there is no custom "do you like folino?"
 * pre-prompt. Play's policy forbids gating or preceding the flow with a question of our own, so this
 * launches the review flow directly and Play decides whether a card actually appears (it silently
 * no-ops when the user has already reviewed, or is over quota). That means a "successful" call is not
 * evidence that anything was shown — there is deliberately nothing to observe or log here.
 *
 * The counter is incremented exactly once per process, before the decision, so the cadence keeps
 * advancing even on launches that don't prompt.
 *
 * Failures (no Play Store, a Play-services error, the activity going away mid-flow) are swallowed: a
 * review prompt is never worth interrupting a launch over. They ARE logged, though — because Play
 * showing nothing is indistinguishable from Play never being asked, a silently broken JNI or Play
 * dependency would otherwise look exactly like normal operation forever.
 */
suspend fun maybePromptForReview(activity: Activity) {
    runCatching {
        val count = incrementColdLaunchCount(activity.applicationContext)
        if (!SettingsJNI.nativeShouldPromptForReview(count)) return
        val manager = ReviewManagerFactory.create(activity)
        manager.launchReview(activity, manager.requestReview())
    }.onFailure { Log.w("ReviewPrompt", "in-app review flow failed", it) }
}

/** Increments and returns the persisted cold-launch count (1-based for the first ever launch). */
private suspend fun incrementColdLaunchCount(context: Context): Int {
    val current = context.dataStore.data.first()[coldLaunchCountKey] ?: 0
    val next = current + 1
    context.dataStore.edit { it[coldLaunchCountKey] = next }
    return next
}
