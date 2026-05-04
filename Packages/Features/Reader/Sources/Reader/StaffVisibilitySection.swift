import SheetMusicCore
import SwiftUI

/// One section of the inspector: toggles for every staff in the score.
/// Extracted from `StaffVisibilityInspector` so Plan B can place a
/// Mixer section beside it inside the same inspector container.
struct StaffVisibilitySection: View {
    let score: Score
    let hiddenStaves: Set<StaffAddress>
    let onToggle: (StaffAddress) async -> Void

    var body: some View {
        Section("Staves") {
            ForEach(staffRows, id: \.address) { row in
                Toggle(isOn: Binding(
                    get: { !hiddenStaves.contains(row.address) },
                    set: { _ in Task { await onToggle(row.address) } }
                )) {
                    Text(row.label)
                }
            }
        }
    }

    private var staffRows: [StaffRow] {
        var rows: [StaffRow] = []
        for (partIndex, part) in score.parts.enumerated() {
            for staffIndex in part.staves.indices {
                let address = StaffAddress(
                    partIndex: partIndex,
                    staffIndexInPart: staffIndex
                )
                let label = makeLabel(part: part, staffIndex: staffIndex)
                rows.append(StaffRow(address: address, label: label))
            }
        }
        return rows
    }

    private func makeLabel(part: Part, staffIndex: Int) -> String {
        let base = part.trackName ?? "Staff"
        if part.staves.count > 1 {
            return "\(base) \(staffIndex + 1)"
        }
        return base
    }

    private struct StaffRow {
        let address: StaffAddress
        let label: String
    }
}
