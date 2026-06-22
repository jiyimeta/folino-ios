#!/usr/bin/env swift
//
// extract-wordmark.swift
//
// Regenerate the Android feature-graphic logo (the "folino" wordmark) from the iOS icon's title layer.
// The icon's title layer (App/Resources/folino.icon/Assets/folino_icon_title.png, 1024x1024) centers the
// wordmark inside a large transparent square; this crops it to the wordmark's bounding box — INCLUDING the
// f's long curling descender — and writes it, transparency preserved, to the Android drawable.
//
// The crop rect was determined by eye (an auto-alpha-trim mis-clipped the thin descender hook). If the
// title art changes, re-eyeball CROP and re-run. macOS-only (CoreGraphics/ImageIO). Run from the repo root:
//   swift Scripts/extract-wordmark.swift
//
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let inPath = "App/Resources/folino.icon/Assets/folino_icon_title.png"
let outPath = "Android/app/src/main/res/drawable-nodpi/folino_wordmark.png"
/// Crop region in the 1024x1024 source (top-left origin): x, y, width, height. Tuned by eye to include the
/// full wordmark — the f's curling descender (lower-left) and the trailing "o" — with even margins.
let cropX = 5, cropY = 270, cropW = 1000, cropH = 512

let inU = URL(fileURLWithPath: inPath)
let outU = URL(fileURLWithPath: outPath)
guard let src = CGImageSourceCreateWithURL(inU as CFURL, nil),
      let img = CGImageSourceCreateImageAtIndex(src, 0, nil)
else {
    FileHandle.standardError.write(Data("cannot read \(inPath) (run from the repo root)\n".utf8))
    exit(1)
}

let h = img.height
let w = img.width
let cs = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(
    data: nil, width: cropW, height: cropH, bitsPerComponent: 8, bytesPerRow: 0,
    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
) else {
    FileHandle.standardError.write(Data("cannot make context\n".utf8))
    exit(1)
}

// Transparent background (no fill). Bottom-left origin: place the top-left crop region by offsetting the
// full image: dx = -cropX, dy = cropH - h + cropY.
ctx.draw(img, in: CGRect(x: -cropX, y: cropH - h + cropY, width: w, height: h))
guard let out = ctx.makeImage(),
      let dest = CGImageDestinationCreateWithURL(outU as CFURL, UTType.png.identifier as CFString, 1, nil)
else {
    FileHandle.standardError.write(Data("cannot create output\n".utf8))
    exit(1)
}

CGImageDestinationAddImage(dest, out, nil)
guard CGImageDestinationFinalize(dest) else {
    FileHandle.standardError.write(Data("cannot write \(outPath)\n".utf8))
    exit(1)
}

print("wrote \(outPath) (\(cropW)x\(cropH))")
