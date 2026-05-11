import Domain
import SwiftUI

struct ScoreRow: View {
    let scoreItem: ScoreItem

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(titleText) \(subtitleText)")
                .lineLimit(1)
                .overlay(alignment: .leading) {
                    if scoreItem.isFavorite {
                        Image(systemName: "star.fill")
                            .font(.system(size: 7))
                            .foregroundStyle(.tint)
                            .offset(x: -12)
                            .accessibilityLabel(Text("library.score.favorite.action", bundle: .module))
                    }
                }
            if let composer = scoreItem.composer, !composer.isEmpty {
                Text(composer)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var titleText: Text {
        Text(scoreItem.title)
            .font(.headline)
    }

    private var subtitleText: Text {
        Text(scoreItem.subtitle ?? "")
            .font(.subheadline)
            .foregroundStyle(.secondary)
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
        addedAt: Date(), lastOpenedAt: nil, tagIDs: [], isFavorite: true,
    )
    let onlyTitle = ScoreItem(
        title: "Untitled Score", composer: nil,
        instrumentationSummary: nil,
        localFileName: "y.mscx", contentHash: "y", sizeBytes: 0,
        lengthBeats: 0, defaultTempoBpm: 120, primaryKey: nil,
        addedAt: Date(), lastOpenedAt: nil, tagIDs: [], isFavorite: false,
    )
    return List {
        ScoreRow(scoreItem: withComposer)
        ScoreRow(scoreItem: onlyTitle)
    }
}
