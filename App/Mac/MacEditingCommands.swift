import Editor
import SheetMusicCore
import SwiftUI

/// The whole editing vocabulary of the Mac, declared once (design §5). Ⅳb generalizes this table into the command
/// registry; it does not replace it, so ids are stable names and not display order.
enum MacEditingCommands {
    static func commands(in menu: MacEditingMenu) -> [MacEditingCommand] {
        all.filter { $0.menu == menu }
    }

    /// The rows of `menu` that sit at its top level, in table order.
    static func topLevelCommands(in menu: MacEditingMenu) -> [MacEditingCommand] {
        commands(in: menu).filter { $0.submenu == nil }
    }

    /// The submenus `menu` needs, in the order their first row appears in the table.
    static func submenus(in menu: MacEditingMenu) -> [MacEditingSubmenu] {
        var seen: [MacEditingSubmenu] = []
        for command in commands(in: menu) {
            if let submenu = command.submenu, !seen.contains(submenu) {
                seen.append(submenu)
            }
        }
        return seen
    }

    static func commands(in menu: MacEditingMenu, submenu: MacEditingSubmenu) -> [MacEditingCommand] {
        commands(in: menu).filter { $0.submenu == submenu }
    }

    static let all: [MacEditingCommand] = file + edit + notes + measures + score

    // MARK: File (design §5.3)

    /// Both rows are `mutating`, unlike the rest of the File menu: they rewrite the score wholesale, which is
    /// exactly what §6.2 closes off while the transport runs — a revert under a running cursor would leave the
    /// engine reading a score that no longer exists.
    private static let file: [MacEditingCommand] = [
        .init(
            "file.revert.lastOpened",
            "mac.menu.revert.lastOpened",
            menu: .file,
            isEnabled: { $0.editor.sessionHasEdits },
        ) { $0.confirmDiscard() },
        .init(
            "file.revert.original",
            "mac.menu.revert.original",
            menu: .file,
            isEnabled: { $0.editor.canRevertToOriginal },
        ) { $0.confirmRevert() },
    ]

    // MARK: Edit

    private static let edit: [MacEditingCommand] = [
        .init(
            "edit.deselect",
            "mac.menu.edit.deselect",
            menu: .edit,
            key: .escape,
            mutating: false,
            isEnabled: { $0.editor.selectedItem != nil },
        ) { $0.editor.deselect() },
        .init(
            "edit.previous",
            "mac.menu.edit.previousElement",
            menu: .edit,
            key: .leftArrow,
            mutating: false,
            isEnabled: { $0.editor.hasEditTarget },
        ) { $0.editor.selectPreviousElement() },
        .init(
            "edit.next",
            "mac.menu.edit.nextElement",
            menu: .edit,
            key: .rightArrow,
            mutating: false,
            isEnabled: { $0.editor.hasEditTarget },
        ) { $0.editor.selectNextElement() },
    ]

    // MARK: Notes (design §6 key map)

    private static let pitchLetters: [Character] = ["a", "b", "c", "d", "e", "f", "g"]

    /// MuseScore's digit table: 1 = 64th … 7 = whole. Same one ssm's macOS example binds.
    private static let durations: [(Character, NoteDuration, String)] = [
        ("1", .sixtyFourth, "64th"), ("2", .thirtySecond, "32nd"), ("3", .sixteenth, "16th"),
        ("4", .eighth, "8th"), ("5", .quarter, "quarter"), ("6", .half, "half"), ("7", .whole, "whole"),
    ]

    private static let accidentals: [(Accidental?, String)] = [
        (.doubleFlat, "doubleFlat"), (.flat, "flat"), (.natural, "natural"), (.sharp, "sharp"),
        (.doubleSharp, "doubleSharp"), (nil, "none"),
    ]

