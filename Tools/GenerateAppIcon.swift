import AppKit
import Foundation

let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let variants: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024)
]

func render(size: Int) throws -> Data {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw NSError(domain: "SoundIcon", code: 1)
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    let scale = CGFloat(size) / 1024
    context.cgContext.scaleBy(x: scale, y: scale)

    let square = NSBezierPath(roundedRect: NSRect(x: 28, y: 28, width: 968, height: 968),
                              xRadius: 226, yRadius: 226)
    NSGradient(starting: NSColor(srgbRed: 0.16, green: 0.56, blue: 0.98, alpha: 1),
               ending: NSColor(srgbRed: 0.08, green: 0.23, blue: 0.62, alpha: 1))?
        .draw(in: square, angle: 135)

    let configuration = NSImage.SymbolConfiguration(pointSize: 500, weight: .medium)
        .applying(.init(paletteColors: [.white]))
    guard let symbol = NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: "Volume Mixer")?
        .withSymbolConfiguration(configuration) else {
        NSGraphicsContext.restoreGraphicsState()
        throw NSError(domain: "SoundIcon", code: 2)
    }
    let symbolScale = min(668 / symbol.size.width, 668 / symbol.size.height)
    let symbolSize = NSSize(width: symbol.size.width * symbolScale,
                            height: symbol.size.height * symbolScale)
    let symbolRect = NSRect(x: (1024 - symbolSize.width) / 2,
                            y: (1024 - symbolSize.height) / 2,
                            width: symbolSize.width, height: symbolSize.height)
    symbol.draw(in: symbolRect,
                from: .zero, operation: .sourceOver, fraction: 1)
    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()

    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "SoundIcon", code: 3)
    }
    return data
}

for (filename, size) in variants {
    try render(size: size).write(to: destination.appendingPathComponent(filename))
}
