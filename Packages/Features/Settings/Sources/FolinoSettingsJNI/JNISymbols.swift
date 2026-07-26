import Domain
import Foundation
import SettingsLogic

/// swift-java entry point for Kotlin `SettingsJNI.nativeLoadVersionHistory`.
/// Takes the YAML asset bytes, returns the wirelet-encoded entry list.
public func nativeLoadVersionHistory(ymlBytes: Data) -> Data {
    versionHistoryWirePayload(ymlData: ymlBytes)
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
