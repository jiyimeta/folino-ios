import Foundation

/// A persisted entry in folino's library. The actual score bytes live on disk at
/// `AppPaths.scoresDirectory/localFileName` (the resolution to absolute URL happens in Infrastructure, not Domain).
///
/// `format` is intentionally NOT stored: callers derive it via `ScoreFormat.detect(filename: item.localFileName)`. The
/// convention `localFileName == "<id>.<canonical-extension>"` is enforced at import time.
public struct ScoreItem: Hashable, Sendable, Codable, Identifiable {
    public let id: ScoreItemID
    public var title: String
    public var subtitle: String?
    public var composer: String?
    public var arranger: String?
    public var lyricist: String?
    public var copyright: String?
    public var instrumentationSummary: String?
    /// Filename relative to the scores directory. Convention: `<id>.<canonical-extension>`.
    public var localFileName: String
    /// SHA-256 hex digest of the on-disk file bytes, computed at import time. Used for duplicate detection.
    /// Recomputed when note editing rewrites the file; rebuilt via the memberwise initializer because the field is
    /// immutable per instance.
    public let contentHash: String
    public var sizeBytes: Int64
    public var lengthBeats: Int
    public var defaultTempoBpm: Int
    public var primaryKey: String?
    public let addedAt: Date
    public var lastOpenedAt: Date?
    public var tagIDs: Set<TagID>
    public var isFavorite: Bool
    /// When non-nil, the item has been soft-deleted at this timestamp and lives only in the "Recently Deleted" view
    /// until it is restored or auto-purged after 30 days. The repository surfaces these rows via `deletedScoreItems`
    /// and excludes them from `scoreItems`, so non-trash callers never see them.
    public var deletedAt: Date?
    /// Major version of the MuseScore wire format detected at import time (2, 3, or 4 for `.mscx`/`.mscz` files).
    /// `nil` for non-MuseScore formats (MusicXML, MIDI, PDF) and for rows imported before this field was introduced.
    /// Analytics treats `nil` as v4 — the current default — so no backfill is required for existing rows.
    public var museScoreMajorVersion: Int?
    /// The original PDF this item was read from, as `<id>.pdf` in the scores directory. Non-nil for every PDF-origin
    /// item — both one still displayed as a PDF and one that has been read into notation.
    public var sourcePDFFileName: String?
    /// SHA-256 of the original PDF's bytes. Duplicate detection matches this as well as `contentHash`, so re-importing
    /// the same PDF is still recognized after the item's own bytes became an `.mscz`.
    public var sourcePDFContentHash: String?
    /// `contentHash` of the `.mscz` exactly as the conversion wrote it. `contentHash` drifting away from this value is
    /// the definition of "the user edited the score".
    public var pdfDerivedContentHash: String?
    /// The last conversion attempt failed, or produced nothing playable. Keeps the Reader from re-running an expensive
    /// OMR pass on every open; an explicit re-read clears it.
    public var pdfConversionFailed: Bool
    /// The file holding this item's original bytes, in the scores directory, or `nil` when nothing has been captured.
    /// Usually `<id>.original.<ext>`, but for a MusicXML / MXL / MIDI import it is the source file itself — the
    /// column names a file, not a pattern, exactly as `sourcePDFFileName` does.
    public var originalFileName: String?
    /// SHA-256 of `originalFileName`'s bytes, in the importer's hex-digest format. Verifies a restore, answers "has
    /// this been edited" without touching disk, and joins duplicate detection.
    public var originalContentHash: String?
    /// What those bytes are. Non-nil with a `nil` `originalFileName` for a row the v18 migration pre-stamped as
    /// predating this feature; capture keeps that value.
    public var originalProvenance: OriginalProvenance?

