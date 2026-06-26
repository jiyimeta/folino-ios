/// Bucket a raw count into a low-cardinality string so no precise magnitude reaches analytics.
public func countBucket(_ count: Int) -> String {
    switch count {
    case ..<1: "0"
    case 1 ... 5: "1-5"
    case 6 ... 20: "6-20"
    case 21 ... 50: "21-50"
    default: "51+"
    }
}
