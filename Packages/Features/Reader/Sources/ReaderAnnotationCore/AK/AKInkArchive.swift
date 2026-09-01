import CoreGraphics
import Foundation

/// The `NSKeyedArchiver` archive Apple stores its ink annotation in.
///
/// The object being encoded is `AKInkAnnotation2`, a class in the private AnnotationKit framework that is
/// absent from the iOS SDK, so it cannot be instantiated. The archive format is public, though: a shim class
/// encodes the same keys, and `setClassName` makes the archive claim Apple's name for it.
///
/// Writing the plist by hand does not work. `PropertyListSerialization` keeps a `["CF$UID": n]` dictionary as
/// an ordinary dictionary — it never becomes a binary-plist UID — so the result is not a keyed archive at all.
///
/// The scalars that are not geometry are carried verbatim from a real sample. `originalModelBaseScaleFactor`
/// in particular is not the canvas-to-page ratio and its role is unexplained; it is copied, not computed.
public enum AKInkArchive {
    /// Encodes the keys Apple's object carries. Named for what it is: this is not AnnotationKit's class, it
    /// just serializes to the same shape. The name it archives under is set on the archiver, deliberately not
    /// with `@objc(AKInkAnnotation2)` — PDFKit may load the real AnnotationKit into this process, and
    /// registering a duplicate Objective-C class name there is a hazard.
    ///
    /// A Swift nested type has no stable Objective-C runtime name of its own, though, and `NSCoding` archiving
    /// requires one; `FolinoAKInkAnnotation2Shim` fills that requirement without colliding with anything
    /// AnnotationKit owns. It is this class's own runtime identity, never written to the archive —
    /// `setClassName` below is what makes the archive claim Apple's name instead.
    @objc(FolinoAKInkAnnotation2Shim)
    private final class Shim: NSObject, NSCoding {
        let rectangle: NSMutableDictionary
        let drawingSize: NSMutableDictionary
        let uuid: String
        let drawing: Data

        init(rectangle: NSMutableDictionary, drawingSize: NSMutableDictionary, uuid: String, drawing: Data) {
            self.rectangle = rectangle
            self.drawingSize = drawingSize
            self.uuid = uuid
            self.drawing = drawing
        }

        /// Never called: this type is encode-only, and `NSKeyedArchiver` never decodes what it archives.
        required init?(coder: NSCoder) {
            nil
        }

        func encode(with coder: NSCoder) {
            coder.encode(rectangle, forKey: "rectangle")
            coder.encode(drawingSize, forKey: "drawingSize")
            coder.encode(uuid, forKey: "UUID")
            coder.encode(drawing, forKey: "drawing")
            coder.encode(2, forKey: "akPlat")
            coder.encode(2, forKey: "akVers")
            coder.encode(0, forKey: "formContentType")
            coder.encode(1, forKey: "originalExifOrientation")
            coder.encode(0.7997311827956989, forKey: "originalModelBaseScaleFactor")
            coder.encode(false, forKey: "AKIsFormFieldKey")
            coder.encode(true, forKey: "editsDisableAppearanceOverride")
            coder.encode(true, forKey: "shouldUsePlaceholderText")
            coder.encode(false, forKey: "textIsClipped")
            coder.encode(false, forKey: "textIsFixedHeight")
            coder.encode(false, forKey: "textIsFixedWidth")
            // Every accepted archive in this investigation carries this key, pointing at the archive's
            // `$null` placeholder object; ours is otherwise the only one without it. Encoding `nil` here is
            // what reproduces that: `NSKeyedArchiver` writes an explicit `$null` reference rather than
            // omitting the key, matching Apple's archive rather than merely resembling it.
            coder.encode(nil as Any?, forKey: "customPlaceholderText")
        }
    }

    enum ArchiveError: Error { case malformedArchive }

    public static func archive(
        payload: Data, archiveRect: CGRect, drawingSize: CGSize, uuid: UUID, deflater: Deflating,
    ) throws -> Data {
        let shim = try Shim(
            rectangle: [
                "X": archiveRect.origin.x, "Y": archiveRect.origin.y,
                "Width": archiveRect.width, "Height": archiveRect.height,
            ],
            drawingSize: ["Width": drawingSize.width, "Height": drawingSize.height],
            uuid: uuid.uuidString,
            drawing: GzipWriter.gzip(payload, using: deflater),
        )

        let archiver = NSKeyedArchiver(requiringSecureCoding: false)
        archiver.setClassName("AKInkAnnotation2", for: Shim.self)
        archiver.encode(shim, forKey: NSKeyedArchiveRootObjectKey)
        archiver.finishEncoding()

        return try addingClassHierarchy(to: archiver.encodedData)
    }

    /// `setClassName` writes only `$classname`; Apple's archive carries `$classes` as well, and no accepted
    /// device test has ever run without it. Rather than find out on a device — which costs a person a round —
    /// insert it. The UIDs survive this round trip; `NSKeyedUnarchiver` accepts the rewritten archive.
    private static func addingClassHierarchy(to data: Data) throws -> Data {
        guard var plist = try PropertyListSerialization
            .propertyList(from: data, options: [.mutableContainers], format: nil) as? [String: Any],
            var objects = plist["$objects"] as? [Any]
        else { throw ArchiveError.malformedArchive }

        for (i, object) in objects.enumerated() {
            guard var entry = object as? [String: Any],
                  entry["$classname"] as? String == "AKInkAnnotation2" else { continue }
            entry["$classes"] = ["AKInkAnnotation2", "AKInkAnnotation", "AKAnnotation", "NSObject"]
            objects[i] = entry
        }
        plist["$objects"] = objects

        return try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
    }
}
