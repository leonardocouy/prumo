import AppKit

let destination = URL(fileURLWithPath: CommandLine.arguments[1])
let iconset = destination.appendingPathComponent("Prumo.iconset")
let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Brand/prumo-icon.svg")
guard let artwork = NSImage(contentsOf: source) else { fatalError("Could not load the Prumo SVG") }
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for pointSize in [16, 32, 128, 256, 512] {
    for factor in [1, 2] {
        let pixels = pointSize * factor
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let context = NSGraphicsContext(bitmapImageRep: bitmap) else { fatalError("Could not create icon bitmap") }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        artwork.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("Could not export app icon") }
        let name = "icon_\(pointSize)x\(pointSize)" + (factor == 2 ? "@2x" : "") + ".png"
        try png.write(to: iconset.appendingPathComponent(name))
    }
}
