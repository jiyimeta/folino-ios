import Domain
import Editor
import SheetMusicCore
import SwiftUI

/// The whole editing vocabulary of the app, declared once (design §5). Ⅳb generalizes this table into the command
/// registry; it does not replace it, so ids are stable names and not display order.
enum AppCommandCatalog {
    /// Most rows need an editor and do nothing without one. `editorRow` wraps the pair so a row still reads
    /// as a single declaration. Not `private`: `AppCommandCatalog+MeasuresAndScore.swift`'s extension calls it
    /// too, and `private` is file-scoped rather than type-scoped.
    static func editorRow(
        _ id: String, _ titleKey: String, menu: AppCommandMenu, submenu: AppCommandSubmenu? = nil,
        key: KeyEquivalent? = nil, alternateKeys: [KeyEquivalent] = [], modifiers: EventModifiers = [],
        mutating: Bool = true,
        isEnabled: @escaping @MainActor @Sendable (EditorViewModel) -> Bool = { _ in true },
        perform: @escaping @MainActor @Sendable (EditorViewModel) -> Void,
    ) -> AppCommand {
        AppCommand(
            id, titleKey, menu: menu, submenu: submenu, key: key, alternateKeys: alternateKeys,
            modifiers: modifiers, mutating: mutating,
            isEnabled: { context in context.editor.map(isEnabled) ?? false },
            perform: { context in context.editor.map(perform) },
        )
    }

    static func commands(in menu: AppCommandMenu) -> [AppCommand] {
        current.filter { $0.menu == menu }
    }

    /// The rows of `menu` that sit at its top level, in table order.
    static func topLevelCommands(in menu: AppCommandMenu) -> [AppCommand] {
        commands(in: menu).filter { $0.submenu == nil }
    }

    /// The submenus `menu` needs, in the order their first row appears in the table.
    static func submenus(in menu: AppCommandMenu) -> [AppCommandSubmenu] {
        var seen: [AppCommandSubmenu] = []
        for command in commands(in: menu) {
            if let submenu = command.submenu, !seen.contains(submenu) {
                seen.append(submenu)
            }
        }
        return seen
    }

    static func commands(in menu: AppCommandMenu, submenu: AppCommandSubmenu) -> [AppCommand] {
        commands(in: menu).filter { $0.submenu == submenu }
    }

    /// The rows this platform has. `all` stays unfiltered so the tests can assert about the whole table.
    static var current: [AppCommand] {
        filtered(all, for: AppCommandPlatform.current)
    }

    /// The filter `current` applies, pulled out as a pure function so a test can exercise it against a small
    /// fixture table instead of `all` — asserting against the real (and currently coincidental) shape of `all`
    /// would pass even if this filter were deleted entirely, since today's only Mac-only rows carry no bare key.
    static func filtered(_ commands: [AppCommand], for platform: AppCommandPlatform) -> [AppCommand] {
        commands.filter { $0.platforms.contains(platform) }
    }

    static let all: [AppCommand] = file + edit + notes + measures + score + shell + view

    // MARK: File (design §5.3)

    /// Both rows are `mutating`, unlike the rest of the File menu: they rewrite the score wholesale, which is
    /// exactly what §6.2 closes off while the transport runs — a revert under a running cursor would leave the
    /// engine reading a score that no longer exists. Both sit in the Revert To submenu (`AppCommandMenus` splits it
    /// out) so the File menu's top level can also carry the shell's own rows (`shell`, below) without mixing the two
    /// kinds together.
    private static let file: [AppCommand] = [
        .init(
            "file.revert.lastOpened",
            "mac.menu.revert.lastOpened",
            menu: .file,
            submenu: .revertTo,
            isEnabled: { $0.editor?.sessionHasEdits ?? false },
        ) { $0.confirmDiscard() },
        .init(
            "file.revert.original",
            "mac.menu.revert.original",
            menu: .file,
            submenu: .revertTo,
            isEnabled: { $0.editor?.canRevertToOriginal ?? false },
        ) { $0.confirmRevert() },
    ]

    // MARK: Edit

