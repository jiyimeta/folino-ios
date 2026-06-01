import Foundation

extension String {
    /// `nil` when the string is empty, otherwise the string itself. Used to normalize parsed metaTag values
    /// (an empty `<metaTag>` should read as "absent", not as an empty string).
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
