// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit

let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
let outputs = [(16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
               (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
               (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
               (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
               (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png")]
for (size, name) in outputs {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                  isPlanar: false, colorSpaceName: .deviceRGB,
                                  bytesPerRow: size * 4, bitsPerPixel: 32)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let context = NSGraphicsContext.current!.cgContext
    context.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    func rounded(_ rect: NSRect, radius: CGFloat, color: NSColor) {
        color.setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
    }
    rounded(NSRect(x: 40, y: 40, width: 944, height: 944), radius: 220,
            color: NSColor(calibratedRed: 0.08, green: 0.40, blue: 0.77, alpha: 1))
    rounded(NSRect(x: 220, y: 280, width: 584, height: 350), radius: 76,
            color: NSColor(calibratedWhite: 0.13, alpha: 1))
    rounded(NSRect(x: 300, y: 545, width: 424, height: 260), radius: 26, color: .white)
    rounded(NSRect(x: 180, y: 300, width: 664, height: 290), radius: 64,
            color: NSColor(calibratedWhite: 0.92, alpha: 1))
    rounded(NSRect(x: 270, y: 355, width: 484, height: 38), radius: 16,
            color: NSColor(calibratedWhite: 0.2, alpha: 1))
    rounded(NSRect(x: 310, y: 170, width: 404, height: 230), radius: 25, color: .white)
    for y in [245, 295] {
        rounded(NSRect(x: 360, y: y, width: 300, height: 16), radius: 8,
                color: NSColor(calibratedRed: 0.12, green: 0.48, blue: 0.80, alpha: 1))
    }
    NSColor(calibratedRed: 0.14, green: 0.73, blue: 0.61, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: 735, y: 480, width: 38, height: 38)).fill()
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: destination.appendingPathComponent(name))
}
