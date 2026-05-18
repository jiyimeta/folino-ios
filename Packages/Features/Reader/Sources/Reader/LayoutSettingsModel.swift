import CoreGraphics
import Domain
import Observation
import SheetMusicCore

/// Owns the Reader's visual / layout preferences slice — staff size, break policy, hidden staves, per-staff clef
/// overrides. Carved out of `ReaderViewModel` so `VisualInspectorScreen` (and the score-rendering pipeline at
/// `ReaderRootScreen`) read the same source of truth without touching the full view model.
///
/// Persistent fields mirror the matching `ReaderPreferences` fields; the parent VM's `onChange` callback copies this
/// slice back into the preferences struct at save time.
@MainActor
@Observable
final class LayoutSettingsModel {
    private(set) var staffSize: CGFloat = 14
    private(set) var honorLayoutBreaks = false
    private(set) var hiddenStaves: Set<StaffAddress> = []
    private(set) var staffClefOverrides: [StaffAddress: String] = [:]

    @ObservationIgnored var onChange: (() async -> Void)?
    /// Fires synchronously after `toggleStaff` mutates `hiddenStaves`, so the parent VM can re-translate the playback
    /// cursor against the new visibility before the saved-cursor read lands on a hidden staff. The async `onChange`
    /// still runs for persistence.
    @ObservationIgnored var onHiddenStavesChanged: (() -> Void)?
    @ObservationIgnored var scoreProvider: () -> Score? = { nil }

    func sync(from prefs: ReaderPreferences) {
        staffSize = prefs.staffSize
        honorLayoutBreaks = prefs.honorLayoutBreaks
        hiddenStaves = prefs.hiddenStaves
        staffClefOverrides = prefs.staffClefOverrides
    }

    func incrementStaffSize() async {
        let next = min(staffSize + 1, ReaderPreferences.maxStaffSize)
        guard next != staffSize else { return }
        staffSize = next
        await onChange?()
    }

    func decrementStaffSize() async {
        let next = max(staffSize - 1, ReaderPreferences.minStaffSize)
        guard next != staffSize else { return }
        staffSize = next
        await onChange?()
    }

    func setHonorLayoutBreaks(_ value: Bool) async {
        guard value != honorLayoutBreaks else { return }
        honorLayoutBreaks = value
        await onChange?()
    }

    func toggleStaff(_ address: StaffAddress) async {
        if hiddenStaves.contains(address) {
            hiddenStaves.remove(address)
        } else {
            hiddenStaves.insert(address)
        }
        onHiddenStavesChanged?()
        await onChange?()
    }

    // MARK: - Clef overrides

    /// Returns the rawType the renderer will use for the staff: the override if one is set, otherwise the score's
    /// authored opening clef, falling back to `"G"` if neither exists or the staff isn't in the score.
    func effectiveClef(for address: StaffAddress) -> String {
        if let override = staffClefOverrides[address] {
            return override
        }
        return scoreProvider()?.authoredClef(at: address) ?? "G"
    }

    func hasClefOverride(for address: StaffAddress) -> Bool {
        staffClefOverrides[address] != nil
    }

    /// True only when an override is set AND its rawType differs from the score's authored opening clef. The picker
    /// uses this to gate the "Use score's clef" button — when the override happens to match the authored value (e.g.
    /// user picked the same Treble that was already there) clearing it would be visibly a no-op, so the reset
    /// affordance would just be noise.
    func isClefOverrideEffective(for address: StaffAddress) -> Bool {
        guard let override = staffClefOverrides[address] else { return false }
        return override != (scoreProvider()?.authoredClef(at: address) ?? "G")
    }

    func setClefOverride(_ rawType: String, for address: StaffAddress) async {
        guard staffClefOverrides[address] != rawType else { return }
        staffClefOverrides[address] = rawType
        await onChange?()
    }

    func clearClefOverride(for address: StaffAddress) async {
        guard staffClefOverrides[address] != nil else { return }
        staffClefOverrides.removeValue(forKey: address)
        await onChange?()
    }
}
