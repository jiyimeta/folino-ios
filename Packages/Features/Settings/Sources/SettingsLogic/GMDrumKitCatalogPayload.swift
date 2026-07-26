import Domain
import Foundation
import Wirelet

/// Encodes `Domain.GMDrumKit.all` for the Android host, preserving the catalog's own order (which is program order
/// within family order) so the picker can render it as-is.
public func gmDrumKitCatalogPayload() -> Data {
    let families = GMDrumKit.Family.allCases
    let catalog = GMDrumKitCatalogWire(
        familyNames: families.map(\.rawValue),
        kits: GMDrumKit.all.map { kit in
            GMDrumKitWire(
                program: Int32(kit.program),
                name: kit.name,
                // `firstIndex` cannot miss — every kit's family comes from this same enum — but a `?? 0` keeps the
                // encoder total rather than trapping if the catalog ever gains a family the enum doesn't list.
                familyIndex: Int32(families.firstIndex(of: kit.family) ?? 0),
            )
        },
    )
    return catalog.encodeToData()
}
