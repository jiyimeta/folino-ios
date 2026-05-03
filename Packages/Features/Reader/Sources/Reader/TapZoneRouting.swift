import CoreGraphics

/// Where a page-mode tap landed, expressed in semantic terms. Tied to
/// `tapZone(forX:width:)` — keep the boundaries in sync with the spec
/// (`docs/superpowers/specs/2026-05-03-reader-v2-design.md`).
public enum PageModeTapZone: Equatable, Sendable {
    case prev
    case chrome
    case next
}

/// Routes a tap location to its semantic page-mode zone. Returns
/// `.chrome` as a safe fallback when `width` is non-positive (e.g. the
/// view hasn't been measured yet).
public func tapZone(forX x: CGFloat, width: CGFloat) -> PageModeTapZone { // swiftlint:disable:this identifier_name
    guard width > 0 else { return .chrome }
    let fraction = x / width
    if fraction < 0.25 { return .prev }
    if fraction < 0.75 { return .chrome }
    return .next
}
