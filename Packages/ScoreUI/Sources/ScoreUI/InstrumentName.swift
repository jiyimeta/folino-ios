import Domain
import Foundation

/// The instrument's display name in the reader's language, resolved from the ScoreUI catalog.
///
/// `ScoreInstrument.englishName` stays the fallback rather than the source of truth: an instrument added to Domain
/// but not yet translated still reads as *something* instead of showing a raw key. `InstrumentNameTests` fails on
/// exactly that gap, so the fallback is a safety net for shipped builds, not a licence to skip the xcstrings entry.
///
/// The written-pitch qualifier is part of the name string ("Clarinet in B♭", 「クラリネット（B♭）」) — each language
/// places it differently, so it cannot be composed from the transposition at call time.
public func localizedInstrumentName(_ instrument: ScoreInstrument) -> String {
    localizedName(forKey: "instrument.\(instrument.id)", fallback: instrument.englishName)
}

/// The family's section header in the reader's language. The fallback is the raw case name — deliberately ugly,
/// because the seven families are fixed and a miss here is a build-time mistake, not a shipped state.
func localizedInstrumentFamilyName(_ family: ScoreInstrument.Family) -> String {
    localizedName(forKey: "instrumentFamily.\(family.rawValue)", fallback: family.rawValue)
}

/// Looks a catalog key up in this module's bundle, answering `fallback` when there is no entry for it.
///
/// The key is built at runtime, so it is passed through `String.LocalizationValue(stringLiteral:)` rather than
/// interpolated into one: interpolation into a `LocalizationValue` produces a `%@` *format* whose argument is the
/// id, which would look for a key named "instrument.%@" and never find one.
///
/// Foundation answers a miss by handing the key straight back, which is what the equality check reads.
func localizedName(forKey key: String, fallback: String) -> String {
    let resolved = String(localized: String.LocalizationValue(stringLiteral: key), bundle: .module)
    return resolved == key ? fallback : resolved
}