    private static let edit: [AppCommand] = [
        editorRow(
            "edit.deselect",
            "mac.menu.edit.deselect",
            menu: .edit,
            key: .escape,
            mutating: false,
            isEnabled: { $0.selectedItem != nil },
        ) { $0.deselect() },
        editorRow(
            "edit.previous",
            "mac.menu.edit.previousElement",
            menu: .edit,
            key: .leftArrow,
            mutating: false,
            isEnabled: { $0.hasEditTarget },
        ) { $0.selectPreviousElement() },
        editorRow(
            "edit.next",
            "mac.menu.edit.nextElement",
            menu: .edit,
            key: .rightArrow,
            mutating: false,
            isEnabled: { $0.hasEditTarget },
        ) { $0.selectNextElement() },
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

    private static let notes: [AppCommand] = pitchCommands + durationCommands + [
        editorRow(
            "notes.rest",
            "mac.menu.notes.rest",
            menu: .notes,
            key: "0",
            isEnabled: { $0.canWriteRest },
        ) { $0.writeRest() },
        editorRow(
            "notes.dot",
            "mac.menu.notes.dot",
            menu: .notes,
            key: ".",
            isEnabled: { $0.hasEditTarget },
        ) { editor in
            // With a note selected the dot lands on it; with only a caret it arms the next note written, which is
            // the pair design §5.1 names (`setSelectionDots` / `setArmedDots`).
            if editor.selectedItem != nil {
                editor.toggleSelectionDot()
            } else {
                editor.toggleArmedDot()
            }
        },
        editorRow(
            "notes.dot.double",
            "mac.menu.notes.dot.double",
            menu: .notes,
            key: ".",
            modifiers: .option,
            isEnabled: { $0.hasEditTarget },
        ) { editor in
            if editor.selectedItem != nil {
                editor.setSelectionDots(2)
            } else {
                editor.setArmedDots(2)
            }
        },
        editorRow(
            "notes.pitch.up",
            "mac.menu.notes.pitch.up",
            menu: .notes,
            key: .upArrow,
            isEnabled: { $0.isNoteSelected },
        ) { $0.shiftPitch(bySemitones: 1) },
        editorRow(
            "notes.pitch.down",
            "mac.menu.notes.pitch.down",
            menu: .notes,
            key: .downArrow,
            isEnabled: { $0.isNoteSelected },
        ) { $0.shiftPitch(bySemitones: -1) },
        editorRow(
            "notes.octave.up",
            "mac.menu.notes.octave.up",
            menu: .notes,
            key: .upArrow,
            modifiers: .command,
            isEnabled: { $0.isNoteSelected },
        ) { $0.shiftOctave(by: 1) },
        editorRow(
            "notes.octave.down",
            "mac.menu.notes.octave.down",
            menu: .notes,
            key: .downArrow,
            modifiers: .command,
            isEnabled: { $0.isNoteSelected },
        ) { $0.shiftOctave(by: -1) },
        editorRow(
            "notes.tie",
            "mac.menu.notes.tie",
            menu: .notes,
            key: "+",
            isEnabled: { $0.canTie },
        ) { $0.toggleTie() },
        editorRow(
            "notes.tie.append",
            "mac.menu.notes.tiedNote",
            menu: .notes,
            isEnabled: { $0.canAppendTiedNote },
        ) { $0.appendTiedNote() },
        editorRow(
            "notes.delete",
            "mac.menu.notes.delete",
            menu: .notes,
            key: .delete,
            alternateKeys: [.deleteForward],
            isEnabled: { $0.selectedItem != nil },
        ) { $0.deleteSelection() },
    ] + accidentalCommands + chordCommands + tupletCommands + voiceCommands

    /// A–G write a pitch at the caret.
    ///
    /// **Disabled on a drum staff rather than routed to `pressDrumKey`.** Design §5.1 describes the letters going to
    /// the kit's own `DrumsetEntry.shortcut` there, but nothing in the app can resolve a letter to a key today:
    /// `DrumPadKey` carries no shortcut, and `GMDrumset`'s stock entries — the kit every folino-authored drum part
    /// gets — define none, so the mapping would be empty for every score that did not arrive from a MuseScore file
    /// with a hand-written `<shortcut>`. The pad that owns drum entry is Ⅳc; the second half of that same spec
    /// paragraph ("the Notes menu shows the pitch commands disabled on a drum staff") is what Ⅳa implements.
    private static var pitchCommands: [AppCommand] {
        pitchLetters.map { letter in
            editorRow(
                "notes.pitch.\(letter)", "mac.menu.notes.pitch.\(letter)",
                menu: .notes, submenu: .pitch, key: KeyEquivalent(letter),
                isEnabled: { $0.hasEditTarget && !$0.isDrumStaffActive },
            ) { $0.inputPitch(letter: letter) }
        }
    }

    private static var durationCommands: [AppCommand] {
        durations.map { digit, duration, name in
            editorRow(
                "notes.duration.\(name)", "mac.menu.notes.duration.\(name)",
                menu: .notes, submenu: .duration, key: KeyEquivalent(digit),
                isEnabled: { $0.hasEditTarget },
            ) { editor in
                // With something selected the digit re-times it; with only a caret it arms the next note.
                if editor.selectedItem != nil {
                    editor.setSelectionDuration(duration)
                } else {
                    editor.setDuration(duration)
                }
            }
        }
    }

    private static var accidentalCommands: [AppCommand] {
        accidentals.map { accidental, name in
            editorRow(
                "notes.accidental.\(name)", "mac.menu.notes.accidental.\(name)",
                menu: .notes, submenu: .accidental,
                isEnabled: { $0.isNoteSelected },
            ) { $0.setAccidental(accidental) }
        }
    }

    /// ⇧A–⇧G add that pitch to the selected chord: arm add-to-chord, write the letter, disarm.
    private static var chordCommands: [AppCommand] {
        pitchLetters.map { letter in
            editorRow(
                "notes.chord.add.\(letter)", "mac.menu.notes.chord.add.\(letter)",
                menu: .notes, submenu: .chord, key: KeyEquivalent(letter), modifiers: .shift,
                isEnabled: { $0.isNoteSelected },
            ) { editor in
                if !editor.isAddToChordArmed {
                    editor.toggleAddToChord()
                }
                editor.inputPitch(letter: letter)
                if editor.isAddToChordArmed {
                    editor.toggleAddToChord()
                }
            }
        } + intervalCommands + [
            editorRow(
                "notes.chord.remove",
                "mac.menu.notes.chord.removeNote",
                menu: .notes,
                submenu: .chord,
                key: .delete,
                modifiers: .shift,
                isEnabled: { $0.isNoteSelected },
            ) { $0.removeSelectedNoteFromChord() },
        ]
    }

    /// `DiatonicInterval` offers a third and an octave, and nothing else — design §5.1's "2nd–9th" describes an
    /// engine command that does not exist. Ⅳd is where the range fills in, from ssm sub-project Ⅰ.
    private static var intervalCommands: [AppCommand] {
        let intervals: [(DiatonicInterval, String)] = [(.third, "third"), (.octave, "octave")]
        return intervals.map { interval, name in
            editorRow(
                "notes.chord.interval.\(name)", "mac.menu.notes.chord.interval.\(name)",
                menu: .notes, submenu: .chord,
                isEnabled: { $0.isNoteSelected },
            ) { $0.addIntervalNote(interval) }
        }
    }

    /// ⌘3–⌘9: MuseScore's tuplet keys. Ⅳc re-homes ⌘3 / ⌘4 to panels (design §6).
    private static var tupletCommands: [AppCommand] {
        (3 ... 9).map { count in
            editorRow(
                "notes.tuplet.\(count)", "mac.menu.notes.tuplet.\(count)",
                menu: .notes, submenu: .tuplet, key: KeyEquivalent(Character("\(count)")), modifiers: .command,
                isEnabled: { $0.hasEditTarget },
            ) { editor in
                if editor.isCaretInTuplet {
                    editor.removeTuplet()
                } else {
                    editor.createTuplet(actualNotes: count)
                }
            }
        } + [
            editorRow(
                "notes.tuplet.remove",
                "mac.menu.notes.tuplet.remove",
                menu: .notes,
                submenu: .tuplet,
                isEnabled: { $0.isCaretInTuplet },
            ) { $0.removeTuplet() },
        ]
    }

    /// The voice a written note lands in. Not mutating: choosing a voice writes nothing, and staying live during
    /// playback costs nothing (§6.2 closes the writes, not the state the next write will use).
    private static var voiceCommands: [AppCommand] {
        (1 ... 4).map { voice in
            editorRow(
                "notes.voice.\(voice)", "mac.menu.notes.voice.\(voice)",
                menu: .notes, submenu: .voice, key: KeyEquivalent(Character("\(voice)")),
                modifiers: [.command, .option], mutating: false,
            ) { $0.activeVoice = voice - 1 }
        }
    }

    // MARK: Measures, Score

    // `measures` and `score` live in `AppCommandCatalog+MeasuresAndScore.swift`; `shell` and `view` (was
    // `MacCommands`) live in `AppCommandCatalog+Shell.swift` — both split out so this file stays under SwiftLint's
    // `file_length` budget. See each file's header comment.
}
