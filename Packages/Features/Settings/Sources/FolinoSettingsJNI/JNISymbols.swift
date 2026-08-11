import Domain
import Foundation
import SettingsLogic

/// swift-java entry point for Kotlin `SettingsJNI.nativeLoadVersionHistory`.
///
/// Takes the YAML asset bytes plus the device's language tag (`java.util.Locale.getDefault().toLanguageTag()`),
/// returns the wirelet-encoded entry list. The tag has to come from the host: descriptions are localized before
/// they cross the wire, and this library's `Locale.current` describes the Swift runtime's environment, not the
/// phone's language — reading it here left every non-English device showing the English release notes.
public func nativeLoadVersionHistory(ymlBytes: Data, languageTag: String) -> Data {
    versionHistoryWirePayload(ymlData: ymlBytes, languageTag: languageTag)
}

/// swift-java entry point for Kotlin `SettingsJNI.nativeShouldPromptForReview`.
///
/// Answers the one question the review cadence exists to answer — "is launch number N a prompting launch?" — from
/// the shared `Domain.ReviewPromptCadence`, so Android prompts on exactly the launches iOS does. Counting the
/// launches and actually invoking the store's review flow stay on the platform side.
public func nativeShouldPromptForReview(coldLaunchCount: Int32) -> Bool {
    ReviewPromptCadence.shouldPrompt(coldLaunchCount: Int(coldLaunchCount))
}

/// swift-java entry point for Kotlin `SettingsJNI.nativeGMDrumKitCatalog`.
///
/// The bank-128 kit catalog (`Domain.GMDrumKit`), so the Android mixer's percussion picker offers exactly the kits
/// the SF2 split actually ships — the same list iOS's picker shows — instead of a Kotlin copy that would drift.
public func nativeGMDrumKitCatalog() -> Data {
    gmDrumKitCatalogPayload()
}
