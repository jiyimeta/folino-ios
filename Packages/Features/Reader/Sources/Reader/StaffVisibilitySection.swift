import SheetMusicCore
import SwiftUI

/// One section of the inspector: toggles for every staff in the score.
/// Extracted from `StaffVisibilityInspector` so Plan B can place a
/// Mixer section beside it inside the same inspector container.
struct StaffVisibilitySection: View {
    let score: Score
    let hiddenStaffIDs: Set<Int>
    let onToggle: (Int) async -> Void
    let onShowAll: () async -> Void
    let onHideAll: ([Int]) async -> Void

    var body: some View {
        Section("Staves") {
            ForEach(staffRows, id: \.id) { row in
                Toggle(isOn: Binding(
                    get: { !hiddenStaffIDs.contains(row.id) },
                    set: { _ in Task { await onToggle(row.id) } }
                )) {
                    Text(row.label)
                }
            }
            HStack {
                Button("Show All") { Task { await onShowAll() } }
                Spacer()
                Button("Hide All") {
                    Task { await onHideAll(staffRows.map(\.id)) }
                }
            }
        }
    }

    private var staffRows: [StaffRow] {
        // Walk parts in order, advancing through their staff declarations
        // and pairing each with the corresponding `StaffContent.id`.
        var rows: [StaffRow] = []
        var staffCursor = 0
        for part in score.parts {
            for declIndex in 0 ..< part.staffDeclarations.count {
                guard staffCursor < score.staves.count else { break }
                let id = score.staves[staffCursor].id
                let label = makeLabel(part: part, declIndex: declIndex)
                rows.append(StaffRow(id: id, label: label))
                staffCursor += 1
            }
        }
        return rows
    }

    private func makeLabel(part: Part, declIndex: Int) -> String {
        let base = part.trackName ?? "Staff"
        if part.staffDeclarations.count > 1 {
            return "\(base) \(declIndex + 1)"
        }
        return base
    }

    private struct StaffRow {
        let id: Int
        let label: String
    }
}
