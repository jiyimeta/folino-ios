import Domain
import Foundation
import SheetMusicCore

/// A time signature as the sheets state one — the pair of numbers a picker holds, with none of `TimeSignature`'s
/// engraving flags. The sheet is choosing what the bar declares, not how it is drawn.
public struct EditorTimeSignatureValue: Equatable {
    public var numerator: Int
    public var denominator: Int

    public init(numerator: Int, denominator: Int) {
        self.numerator = numerator
        self.denominator = denominator
    }
}

/// Key- and time-signature changes, as the two signature sheets drive them. Every op routes through the shared
/// `apply(_:)` choke point, so all four are undoable and all four re-publish the score to the Reader for free.
///
/// All four address `targetMeasureIndex` — the selection's bar, else the caret's — and the engine applies the change
/// from there to the next bar declaring one of the same kind, with bar 0 meaning "the whole score" (see the intents'
/// own documentation). A no-op without a target, exactly as the measure ops next door are.
///
/// **A refused apply and a no-op apply both come back `false`**, and only one of them is worth telling the user
/// about. Picking the key a bar is already in, or removing a change from a bar that declares none, plans to nothing
/// and the session reports `.nothingToApply` — an alert there would put an error in front of someone who chose
/// correctly. So `lastSignatureRefusal` is set for every OTHER reason and left `nil` for that one.
extension EditorViewModel {
    // MARK: - What the sheets open showing

    /// The key in force at the target bar, in concert pitch. `nil` without a target, and for a score with no pitched
    /// staff to read a key from.
    public var targetConcertKey: Int? {
        guard let score, let targetMeasureIndex, let reference = keySignatureReferenceStaff else { return nil }
        return score.activeKey(staff: reference, measureIndex: targetMeasureIndex)
    }

    /// The meter in force at the target bar. `nil` without a target.
    public var targetTimeSignature: EditorTimeSignatureValue? {
        guard let score, let targetMeasureIndex else { return nil }
        return Self.timeSignature(inForceAt: targetMeasureIndex, in: score)
    }

    /// Whether the target bar declares a key of its OWN — which is what the sheet's Remove row acts on. False at bar
    /// 0, whose signature is the score's key rather than a change to it (the engine refuses removing it), and false
    /// for a bar that merely inherits.
    public var targetHasExplicitKeyChange: Bool {
        guard let score, let targetMeasureIndex, targetMeasureIndex > 0,
              let reference = keySignatureReferenceStaff,
              let voice = Self.voiceZero(of: score, at: reference, measureIndex: targetMeasureIndex)
        else { return false }
        return Self.leadingSignatures(of: voice).contains(where: \.isKeySignature)
    }

    /// Whether the target bar declares a meter of its own. Same shape as `targetHasExplicitKeyChange`, read from
    /// part 0 / staff 0: a time signature is score-wide in this model, which is the invariant
    /// `Score.effectiveMeasureDurations()` itself rests on.
    public var targetHasExplicitTimeChange: Bool {
        guard let score, let targetMeasureIndex, targetMeasureIndex > 0,
              let voice = Self.voiceZero(
                  of: score, at: StaffAddress(partIndex: 0, staffIndexInPart: 0), measureIndex: targetMeasureIndex,
              )
        else { return false }
        return Self.leadingSignatures(of: voice).contains(where: \.isTimeSignature)
    }

    // MARK: - Applying

    /// Writes `concertKey` at the target bar, replacing whatever that bar declared or inserting a change where it
    /// declared none.
    @discardableResult
    public func setKeySignature(concertKey: Int) -> Bool {
        guard let targetMeasureIndex else { return false }
        return applySignature(
            .setKeySignature(measureIndex: targetMeasureIndex, concertKey: concertKey), kind: "key", action: "set",
        )
    }

    /// Drops the target bar's own key change, handing the span back to the key that was already in force.
    @discardableResult
    public func removeKeySignatureChange() -> Bool {
        guard let targetMeasureIndex else { return false }
        return applySignature(.removeKeySignature(measureIndex: targetMeasureIndex), kind: "key", action: "remove")
    }

    /// Writes `numerator`/`denominator` at the target bar and re-bars the span it governs.
    @discardableResult
    public func setTimeSignature(numerator: Int, denominator: Int) -> Bool {
        guard let targetMeasureIndex else { return false }
        return applySignature(
            .setTimeSignature(measureIndex: targetMeasureIndex, numerator: numerator, denominator: denominator),
            kind: "time", action: "set",
        )
    }

