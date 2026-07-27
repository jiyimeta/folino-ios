import Wirelet

/// One drum kit as it crosses to Kotlin: the bank-128 program, its display name, and its family's index into
/// `Domain.GMDrumKit.Family.allCases` so the host can group the picker without knowing the family names.
///
/// Mirrors how ssm ships `GMInstrument` — Swift owns the catalog, Kotlin loads it once over JNI and caches it. The
/// alternative, a hand-maintained Kotlin copy of the kit table, would drift from the SF2 split's actual presets and
/// silently offer kits that resolve to the Standard fallback.
@WireFormat
public struct GMDrumKitWire: Equatable, Sendable {
    public var program: Int32
    public var name: String
    public var familyIndex: Int32

    public init(program: Int32, name: String, familyIndex: Int32) {
        self.program = program
        self.name = name
        self.familyIndex = familyIndex
    }
}

/// The whole catalog, plus the family display names in `allCases` order so `familyIndex` resolves host-side.
@WireFormat
public struct GMDrumKitCatalogWire: Equatable, Sendable {
    public var familyNames: [String]
    public var kits: [GMDrumKitWire]

    public init(familyNames: [String], kits: [GMDrumKitWire]) {
        self.familyNames = familyNames
        self.kits = kits
    }
}
