import Wirelet

/// The coach-mark slot as Compose needs to see it. Output of `nativeHintState`.
///
/// Everything here is derived, never decided, on the Kotlin side: which hint is showing and where its control is are
/// the shared `ReaderHintEngine`'s answers, and Compose only draws them.
///
/// Field order is the wire contract — do not reorder.
@WireFormat
public struct ReaderHintStateWire: Equatable {
    /// `ReaderFeatureHint.wireValue`, or `-1` (`ReaderFeatureHint.noHintWireValue`) when nothing is showing.
    public let presentedHint: Int32
    /// Whether the showing hint's control has a live anchor. False (with zeroed rect) when nothing is showing.
    public let hasAnchor: Bool
    public let anchorX: Double
    public let anchorY: Double
    public let anchorWidth: Double
    public let anchorHeight: Double
    /// Monotonic. Bumped when the user taps a transport coach mark, asking the transport to act the swipe out.
    public let transportModeSwitchRequests: Int32
    /// Non-zero == a deferred offer is armed, and the number is its token: a token that CHANGES is a fresh schedule
    /// that must restart the host's timer, and zero is a cancellation. Wirelet has no `nil`, and a bare "is pending"
    /// flag could not tell a re-arm from a schedule that never lapsed.
    public let transportExpandSchedule: Int32
    public let padRestoreSchedule: Int32
    public let padMoveSchedule: Int32
    /// How long the host must wait before calling `nativeHintFireDeferredOffer` for an armed offer.
    public let deferredOfferDelayMillis: Int32

    public init(
        presentedHint: Int32,
        hasAnchor: Bool,
        anchorX: Double,
        anchorY: Double,
        anchorWidth: Double,
        anchorHeight: Double,
        transportModeSwitchRequests: Int32,
        transportExpandSchedule: Int32,
        padRestoreSchedule: Int32,
        padMoveSchedule: Int32,
        deferredOfferDelayMillis: Int32,
    ) {
        self.presentedHint = presentedHint
        self.hasAnchor = hasAnchor
        self.anchorX = anchorX
        self.anchorY = anchorY
        self.anchorWidth = anchorWidth
        self.anchorHeight = anchorHeight
        self.transportModeSwitchRequests = transportModeSwitchRequests
        self.transportExpandSchedule = transportExpandSchedule
        self.padRestoreSchedule = padRestoreSchedule
        self.padMoveSchedule = padMoveSchedule
        self.deferredOfferDelayMillis = deferredOfferDelayMillis
    }
}

/// Where the bubble goes, for one anchor in one viewport. Output of `nativeHintBubbleFrame`.
///
/// Field order is the wire contract — do not reorder.
@WireFormat
public struct ReaderHintBubbleFrameWire: Equatable {
    public let width: Double
    public let originX: Double
    public let caretDX: Double
    /// `ReaderHintPlacement.rawValue` — 0 above the control (caret down), 1 below it (caret up).
    public let placement: Int32
    /// The card's caret-side edge: its top when `placement == 1`, its bottom when `0`.
    public let edgeY: Double

    public init(width: Double, originX: Double, caretDX: Double, placement: Int32, edgeY: Double) {
        self.width = width
        self.originX = originX
        self.caretDX = caretDX
        self.placement = placement
        self.edgeY = edgeY
    }
}

/// Every measurement the Compose bubble is drawn from. Output of `nativeHintBubbleMetrics`, so a padding or a corner
/// radius cannot drift between the two platforms' cards.
///
/// Field order is the wire contract — do not reorder.
@WireFormat
public struct ReaderHintBubbleMetricsWire: Equatable {
    public let caretWidth: Double
    public let caretHeight: Double
    public let cornerRadius: Double
    public let horizontalPadding: Double
    public let verticalPadding: Double
    public let titleMessageSpacing: Double
    public let titleFontSize: Double
    public let messageFontSize: Double
    public let transitionDurationMillis: Int32
    public let transitionScale: Double

    public init(
        caretWidth: Double,
        caretHeight: Double,
        cornerRadius: Double,
        horizontalPadding: Double,
        verticalPadding: Double,
        titleMessageSpacing: Double,
        titleFontSize: Double,
        messageFontSize: Double,
        transitionDurationMillis: Int32,
        transitionScale: Double,
    ) {
        self.caretWidth = caretWidth
        self.caretHeight = caretHeight
        self.cornerRadius = cornerRadius
        self.horizontalPadding = horizontalPadding
        self.verticalPadding = verticalPadding
        self.titleMessageSpacing = titleMessageSpacing
        self.titleFontSize = titleFontSize
        self.messageFontSize = messageFontSize
        self.transitionDurationMillis = transitionDurationMillis
        self.transitionScale = transitionScale
    }
}
