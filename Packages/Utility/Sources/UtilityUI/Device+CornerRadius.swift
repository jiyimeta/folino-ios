import DeviceKit
import Foundation

/// Exposes device screen metrics to feature modules without forcing them to depend on DeviceKit
/// directly — callers import `UtilityUI` and read `DeviceMetrics.screenCornerRadius`.
public enum DeviceMetrics {
    /// Physical screen corner radius of the current device, in points. `0` for square-cornered
    /// devices (e.g. iPhone SE). Useful for nesting a rounded card concentrically inside the screen.
    ///
    /// On macOS this is always `0` — DeviceKit gates its whole iPhone/iPad `Device` case set behind
    /// `#if os(iOS)`, so there is no per-device geometry to read here.
    public static var screenCornerRadius: CGFloat {
        #if os(iOS)
        Device.current.cornerRadius
        #else
        0
        #endif
    }
}

// PARITY(macos): screen corner radius — DeviceKit has no macOS device geometry to read, so
// `screenCornerRadius` returns 0 there. Revisit only if a Mac window ever needs concentric corner
// nesting against real display bezel geometry.

#if os(iOS)
extension Device {
    /// Physical screen corner radius in points. Values mirror Apple's display geometry per device;
    /// `0` for square-cornered devices. Copied from the shared Recordia implementation.
    var cornerRadius: CGFloat {
        switch self {
        case .iPhone11:
            41.5
        case .iPhone11Pro, .iPhone11ProMax:
            39
        case .iPhoneSE2, .iPhoneSE3:
            0
        case .iPhone12, .iPhone12Pro, .iPhone13, .iPhone13Pro, .iPhone14, .iPhone16e, .iPhone17e:
            47 + 1 / 3
        case .iPhone12Mini, .iPhone13Mini:
            44
        case .iPhone12ProMax, .iPhone13ProMax, .iPhone14Plus:
            53 + 1 / 3
        case .iPhone14Pro, .iPhone14ProMax,
             .iPhone15, .iPhone15Plus, .iPhone15Pro, .iPhone15ProMax,
             .iPhone16, .iPhone16Plus:
            55
        case .iPhone16Pro, .iPhone16ProMax,
             .iPhone17, .iPhone17Pro, .iPhone17ProMax,
             .iPhoneAir:
            62
        case .iPadAir3,
             .iPad8, .iPad9, .iPad10, .iPadA16,
             .iPadAir4, .iPadAir5,
             .iPadAir11M2, .iPadAir13M2, .iPadAir11M3, .iPadAir13M3, .iPadAir11M4, .iPadAir13M4,
             .iPadMini5, .iPadMini6, .iPadMiniA17Pro,
             .iPadPro11Inch, .iPadPro12Inch3, .iPadPro11Inch2, .iPadPro12Inch4,
             .iPadPro11Inch3, .iPadPro12Inch5, .iPadPro11Inch4, .iPadPro12Inch6,
             .iPadPro11M4, .iPadPro13M4, .iPadPro11M5, .iPadPro13M5:
            18
        case let .simulator(device):
            device.cornerRadius
        case let .unknown(string):
            withAssertionFailure("Unknown device: \(string)") {
                0
            }
        // MARK: -
        case .iPodTouch5, .iPodTouch6, .iPodTouch7,
             .iPhone4, .iPhone4s,
             .iPhone5, .iPhone5c, .iPhone5s,
             .iPhone6, .iPhone6Plus, .iPhone6s, .iPhone6sPlus,
             .iPhone7, .iPhone7Plus,
             .iPhoneSE,
             .iPhone8, .iPhone8Plus,
             .iPhoneX, .iPhoneXS, .iPhoneXSMax, .iPhoneXR,
             .iPad2, .iPad3, .iPad4,
             .iPadAir, .iPadAir2,
             .iPad5, .iPad6, .iPad7,
             .iPadMini, .iPadMini2, .iPadMini3, .iPadMini4,
             .iPadPro9Inch, .iPadPro12Inch, .iPadPro12Inch2, .iPadPro10Inch:
            withAssertionFailure("Incompatible with iOS 26.") {
                39
            }
        case .homePod:
            withAssertionFailure("Unsupported device family.") {
                0
            }
        }
    }
}

private func withAssertionFailure<V>(_ message: String, _ value: () -> V) -> V {
    assertionFailure(message)
    return value()
}
#endif