    private static let notes: [MacEditingCommand] = pitchCommands + durationCommands + [
        .init(
            "notes.rest",
            "mac.menu.notes.rest",
            menu: .notes,
            key: "0",
            isEnabled: { $0.editor.canWriteRest },
        ) { $0.editor.writeRest() },
        .init(
            "notes.dot",
            "mac.menu.notes.dot",
            menu: .notes,
            key: ".",
            isEnabled: { $0.editor.hasEditTarget },
        ) { target in
            // With a note selected the dot lands on it; with only a caret it arms the next note written, which is
            // the pair design §5.1 names (`setSelectionDots` / `setArmedDots`).
            if target.editor.selectedItem != nil {
                target.editor.toggleSelectionDot()
            } else {
                target.editor.toggleArmedDot()
            }
        },
        .init(
            "notes.dot.double",
            "mac.menu.notes.dot.double",
            menu: .notes,
            key: ".",
            modifiers: .option,
            isEnabled: { $0.editor.hasEditTarget },
        ) { target in
            if target.editor.selectedItem != nil {
                target.editor.setSelectionDots(2)
            } else {
                target.editor.setArmedDots(2)
            }
        },
        .init(
            "notes.pitch.up",
            "mac.menu.notes.pitch.up",
            menu: .notes,
            key: .upArrow,
            isEnabled: { $0.editor.isNoteSelected },
        ) { $0.editor.shiftPitch(bySemitones: 1) },
        .init(
            "notes.pitch.down",
            "mac.menu.notes.pitch.down",
            menu: .notes,
            key: .downArrow,
            isEnabled: { $0.editor.isNoteSelected },
        ) { $0.editor.shiftPitch(bySemitones: -1) },
        .init(
            "notes.octave.up",
            "mac.menu.notes.octave.up",
            menu: .notes,
            key: .upArrow,
            modifiers: .command,
            isEnabled: { $0.editor.isNoteSelected },
        ) { $0.editor.shiftOctave(by: 1) },
        .init(
            "notes.octave.down",
            "mac.menu.notes.octave.down",
            menu: .notes,
            key: .downArrow,
            modifiers: .command,
            isEnabled: { $0.editor.isNoteSelected },
        ) { $0.editor.shiftOctave(by: -1) },
        .init(
            "notes.tie",
            "mac.menu.notes.tie",
            menu: .notes,
            key: "+",
            isEnabled: { $0.editor.canTie },
        ) { $0.editor.toggleTie() },
        .init(
            "notes.tie.append",
            "mac.menu.notes.tiedNote",
            menu: .notes,
            isEnabled: { $0.editor.canAppendTiedNote },
        ) { $0.editor.appendTiedNote() },
        .init(
            "notes.delete",
            "mac.menu.notes.delete",
            menu: .notes,
            key: .delete,
            alternateKeys: [.deleteForward],
            isEnabled: { $0.editor.selectedItem != nil },
        ) { $0.editor.deleteSelection() },
    ] + accidentalCommands + chordCommands + tupletCommands + voiceCommands

    /// A–G write a pitch at the caret.
    ///
    /// **Disabled on a drum staff rather than routed to `pressDrumKey`.** Design §5.1 describes the letters going to
    /// the kit's own `DrumsetEntry.shortcut` there, but nothing in the app can resolve a letter to a key today:
    /// `DrumPadKey` carries no shortcut, and `GMDrumset`'s stock entries — the kit every folino-authored drum part
    /// gets — define none, so the mapping would be empty for every score that did not arrive from a MuseScore file
    /// with a hand-written `<shortcut>`. The pad that owns drum entry is Ⅳc; the second half of that same spec
    /// paragraph ("the Notes menu shows the pitch commands disabled on a drum staff") is what Ⅳa implements.
    private static var pitchCommands: [MacEditingCommand] {
        pitchLetters.map { letter in
            .init(
                "notes.pitch.\(letter)", "mac.menu.notes.pitch.\(letter)",
                menu: .notes, submenu: .pitch, key: KeyEquivalent(letter),
                isEnabled: { $0.editor.hasEditTarget && !$0.editor.isDrumStaffActive },
            ) { $0.editor.inputPitch(letter: letter) }
        }
    }

    private static var durationCommands: [MacEditingCommand] {
        durations.map { digit, duration, name in
            .init(
                "notes.duration.\(name)", "mac.menu.notes.duration.\(name)",
                menu: .notes, submenu: .duration, key: KeyEquivalent(digit),
                isEnabled: { $0.editor.hasEditTarget },
            ) { target in
                // With something selected the digit re-times it; with only a caret it arms the next note.
                if target.editor.selectedItem != nil {
                    target.editor.setSelectionDuration(duration)
                } else {
                    target.editor.setDuration(duration)
                }
            }
        }
    }

    private static var accidentalCommands: [MacEditingCommand] {
        accidentals.map { accidental, name in
            .init(
                "notes.accidental.\(name)", "mac.menu.notes.accidental.\(name)",
                menu: .notes, submenu: .accidental,
                isEnabled: { $0.editor.isNoteSelected },
            ) { $0.editor.setAccidental(accidental) }
        }
    }

    /// ⇧A–⇧G add that pitch to the selected chord: arm add-to-chord, write the letter, disarm.
    private static var chordCommands: [MacEditingCommand] {
        pitchLetters.map { letter in
            .init(
                "notes.chord.add.\(letter)", "mac.menu.notes.chord.add.\(letter)",
                menu: .notes, submenu: .chord, key: KeyEquivalent(letter), modifiers: .shift,
                isEnabled: { $0.editor.isNoteSelected },
            ) { target in
                if !target.editor.isAddToChordArmed {
                    target.editor.toggleAddToChord()
                }
                target.editor.inputPitch(letter: letter)
                if target.editor.isAddToChordArmed {
                    target.editor.toggleAddToChord()
                }
            }
        } + intervalCommands + [
            .init(
                "notes.chord.remove",
                "mac.menu.notes.chord.removeNote",
                menu: .notes,
                submenu: .chord,
                key: .delete,
                modifiers: .shift,
                isEnabled: { $0.editor.isNoteSelected },
            ) { $0.editor.removeSelectedNoteFromChord() },
        ]
    }

