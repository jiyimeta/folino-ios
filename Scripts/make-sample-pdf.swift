#!/usr/bin/env swift
// Generates a 2-page PDF whose document `/Title` is "Sample Title", used as a binary test fixture for the PDF import
// gateway tests. Run: `swift Scripts/make-sample-pdf.swift <out.pdf>`. The output is committed under the Infrastructure
// test bundle resources. Self-contained (Core Graphics only — runs on the macOS host, no UIKit); no GPL data.
import CoreGraphics
import Foundation
import ImageIO

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "sample.pdf"
let outURL = URL(fileURLWithPath: outPath)

var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792) // US Letter, points.

let auxInfo: [CFString: Any] = [kCGPDFContextTitle: "Sample Title"]

guard let consumer = CGDataConsumer(url: outURL as CFURL),
      let context = CGContext(consumer: consumer, mediaBox: &mediaBox, auxInfo as CFDictionary)
else {
    FileHandle.standardError.write(Data("Failed to create PDF context\n".utf8))
    exit(1)
}

for _ in 1 ... 2 {
    context.beginPDFPage(nil)
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(mediaBox)
    context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 40, y: 632, width: 200, height: 40))
    context.endPDFPage()
}

context.closePDF()
print("Wrote 2-page PDF with /Title to \(outURL.path)")
