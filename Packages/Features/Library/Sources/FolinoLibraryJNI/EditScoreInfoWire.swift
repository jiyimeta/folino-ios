import Wirelet

/// Snapshot the Android edit-info screen loads to pre-fill its fields plus read-only info.
/// `source` is a display label ("MuseScore 4" / "MusicXML" / "MIDI" / "PDF") or "" when unknown.
/// `addedAt` is Unix seconds (0 when unavailable).
@WireFormat
public struct EditScoreInfoWire: Equatable, Sendable {
    public var title: String
    public var subtitle: String
    public var composer: String
    public var arranger: String
    public var lyricist: String
    public var copyright: String
    public var source: String
    public var addedAt: Double

    public init(
        title: String, subtitle: String, composer: String, arranger: String,
        lyricist: String, copyright: String, source: String, addedAt: Double,
    ) {
        self.title = title
        self.subtitle = subtitle
        self.composer = composer
        self.arranger = arranger
        self.lyricist = lyricist
        self.copyright = copyright
        self.source = source
        self.addedAt = addedAt
    }
}
