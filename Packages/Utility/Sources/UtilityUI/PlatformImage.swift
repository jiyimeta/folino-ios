#if os(iOS)
import UIKit

/// The platform's raster image type, for the small amount of shared code that genuinely produces one (annotation ink
/// flattening, the now-playing artwork). Everything else should stay in SwiftUI's `Image`.
public typealias PlatformImage = UIImage
#else
import AppKit

public typealias PlatformImage = NSImage
#endif
