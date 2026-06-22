import Foundation

/// A musical position an annotation is pinned to. Pure musical coordinates (Foundation-only); independent of any
/// computed layout, so it survives reflow / staff-size (content-zoom) changes / staff-visibility toggles. The Reader
/// maps between this and on-screen layout points via SheetMusicLayout; Domain stays layout-agnostic.
///
/// The x-coordinate mirrors the playback cursor's tick model (`measureIndex` + `tickInMeasure`) so the same
/// cursor/layout machinery applies. It is deliberately NOT a fraction of the measure width: musical spacing is
/// non-linear, so a uniform fraction has no engine correspondence and no inverse.
public struct MusicalAnchor: Hashable, Codable, Sendable {
    /// Zero-based index of the anchoring measure (stable across reflow).
    public let measureIndex: Int
    /// Tick offset within the measure (stable across reflow).
    public let tickInMeasure: Int
    /// Staff identity (stable across reflow), mirroring the engine's StaffAddress.
    public let partIndex: Int
    public let staffIndexInPart: Int
    /// Horizontal offset from the resolved tick column, in staff-spaces (sp). Preserves the relative x of strokes that
    /// snap to the same tick column.
    public let dxSp: Double
    /// Vertical offset from the top line of the staff, in staff-spaces (sp). Positive = downward.
    public let verticalOffsetSp: Double

    public init(
        measureIndex: Int,
        tickInMeasure: Int,
        partIndex: Int,
        staffIndexInPart: Int,
        dxSp: Double,
        verticalOffsetSp: Double,
    ) {
        self.measureIndex = max(0, measureIndex)
        self.tickInMeasure = max(0, tickInMeasure)
        self.partIndex = max(0, partIndex)
        self.staffIndexInPart = max(0, staffIndexInPart)
        self.dxSp = dxSp
        self.verticalOffsetSp = verticalOffsetSp
    }
}
