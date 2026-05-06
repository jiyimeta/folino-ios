import Domain
import SwiftUI

struct ScoreRow: View {
    let scoreItem: ScoreItem

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 2) {
                    Text(scoreItem.title)
                        .font(.body)
                        .lineLimit(1)
                    if let subtitle = scoreItem.subtitle, !subtitle.isEmpty {
                        Text("- \(subtitle)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                if let composer = scoreItem.composer, !composer.isEmpty {
                    Text(composer)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if scoreItem.isFavorite {
                Image(systemName: "star.fill")
                    .foregroundStyle(.tint)
                    .accessibilityLabel("Favorite")
            }
        }
        .contentShape(Rectangle())
    }
}

#Preview {
    let withComposer = ScoreItem(
        title: "Sonata in C major",
        subtitle: "Subtitle",
        composer: "W. A. Mozart",
        instrumentationSummary: "Piano",
        localFileName: "x.mscx", contentHash: "x", sizeBytes: 0,
        lengthBeats: 0, defaultTempoBpm: 120, primaryKey: nil,
        addedAt: Date(), lastOpenedAt: nil, tagIDs: [], isFavorite: true
    )
    let onlyTitle = ScoreItem(
        title: "Untitled Score", composer: nil,
        instrumentationSummary: nil,
        localFileName: "y.mscx", contentHash: "y", sizeBytes: 0,
        lengthBeats: 0, defaultTempoBpm: 120, primaryKey: nil,
        addedAt: Date(), lastOpenedAt: nil, tagIDs: [], isFavorite: false
    )
    return List {
        ScoreRow(scoreItem: withComposer)
        ScoreRow(scoreItem: onlyTitle)
    }
}
