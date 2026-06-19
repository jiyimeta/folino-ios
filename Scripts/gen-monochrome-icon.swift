#!/usr/bin/env swift
//
// gen-monochrome-icon.swift
//
// Derives the Android adaptive-icon <monochrome> layer from the existing per-density
// `ic_launcher_foreground.png` files. Android renders the monochrome drawable by tinting it with the
// system theme color (SRC_IN semantics), so only the ALPHA channel matters — this flattens every
// foreground to solid black while preserving its alpha, producing a genuine single-color silhouette
// (the folino wordmark + faint staff) at each density.
//
// macOS-only (CoreGraphics/ImageIO). Run from the repo root:
//   swift Scripts/gen-monochrome-icon.swift Android/app/src/main/res
//
// (ImageMagick is not assumed present; this uses the system CoreGraphics stack instead.)

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let densities = ["mdpi", "hdpi", "xhdpi", "xxhdpi", "xxxhdpi"]

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: swift gen-monochrome-icon.swift <res-dir>\n".utf8))
    exit(2)
}

let resDir = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)

func flattenToBlack(_ input: URL, _ output: URL) throws {
    guard let src = CGImageSourceCreateWithURL(input as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil)
    else {
        throw NSError(domain: "mono", code: 1, userInfo: [NSLocalizedDescriptionKey: "cannot read \(input.path)"])
    }
    let w = img.width, h = img.height
    let space = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
    ) else {
        throw NSError(domain: "mono", code: 2, userInfo: [NSLocalizedDescriptionKey: "cannot make context"])
    }
    let rect = CGRect(x: 0, y: 0, width: w, height: h)
    // Lay down the source (carries the alpha shape), then SRC_IN-fill black: keeps the per-pixel alpha,
    // replaces every color channel with black -> a uniform single-color silhouette.
    ctx.draw(img, in: rect)
    ctx.setBlendMode(.sourceIn)
    ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
    ctx.fill(rect)
    guard let outImage = ctx.makeImage(),
          let dest = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil)
    else {
        throw NSError(domain: "mono", code: 3, userInfo: [NSLocalizedDescriptionKey: "cannot create destination"])
    }
    CGImageDestinationAddImage(dest, outImage, nil)
    guard CGImageDestinationFinalize(dest) else {
        throw NSError(domain: "mono", code: 4, userInfo: [NSLocalizedDescriptionKey: "cannot write \(output.path)"])
    }
    print("wrote \(output.path) (\(w)x\(h))")
}

for d in densities {
    let dir = resDir.appendingPathComponent("mipmap-\(d)")
    let input = dir.appendingPathComponent("ic_launcher_foreground.png")
    let output = dir.appendingPathComponent("ic_launcher_monochrome.png")
    do {
        try flattenToBlack(input, output)
    } catch {
        FileHandle.standardError.write(Data("ERROR (\(d)): \(error.localizedDescription)\n".utf8))
        exit(1)
    }
}