    /// Drops the target bar's own meter change, re-barring the span back to the meter that was already in force.
    @discardableResult
    public func removeTimeSignatureChange() -> Bool {
        guard let targetMeasureIndex else { return false }
        return applySignature(.removeTimeSignature(measureIndex: targetMeasureIndex), kind: "time", action: "remove")
    }

    /// The one apply path the four ops share: land the intent, then either report the change or record why it did
    /// not happen — see the type doc for why `.nothingToApply` records nothing.
    private func applySignature(_ intent: EditIntent, kind: String, action: String) -> Bool {
        guard apply(intent) else {
            let refusal = session?.lastRefusal
            lastSignatureRefusal = refusal?.reason == .nothingToApply ? nil : refusal
            return false
        }
        lastSignatureRefusal = nil
        onSignatureChanged?(kind, action)
        return true
    }

    /// Both sheet flags' `didSet`. Opening either drops the refusal the last attempt left: that alert belongs to the
    /// attempt that raised it, and a sheet reopened later has nothing to say about it yet.
    func signatureSheetPresentationChanged(to isPresented: Bool) {
        guard isPresented else { return }
        lastSignatureRefusal = nil
    }

    // MARK: - Reading the score

    /// The staff a key is read from: the first pitched one, excluding a `useDrumset` part and a `"percussion"` staff
    /// the way ssm's own `KeySignatureStaves` does — mirrored here because that type is internal to the engine.
    /// `nil` for a kit-only score, which declares no key anywhere and so has none to show.
    private var keySignatureReferenceStaff: StaffAddress? {
        guard let score else { return nil }
        for (partIndex, part) in score.parts.enumerated() where !part.instrument.useDrumset {
            for (staffIndex, staff) in part.staves.enumerated() where staff.group != "percussion" {
                return StaffAddress(partIndex: partIndex, staffIndexInPart: staffIndex)
            }
        }
        return nil
    }

    /// The meter in force at `measureIndex` — the last bar up to and including it that declares one, 4/4 until one
    /// does. Walked the way `Score.activeKey` walks key signatures.
    ///
    /// NOT derived from `effectiveMeasureDuration(at:measureIndex:)`, which would be the obvious shortcut and is
    /// wrong: that `Fraction` is the bar's `actualLength` when it has one, so a pickup would report its own truncated
    /// length as the meter — "how long is this bar" and "what meter is it in" are different questions.
    private static func timeSignature(inForceAt measureIndex: Int, in score: Score) -> EditorTimeSignatureValue {
        var current = EditorTimeSignatureValue(numerator: 4, denominator: 4)
        guard let staff = score.parts.first?.staves.first else { return current }
        for index in 0 ..< min(measureIndex + 1, staff.measures.count) {
            guard let voice = staff.measures[index].voices.first else { continue }
            for element in voice.elements {
                if case let .timeSignature(signature) = element {
                    current = EditorTimeSignatureValue(
                        numerator: signature.numerator, denominator: signature.denominator,
                    )
                    break
                }
            }
        }
        return current
    }

    /// One staff's voice 0 at `measureIndex`, or `nil` when the staff is shorter than that or the bar carries no
    /// voices at all.
    private static func voiceZero(of score: Score, at address: StaffAddress, measureIndex: Int) -> Voice? {
        guard let staff = score[address], staff.measures.indices.contains(measureIndex) else { return nil }
        return staff.measures[measureIndex].voices.first
    }

    /// The run of clef / key / time elements at the head of a voice — ssm's `MeasureStructure.leadingSignaturePrefix`
    /// mirrored, that type being internal to the engine.
    ///
    /// Scoping to the run is the point: a key signature written after a note is a mid-bar change, which is neither
    /// what "this bar declares a key" means nor something the signature commands claim to manage.
    private static func leadingSignatures(of voice: Voice) -> [VoiceElement] {
        Array(voice.elements.prefix { $0.isLeadingSignatureKind })
    }
}

/// The three element kinds the signature reads dispatch on, as properties rather than `if case` at each call site —
/// `contains(where:)` and `prefix(while:)` both want a plain predicate.
extension VoiceElement {
    fileprivate var isKeySignature: Bool {
        switch self {
        case .keySignature: true
        default: false
        }
    }

    fileprivate var isTimeSignature: Bool {
        switch self {
        case .timeSignature: true
        default: false
        }
    }

    /// Whether this element belongs to a bar's leading signature run — the kinds `MeasureStructure`'s own
    /// `isLeadingSignature` names.
    fileprivate var isLeadingSignatureKind: Bool {
        switch self {
        case .clef, .keySignature, .timeSignature: true
        default: false
        }
    }
}
