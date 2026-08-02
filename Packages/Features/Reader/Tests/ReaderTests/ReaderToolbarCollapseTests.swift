import Foundation
@testable import Reader
import Testing

/// Pins the toolbar's fold breakpoints to the widths of real devices.
///
/// The bug these exist for: the fold compared the score reader's six-button row against the FULL window width, which
/// put its breakpoint at 392pt — below every iPhone. So it never ran, and on a 402pt iPhone 16 Pro the navigation bar
/// made an overflow menu of its own instead, swallowed the two inspectors, and would not open when tapped.
///
/// The rule these lock in: on a phone something always folds, and what folds first is score-info + share.
@MainActor
@Suite("ReaderToolbar collapse breakpoints")
struct ReaderToolbarCollapseTests {
    /// Portrait widths in points. The Reader is a full-window screen on iPhone, so the window width IS these.
    private enum Device {
        static let iPhone12Mini: CGFloat = 375
        static let iPhoneSE3: CGFloat = 375
        static let iPhone17: CGFloat = 393
        static let iPhone16Pro: CGFloat = 402
        static let iPhone17ProMax: CGFloat = 440
        static let iPadPortrait: CGFloat = 834
    }

    private func collapse(_ width: CGFloat, hasNoteEditing: Bool = true) -> ReaderToolbar.Collapse {
        ReaderToolbar.collapse(availableWidth: width, hasLeadingAffordance: true, hasNoteEditing: hasNoteEditing)
    }

    @Test
    func `no iPhone tries to show the full six-button row`() {
        let phones = [
            Device.iPhoneSE3, Device.iPhone17, Device.iPhone16Pro, Device.iPhone17ProMax,
        ]
        for width in phones {
            #expect(collapse(width) > .expanded, "\(width)pt should fold at least the score actions")
        }
    }

    @Test
    func `a modern iPhone folds the score actions and stops there`() {
        #expect(collapse(Device.iPhone16Pro) == .scoreActions)
        #expect(collapse(Device.iPhone17) == .scoreActions)
        #expect(collapse(Device.iPhone17ProMax) == .scoreActions)
    }

    @Test
    func `the narrowest phones give up the note-editing button too`() {
        #expect(collapse(Device.iPhone12Mini) == .noteEditing)
        #expect(collapse(Device.iPhoneSE3) == .noteEditing)
    }

    @Test
    func `an iPad detail column keeps every action discrete`() {
        #expect(collapse(Device.iPadPortrait) == .expanded)
    }

    @Test
    func `the first frame, before the width is measured, starts fully folded`() {
        #expect(collapse(0) == .annotation)
    }

    @Test
    func `folding never makes the row wider`() {
        let costs = ReaderToolbar.Collapse.allCases.map {
            ReaderToolbar.trailingWidth(collapse: $0, hasNoteEditing: true)
        }
        #expect(costs == costs.sorted(by: >))
    }

    @Test
    func `a reader with no note editing wired skips that level's saving`() {
        let withHost = ReaderToolbar.trailingWidth(collapse: .noteEditing, hasNoteEditing: true)
        let withoutHost = ReaderToolbar.trailingWidth(collapse: .scoreActions, hasNoteEditing: false)
        #expect(withHost == withoutHost)
    }
}
