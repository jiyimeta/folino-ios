import CoreGraphics
@testable import Reader
import Testing

struct TransportCardMetricsTests {
    /// A phone-width container with the expanded card already measured.
    private func metrics(
        morph: Double,
        availableWidth: CGFloat = 393,
        isInPlaylist: Bool = false,
        measuredExpandedHeight: CGFloat? = 114,
    ) -> TransportCardMetrics {
        TransportCardMetrics(
            morph: morph,
            availableWidth: availableWidth,
            isInPlaylist: isInPlaylist,
            measuredExpandedHeight: measuredExpandedHeight,
        )
    }

    @Test func `shut, the card is exactly its buttons`() {
        let compact = metrics(morph: 0)
        #expect(compact.width == 4 * TransportCardMetrics.buttonWidth)
        #expect(compact.height == TransportCardMetrics.collapsedHeight)
        #expect(compact.horizontalPadding == 0)
        #expect(compact.topPadding == 0)
        #expect(compact.triadSpacing == 0)
        #expect(compact.playWidth == TransportCardMetrics.buttonWidth)
        #expect(compact.trailingPlaceholderWidth == 0)
        #expect(compact.trailingInset == TransportCardMetrics.compactMargin)
        #expect(!compact.showsSeekRegion)
    }

    @Test func `a playlist pill is one button wider`() {
        #expect(metrics(morph: 0, isInPlaylist: true).width == 5 * TransportCardMetrics.buttonWidth)
    }

    @Test func `fully open, the card spans the width inside its margins`() {
        let expanded = metrics(morph: 1)
        #expect(expanded.width == 393 - 2 * TransportCardMetrics.cardMargin)
        #expect(expanded.height == 114)
        #expect(expanded.horizontalPadding == TransportCardMetrics.expandedHorizontalPadding)
        #expect(expanded.topPadding == TransportCardMetrics.expandedTopPadding)
        #expect(expanded.triadSpacing == TransportCardMetrics.expandedTriadSpacing)
        #expect(expanded.playWidth == TransportCardMetrics.expandedPlayWidth)
        #expect(expanded.playGlyphScale == 1)
        #expect(expanded.trailingInset == TransportCardMetrics.cardMargin)
        #expect(expanded.showsSeekRegion)
        #expect(expanded.seekRegionOpacity == 1)
    }

    @Test func `on a wide screen the open card stops growing and centers`() {
        let expanded = metrics(morph: 1, availableWidth: 1024)
        #expect(expanded.width == TransportCardMetrics.maxCardWidth)
        #expect(expanded.trailingInset == (1024 - TransportCardMetrics.maxCardWidth) / 2)
    }

    @Test func `half way, every measurement is half way`() throws {
        let half = metrics(morph: 0.5)
        let compact = metrics(morph: 0)
        let expanded = metrics(morph: 1)

        let compactWidth = try #require(compact.width)
        let expandedWidth = try #require(expanded.width)
        let compactHeight = try #require(compact.height)
        let expandedHeight = try #require(expanded.height)
        #expect(half.width == (compactWidth + expandedWidth) / 2)
        #expect(half.height == (compactHeight + expandedHeight) / 2)
        #expect(half.horizontalPadding == TransportCardMetrics.expandedHorizontalPadding / 2)
        #expect(half.playWidth == (TransportCardMetrics.buttonWidth + TransportCardMetrics.expandedPlayWidth) / 2)
        #expect(half.trailingInset == (compact.trailingInset + expanded.trailingInset) / 2)
    }

    @Test func `the seek region is mounted the moment the card starts opening`() {
        #expect(!metrics(morph: 0).showsSeekRegion)
        #expect(metrics(morph: 0.01).showsSeekRegion)
        #expect(metrics(morph: 0.01).seekRegionOpacity == 0.01)
    }

    @Test func `a settled card carries exactly one glass layer`() {
        let compact = metrics(morph: 0)
        #expect(!compact.showsExpandedGlass)
        #expect(compact.showsCompactGlass)
        #expect(compact.compactGlassOpacity == 1)

        let expanded = metrics(morph: 1)
        #expect(expanded.showsExpandedGlass)
        #expect(!expanded.showsCompactGlass)
        #expect(expanded.expandedGlassOpacity == 1)
    }

    @Test func `mid-morph the two glass layers crossfade on the morph itself`() {
        let half = metrics(morph: 0.5)
        #expect(half.showsExpandedGlass)
        #expect(half.showsCompactGlass)
        #expect(half.expandedGlassOpacity == 0.5)
        #expect(half.compactGlassOpacity == 0.5)
    }

    @Test func `morph is clamped, so an overshooting spring cannot invert the layout`() {
        #expect(metrics(morph: 1.4).width == metrics(morph: 1).width)
        #expect(metrics(morph: -0.4).width == metrics(morph: 0).width)
        #expect(metrics(morph: -0.4).horizontalPadding == 0)
    }

    @Test func `an unmeasured open card is left to size itself`() {
        #expect(metrics(morph: 1, measuredExpandedHeight: nil).height == nil)
        #expect(metrics(morph: 0, measuredExpandedHeight: nil).height == TransportCardMetrics.collapsedHeight)
    }

    @Test func `an unmeasured container leaves the open card to take what it is offered`() {
        #expect(metrics(morph: 1, availableWidth: 0).width == nil)
        #expect(metrics(morph: 0, availableWidth: 0).width == 4 * TransportCardMetrics.buttonWidth)
    }

    /// The row has to fit inside the card at *every* point of the morph, or the flexible frames either side of the
    /// centered triad would be squeezed and the buttons would jitter as the card resizes.
    @Test func `the transport row fits the card all the way through the morph`() throws {
        for step in 0 ... 20 {
            let m = metrics(morph: Double(step) / 20)
            let triad = TransportCardMetrics.buttonWidth * 2 + m.playWidth + m.triadSpacing * 2
            let content = TransportCardMetrics.buttonWidth
                + triad
                + m.trailingPlaceholderWidth
                + m.horizontalPadding * 2
            let width = try #require(m.width)
            #expect(content <= width, "content \(content) exceeded card \(width) at morph \(m.morph)")
        }
    }
}
