import Foundation
import PDFKit

// Extract every /PPK value, decode the base64, and report the container magic + size.
// PDFKit only — no PencilKit, which cannot run in a command-line tool on macOS.

let path = CommandLine.arguments[1]
let outDir = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : NSTemporaryDirectory()
guard let doc = PDFDocument(data: try! Data(contentsOf: URL(fileURLWithPath: path))) else {
    print("open failed"); exit(1)
}

func magic(_ d: Data) -> String {
    let head = [UInt8](d.prefix(16))
    let ascii = String(bytes: head.prefix(8).map { $0 >= 32 && $0 < 127 ? $0 : 0x2E }, encoding: .ascii) ?? "?"
    let hex = head.map { String(format: "%02x", $0) }.joined(separator: " ")
    return "ascii=\"\(ascii)\" hex=[\(hex)] bytes=\(d.count)"
}

var n = 0
for i in 0 ..< doc.pageCount {
    guard let page = doc.page(at: i) else { continue }
    for a in page.annotations {
        for (k, v) in a.annotationKeyValues {
            let key = "\(k)"
            guard key.contains("PPK") || key.contains("AKExtras") || key.contains("AKAnnotation") else { continue }

            /// The value may be the dictionary itself, or a base64 string, or Data.
            func report(_ label: String, _ value: Any) {
                if let s = value as? String, let raw = Data(base64Encoded: s, options: .ignoreUnknownCharacters) {
                    print("page \(i + 1) \(label): base64 -> \(magic(raw))")
                    n += 1
                    let out = URL(fileURLWithPath: outDir).appendingPathComponent("ppk-p\(i + 1)-\(n).bin")
                    try? raw.write(to: out)
                    print("   wrote \(out.path)")
                } else if let d = value as? Data {
                    print("page \(i + 1) \(label): Data -> \(magic(d))")
                } else if let dict = value as? [String: Any] {
                    for (dk, dv) in dict {
                        report("\(label)/\(dk)", dv)
                    }
                } else if let dict = value as? [AnyHashable: Any] {
                    for (dk, dv) in dict {
                        report("\(label)/\(dk)", dv)
                    }
                } else {
                    print("page \(i + 1) \(label): \(type(of: value)) \(String(describing: value).prefix(60))")
                }
            }
            report(key, v)
        }
    }
}

print("total blobs extracted:", n)