    public init(
        id: ScoreItemID = ScoreItemID(),
        title: String,
        subtitle: String? = nil,
        composer: String?,
        arranger: String? = nil,
        lyricist: String? = nil,
        copyright: String? = nil,
        instrumentationSummary: String?,
        localFileName: String,
        contentHash: String,
        sizeBytes: Int64,
        lengthBeats: Int,
        defaultTempoBpm: Int,
        primaryKey: String?,
        addedAt: Date,
        lastOpenedAt: Date?,
        tagIDs: Set<TagID>,
        isFavorite: Bool,
        deletedAt: Date? = nil,
        museScoreMajorVersion: Int? = nil,
        sourcePDFFileName: String? = nil,
        sourcePDFContentHash: String? = nil,
        pdfDerivedContentHash: String? = nil,
        pdfConversionFailed: Bool = false,
        originalFileName: String? = nil,
        originalContentHash: String? = nil,
        originalProvenance: OriginalProvenance? = nil,
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.composer = composer
        self.arranger = arranger
        self.lyricist = lyricist
        self.copyright = copyright
        self.instrumentationSummary = instrumentationSummary
        self.localFileName = localFileName
        self.contentHash = contentHash
        self.sizeBytes = sizeBytes
        self.lengthBeats = lengthBeats
        self.defaultTempoBpm = defaultTempoBpm
        self.primaryKey = primaryKey
        self.addedAt = addedAt
        self.lastOpenedAt = lastOpenedAt
        self.tagIDs = tagIDs
        self.isFavorite = isFavorite
        self.deletedAt = deletedAt
        self.museScoreMajorVersion = museScoreMajorVersion
        self.sourcePDFFileName = sourcePDFFileName
        self.sourcePDFContentHash = sourcePDFContentHash
        self.pdfDerivedContentHash = pdfDerivedContentHash
        self.pdfConversionFailed = pdfConversionFailed
        self.originalFileName = originalFileName
        self.originalContentHash = originalContentHash
        self.originalProvenance = originalProvenance
    }

    /// Hand-written so a payload encoded before the PDF-origin fields existed still decodes: `pdfConversionFailed` is
    /// the only non-optional addition, and a synthesized decoder would throw `keyNotFound` on it. Everything else
    /// decodes exactly as the synthesized version would.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: c.decode(ScoreItemID.self, forKey: .id),
            title: c.decode(String.self, forKey: .title),
            subtitle: c.decodeIfPresent(String.self, forKey: .subtitle),
            composer: c.decodeIfPresent(String.self, forKey: .composer),
            arranger: c.decodeIfPresent(String.self, forKey: .arranger),
            lyricist: c.decodeIfPresent(String.self, forKey: .lyricist),
            copyright: c.decodeIfPresent(String.self, forKey: .copyright),
            instrumentationSummary: c.decodeIfPresent(String.self, forKey: .instrumentationSummary),
            localFileName: c.decode(String.self, forKey: .localFileName),
            contentHash: c.decode(String.self, forKey: .contentHash),
            sizeBytes: c.decode(Int64.self, forKey: .sizeBytes),
            lengthBeats: c.decode(Int.self, forKey: .lengthBeats),
            defaultTempoBpm: c.decode(Int.self, forKey: .defaultTempoBpm),
            primaryKey: c.decodeIfPresent(String.self, forKey: .primaryKey),
            addedAt: c.decode(Date.self, forKey: .addedAt),
            lastOpenedAt: c.decodeIfPresent(Date.self, forKey: .lastOpenedAt),
            tagIDs: c.decode(Set<TagID>.self, forKey: .tagIDs),
            isFavorite: c.decode(Bool.self, forKey: .isFavorite),
            deletedAt: c.decodeIfPresent(Date.self, forKey: .deletedAt),
            museScoreMajorVersion: c.decodeIfPresent(Int.self, forKey: .museScoreMajorVersion),
            sourcePDFFileName: c.decodeIfPresent(String.self, forKey: .sourcePDFFileName),
            sourcePDFContentHash: c.decodeIfPresent(String.self, forKey: .sourcePDFContentHash),
            pdfDerivedContentHash: c.decodeIfPresent(String.self, forKey: .pdfDerivedContentHash),
            pdfConversionFailed: c.decodeIfPresent(Bool.self, forKey: .pdfConversionFailed) ?? false,
            originalFileName: c.decodeIfPresent(String.self, forKey: .originalFileName),
            originalContentHash: c.decodeIfPresent(String.self, forKey: .originalContentHash),
            originalProvenance: c.decodeIfPresent(OriginalProvenance.self, forKey: .originalProvenance),
        )
    }
}
