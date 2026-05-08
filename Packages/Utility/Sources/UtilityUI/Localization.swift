import Foundation
import SwiftUI

public enum UtilityUILocalization {
    public static let bundle: Bundle = .module
}

public enum L10n {
    public enum Common {
        public static var add: Text { Text("common.action.add", bundle: UtilityUILocalization.bundle) }
        public static var cancel: Text { Text("common.action.cancel", bundle: UtilityUILocalization.bundle) }
        public static var create: Text { Text("common.action.create", bundle: UtilityUILocalization.bundle) }
        public static var delete: Text { Text("common.action.delete", bundle: UtilityUILocalization.bundle) }
        public static var done: Text { Text("common.action.done", bundle: UtilityUILocalization.bundle) }
        public static var more: Text { Text("common.action.more", bundle: UtilityUILocalization.bundle) }
        public static var ok: Text { Text("common.action.ok", bundle: UtilityUILocalization.bundle) }
        public static var open: Text { Text("common.action.open", bundle: UtilityUILocalization.bundle) }
        public static var rename: Text { Text("common.action.rename", bundle: UtilityUILocalization.bundle) }
        public static var save: Text { Text("common.action.save", bundle: UtilityUILocalization.bundle) }
        public static var select: Text { Text("common.action.select", bundle: UtilityUILocalization.bundle) }
        public static var share: Text { Text("common.action.share", bundle: UtilityUILocalization.bundle) }
    }
}
