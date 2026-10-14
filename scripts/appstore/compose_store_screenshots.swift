#!/usr/bin/env swift
// Composes raw window captures from `fastlane mac appstore_screenshots` into
// Mac App Store screenshots: 2880 x 1800 pixels (16:10), opaque, with the
// window centered on a plain gradient.
//
// Usage: compose_store_screenshots.swift <input.png> <output.png>

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let canvasWidth = 2880
let canvasHeight = 1800
// Space between the window (including its shadow) and the image edge.
let margin = 90.0

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("compose_store_screenshots: \(message)\n".utf8))
    exit(1)
}

let arguments = CommandLine.arguments
guard arguments.count == 3 else { fail("usage: compose_store_screenshots.swift <input.png> <output.png>") }
let inputURL = URL(fileURLWithPath: arguments[1])
let outputURL = URL(fileURLWithPath: arguments[2])

guard let source = CGImageSourceCreateWithURL(inputURL as CFURL, nil),
      let window = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    fail("cannot read \(inputURL.path)")
}

guard let context = CGContext(
    data: nil,
    width: canvasWidth,
    height: canvasHeight,
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
) else {
    fail("cannot create canvas")
}

let top = CGColor(srgbRed: 0.16, green: 0.30, blue: 0.62, alpha: 1)
let bottom = CGColor(srgbRed: 0.05, green: 0.09, blue: 0.20, alpha: 1)
let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [top, bottom] as CFArray, locations: [0, 1])!
context.drawLinearGradient(
    gradient,
    start: CGPoint(x: 0, y: Double(canvasHeight)),
    end: CGPoint(x: 0, y: 0),
    options: []
)

let available = CGSize(width: Double(canvasWidth) - 2 * margin, height: Double(canvasHeight) - 2 * margin)
let scale = min(available.width / Double(window.width), available.height / Double(window.height), 1)
let size = CGSize(width: Double(window.width) * scale, height: Double(window.height) * scale)
let origin = CGPoint(x: (Double(canvasWidth) - size.width) / 2, y: (Double(canvasHeight) - size.height) / 2)
context.interpolationQuality = .high
context.draw(window, in: CGRect(origin: origin, size: size))

guard let image = context.makeImage(),
      let destination = CGImageDestinationCreateWithURL(outputURL as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    fail("cannot create \(outputURL.path)")
}
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else { fail("cannot write \(outputURL.path)") }
