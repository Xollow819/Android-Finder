import AppKit
import Foundation

guard CommandLine.arguments.count == 3,
      let robot = NSImage(contentsOfFile: CommandLine.arguments[1]) else {
    throw CocoaError(.fileReadCorruptFile)
}
let destination = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
let sizes = [16, 32, 128, 256, 512]

for size in sizes {
    for scale in [1, 2] {
        let pixels = size * scale
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let canvas = CGFloat(pixels)
        let width = canvas * 0.82
        let height = width * robot.size.height / robot.size.width
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        robot.draw(in: NSRect(x: (canvas - width) / 2, y: (canvas - height) / 2, width: width, height: height),
                   from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let suffix = scale == 2 ? "@2x" : ""
        try png.write(to: destination.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