    /// `DiatonicInterval` offers a third and an octave, and nothing else — design §5.1's "2nd–9th" describes an
    /// engine command that does not exist. Ⅳd is where the range fills in, from ssm sub-project Ⅰ.
    private static var intervalCommands: [MacEditingCommand] {
        let intervals: [(DiatonicInterval, String)] = [(.third, "third"), (.octave, "octave")]
        return intervals.map { interval, name in
            .init(
                "notes.chord.interval.\(name)", "mac.menu.notes.chord.interval.\(name)",
                menu: .notes, submenu: .chord,
                isEnabled: { $0.editor.isNoteSelected },
            ) { $0.editor.addIntervalNote(interval) }
        }
    }

    /// ⌘3–⌘9: MuseScore's tuplet keys. Ⅳc re-homes ⌘3 / ⌘4 to panels (design §6).
    private static var tupletCommands: [MacEditingCommand] {
        (3 ... 9).map { count in
            .init(
                "notes.tuplet.\(count)", "mac.menu.notes.tuplet.\(count)",
                menu: .notes, submenu: .tuplet, key: KeyEquivalent(Character("\(count)")), modifiers: .command,
                isEnabled: { $0.editor.hasEditTarget },
            ) { target in
                if target.editor.isCaretInTuplet {
                    target.editor.removeTuplet()
                } else {
                    target.editor.createTuplet(actualNotes: count)
                }
            }
        } + [
            .init(
                "notes.tuplet.remove",
                "mac.menu.notes.tuplet.remove",
                menu: .notes,
                submenu: .tuplet,
                isEnabled: { $0.editor.isCaretInTuplet },
            ) { $0.editor.removeTuplet() },
        ]
    }

    /// The voice a written note lands in. Not mutating: choosing a voice writes nothing, and staying live during
    /// playback costs nothing (§6.2 closes the writes, not the state the next write will use).
    private static var voiceCommands: [MacEditingCommand] {
        (1 ... 4).map { voice in
            .init(
                "notes.voice.\(voice)", "mac.menu.notes.voice.\(voice)",
                menu: .notes, submenu: .voice, key: KeyEquivalent(Character("\(voice)")),
                modifiers: [.command, .option], mutating: false,
            ) { $0.editor.activeVoice = voice - 1 }
        }
    }

    // MARK: Measures

    /// "Add Measures…" raises `EditorAddMeasuresSheet`, which offers both placements — at the end and before the
    /// target bar — so design §5.1's "Insert measures before…" is that sheet and not a menu row of its own.
    private static let measures: [MacEditingCommand] = [
        .init("measures.append", "mac.menu.measures.append", menu: .measures) { $0.editor.appendMeasure() },
        .init("measures.append.many", "mac.menu.measures.appendMany", menu: .measures) {
            $0.editor.isAddMeasuresSheetPresented = true
        },
        .init(
            "measures.insertBefore",
            "mac.menu.measures.insertBefore",
            menu: .measures,
            isEnabled: { $0.editor.targetMeasureIndex != nil },
        ) { $0.editor.insertMeasureBeforeTarget() },
        .init(
            "measures.delete",
            "mac.menu.measures.delete",
            menu: .measures,
            isEnabled: { $0.editor.targetMeasureIndex != nil },
        ) { $0.editor.deleteTargetMeasure() },
        .init(
            "measures.keySignature",
            "mac.menu.measures.keySignature",
            menu: .measures,
            isEnabled: { $0.editor.targetMeasureIndex != nil && $0.editor.targetConcertKey != nil },
        ) {
            $0.editor.isKeySignatureSheetPresented = true
        },
        .init(
            "measures.timeSignature",
            "mac.menu.measures.timeSignature",
            menu: .measures,
            isEnabled: { $0.editor.targetMeasureIndex != nil },
        ) { $0.editor.isTimeSignatureSheetPresented = true },
        .init(
            "measures.rehearsalMark",
            "mac.menu.measures.rehearsalMark",
            menu: .measures,
            isEnabled: { $0.editor.targetMeasureIndex != nil },
        ) { $0.editor.isRehearsalMarkSheetPresented = true },
    ]

    // MARK: Score

    private static let score: [MacEditingCommand] = [
        .init("score.instruments", "mac.menu.score.instruments", menu: .score, key: "i") {
            $0.editor.isInstrumentsSheetPresented = true
        },
        .init(
            "score.drumLayout",
            "mac.menu.score.drumLayout",
            menu: .score,
            isEnabled: { $0.editor.isDrumStaffActive },
        ) { $0.editor.isDrumLayoutSheetPresented = true },
    ]
}
