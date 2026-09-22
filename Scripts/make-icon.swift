#!/usr/bin/env swift
//
// Generates Resources/AppIcon.icns — a generic database-cylinder mark.
//
// The icon is drawn in code rather than committed as a binary blob, so anyone reading this
// public repository can see exactly what ships in the app bundle.
//
// Usage: swift Scripts/make-icon.swift [output-directory]
//

import AppKit
import CoreGraphics
import Foundation

let outputDirectory = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources"
let iconsetDirectory = outputDirectory + "/AppIcon.iconset"

// Postgres-ish navy through to a lighter slate blue.
let backgroundTop = CGColor(red: 0.20, green: 0.38, blue: 0.62, alpha: 1)
let backgroundBottom = CGColor(red: 0.11, green: 0.20, blue: 0.36, alpha: 1)
let discFill = CGColor(red: 0.98, green: 0.98, blue: 1.00, alpha: 1)
let discShade = CGColor(red: 0.80, green: 0.86, blue: 0.94, alpha: 1)

func drawIcon(size: CGFloat) -> CGImage? {
    let pixels = Int(size)
    guard let context = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    context.setShouldAntialias(true)
    context.interpolationQuality = .high

    // Rounded-rect background, following Apple's ~22% corner radius on a 10% inset canvas.
    let inset = size * 0.06
    let rect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let radius = rect.width * 0.2237
    let backgroundPath = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

    context.saveGState()
    context.addPath(backgroundPath)
    context.clip()
    if let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [backgroundTop, backgroundBottom] as CFArray,
        locations: [0, 1]
    ) {
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: 0, y: size),
            end: CGPoint(x: 0, y: 0),
            options: []
        )
    }
    context.restoreGState()

    // Database cylinder: three stacked discs with connecting walls.
    let cylinderWidth = size * 0.50
    let cylinderX = (size - cylinderWidth) / 2
    let discHeight = cylinderWidth * 0.26
    let bandHeight = cylinderWidth * 0.235
    let bandCount = 3
    let totalHeight = discHeight + bandHeight * CGFloat(bandCount)
    let bottomY = (size - totalHeight) / 2

    func disc(atY y: CGFloat) -> CGPath {
        CGPath(ellipseIn: CGRect(x: cylinderX, y: y, width: cylinderWidth, height: discHeight), transform: nil)
    }

    // Body walls, drawn bottom-up so the top disc sits cleanly on them.
    for index in 0..<bandCount {
        let y = bottomY + CGFloat(index) * bandHeight
        let wall = CGMutablePath()
        wall.addRect(CGRect(x: cylinderX, y: y + discHeight / 2, width: cylinderWidth, height: bandHeight))
        // Lower bands sit in shadow, so the stack reads as lit from above.
        let shade = index == 0 ? discShade : discFill
        context.setFillColor(shade)
        context.addPath(wall)
        context.fillPath()

        // Front curve closing the bottom of each band.
        context.setFillColor(shade)
        context.addPath(disc(atY: y))
        context.fillPath()
    }

    // Separator lines between bands, in the background colour so they read as gaps.
    context.setStrokeColor(backgroundBottom)
    context.setLineWidth(max(1, size * 0.012))
    for index in 1...bandCount {
        let y = bottomY + CGFloat(index) * bandHeight
        context.addPath(disc(atY: y))
        context.strokePath()
    }

    // Top face, brightest so the cylinder reads as lit from above.
    context.setFillColor(discFill)
    context.addPath(disc(atY: bottomY + bandHeight * CGFloat(bandCount)))
    context.fillPath()

    return context.makeImage()
}

func write(_ image: CGImage, to path: String) throws {
    let bitmap = NSBitmapImageRep(cgImage: image)
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "make-icon", code: 1, userInfo: [NSLocalizedDescriptionKey: "PNG encoding failed"])
    }
    try data.write(to: URL(fileURLWithPath: path))
}

// The exact set of sizes iconutil expects.
let variants: [(name: String, size: CGFloat)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]

do {
    try? FileManager.default.removeItem(atPath: iconsetDirectory)
    try FileManager.default.createDirectory(atPath: iconsetDirectory, withIntermediateDirectories: true)

    for variant in variants {
        guard let image = drawIcon(size: variant.size) else {
            throw NSError(domain: "make-icon", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not render \(variant.name)"])
        }
        try write(image, to: iconsetDirectory + "/" + variant.name)
    }

    let iconutil = Process()
    iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    iconutil.arguments = ["-c", "icns", iconsetDirectory, "-o", outputDirectory + "/AppIcon.icns"]
    try iconutil.run()
    iconutil.waitUntilExit()
    guard iconutil.terminationStatus == 0 else {
        throw NSError(domain: "make-icon", code: 3, userInfo: [NSLocalizedDescriptionKey: "iconutil failed"])
    }

    // The .iconset is an intermediate; only the .icns is needed by the bundle.
    try? FileManager.default.removeItem(atPath: iconsetDirectory)
    print("Wrote \(outputDirectory)/AppIcon.icns")
} catch {
    FileHandle.standardError.write(Data("make-icon failed: \(error.localizedDescription)\n".utf8))
    exit(1)
}
