// SPDX-License-Identifier: GPL-2.0-or-later
// Renders README screenshots offscreen with the app's own views and print rasters.
// Uses a documentation address (192.0.2.10) and a generated sample PDF; never connects to a printer.
import AppKit
import CoreText

let out = URL(fileURLWithPath: CommandLine.arguments[1])
let work = URL(fileURLWithPath: CommandLine.arguments[2])
UserDefaults.standard.register(defaults: [
    "printerHost": "192.0.2.10", "printerPort": 9100, "printerStatusMode": "off", "automaticDropWindow": true
])

// MARK: Sample document

func sampleDocument() -> URL {
    let url = work.appendingPathComponent("示例文档.pdf")
    var box = CGRect(x: 0, y: 0, width: 595, height: 842)
    let context = CGContext(consumer: CGDataConsumer(url: url as CFURL)!, mediaBox: &box, nil)!
    func text(_ string: String, _ x: CGFloat, _ y: CGFloat, size: CGFloat, bold: Bool = false, gray: CGFloat = 0) {
        let font = CTFontCreateWithName((bold ? "PingFangSC-Semibold" : "PingFangSC-Regular") as CFString, size, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: gray, alpha: 1)
        ]))
        context.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(line, context)
    }
    let titles = ["季度工作报告", "项目进展", "数据摘要", "下一步计划"]
    for (index, title) in titles.enumerated() {
        context.beginPDFPage(nil)
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(box)
        context.setFillColor(gray: 0.15, alpha: 1)
        context.fill(CGRect(x: 56, y: 770, width: 483, height: 4))
        text(title, 56, 730, size: 26, bold: true)
        text("Brother Drop Print 示例文档 · 第 \(index + 1) 页", 56, 704, size: 11, gray: 0.45)
        var y: CGFloat = 660
        for paragraph in 0..<5 {
            for line in 0..<4 {
                let width: CGFloat = line == 3 ? 260 : 483
                context.setFillColor(gray: 0.72, alpha: 1)
                context.fill(CGRect(x: 56, y: y, width: width - CGFloat((paragraph * 37 + line * 53) % 60), height: 7))
                y -= 16
            }
            y -= 14
            if paragraph == 1 {
                for bar in 0..<6 {
                    let height = CGFloat([60, 92, 74, 120, 102, 136][(bar + index) % 6])
                    context.setFillColor(gray: bar % 2 == 0 ? 0.25 : 0.55, alpha: 1)
                    context.fill(CGRect(x: 76 + CGFloat(bar) * 74, y: y - 150, width: 46, height: height))
                }
                context.setFillColor(gray: 0.3, alpha: 1)
                context.fill(CGRect(x: 56, y: y - 152, width: 483, height: 1.5))
                y -= 176
            }
        }
        text("\(index + 1) / \(titles.count)", 280, 40, size: 10, gray: 0.5)
        context.endPDFPage()
    }
    context.closePDF()
    return url
}

// MARK: Snapshot and composition

func snapshot(_ view: NSView) -> CGImage {
    view.layoutSubtreeIfNeeded()
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width * 2),
                               pixelsHigh: Int(view.bounds.height * 2), bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = view.bounds.size
    view.cacheDisplay(in: view.bounds, to: rep)
    return rep.cgImage!
}

struct Tile { let image: CGImage; let radius: CGFloat; var offsetY: CGFloat = 0 }

/// Places tiles left to right, top aligned, on a soft backdrop. All units are pixels at 2x.
func compose(_ tiles: [Tile], dark: Bool, name: String, padding: CGFloat = 96, spacing: CGFloat = 72) {
    let width = tiles.reduce(padding * 2 - spacing) { $0 + CGFloat($1.image.width) + spacing }
    let height = (tiles.map { CGFloat($0.image.height) + $0.offsetY }.max() ?? 0) + padding * 2
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(data: nil, width: Int(width), height: Int(height), bitsPerComponent: 8, bytesPerRow: 0,
                            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let colors = dark ? [CGColor(srgbRed: 0.13, green: 0.15, blue: 0.20, alpha: 1),
                         CGColor(srgbRed: 0.07, green: 0.08, blue: 0.11, alpha: 1)]
                      : [CGColor(srgbRed: 0.93, green: 0.95, blue: 0.98, alpha: 1),
                         CGColor(srgbRed: 0.85, green: 0.89, blue: 0.94, alpha: 1)]
    let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: [0, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: height), end: CGPoint(x: width, y: 0), options: [])
    var x = padding
    for tile in tiles {
        let rect = CGRect(x: x, y: height - padding - tile.offsetY - CGFloat(tile.image.height),
                          width: CGFloat(tile.image.width), height: CGFloat(tile.image.height))
        let path = CGPath(roundedRect: rect, cornerWidth: tile.radius, cornerHeight: tile.radius, transform: nil)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -18), blur: 60,
                          color: CGColor(gray: 0, alpha: dark ? 0.6 : 0.28))
        context.addPath(path)
        context.setFillColor(gray: dark ? 0.2 : 1, alpha: 1)
        context.fillPath()
        context.restoreGState()
        context.saveGState()
        context.addPath(path)
        context.clip()
        context.draw(tile.image, in: rect)
        context.restoreGState()
        context.addPath(path)
        context.setStrokeColor(gray: dark ? 1 : 0, alpha: dark ? 0.14 : 0.08)
        context.setLineWidth(2)
        context.strokePath()
        x += CGFloat(tile.image.width) + spacing
    }
    let destination = CGImageDestinationCreateWithURL(out.appendingPathComponent(name) as CFURL,
                                                      "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    CGImageDestinationFinalize(destination)
    print(name, Int(width), "x", Int(height))
}

func pump(_ seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

// MARK: Scenes

let application = NSApplication.shared
application.setActivationPolicy(.accessory)
let sample = sampleDocument()

// Floating receiver: capsule, card, print panel.
let flash = FlashDropController()
flash.printerSummary = { "192.0.2.10:9100" }
flash.presets = { PrintPreset.builtIn }
flash.setPrinterStatus("就绪", severity: .ok)
var flashTiles: [Bool: [Tile]] = [:]
for dark in [false, true] {
    application.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    flash.beginDrag(); pump(0.4)
    let window = NSApp.windows.first { $0.title == "Brother 闪印" }!
    let pill = snapshot(window.contentView!)
    flash.dropView.onHover?(true); pump(0.4)
    let card = snapshot(window.contentView!)
    flash.showResult()
    flash.add([QueuedPrintFile(document: try! PrintDocument(url: sample), setup: PageSetup())])
    flash.setStatus("确认份数和页码后点“打印”。")
    pump(0.5)
    let panel = snapshot(window.contentView!)
    flash.hide()
    flashTiles[dark] = [Tile(image: pill, radius: 36), Tile(image: card, radius: 32), Tile(image: panel, radius: 32)]
    compose(flashTiles[dark]!, dark: dark, name: "flash-\(dark ? "dark" : "light").png")
}

// Settings window. Offscreen drawing cannot capture PDFKit previews, so the workbench is not rendered here.
let settings = SettingsController()
settings.show()
pump(0.5)
for dark in [false, true] {
    application.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    pump(0.6)
    let preferences = NSApp.windows.first { $0.title == "Brother Drop Print 设置" && $0.isVisible }!
    preferences.makeFirstResponder(nil)
    compose([Tile(image: snapshot(preferences.contentView!.superview!), radius: 26)], dark: dark,
            name: "settings-\(dark ? "dark" : "light").png")
}

// Pages per sheet, from the actual print rasters.
func sheetImage(_ data: Data, setup: PageSetup) -> CGImage {
    let header = "P4\n\(setup.width) \(setup.height)\n".utf8.count
    let provider = CGDataProvider(data: data.dropFirst(header) as CFData)!
    return CGImage(width: setup.width, height: setup.height, bitsPerComponent: 1, bitsPerPixel: 1,
                   bytesPerRow: setup.rowBytes, space: CGColorSpaceCreateDeviceGray(),
                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                   provider: provider, decode: [1, 0], shouldInterpolate: true, intent: .defaultIntent)!
}
let document = try! PrintDocument(url: sample)
var sheets: [Tile] = []
for (layout, pages) in [(1, [1]), (2, [1, 2]), (4, [1, 2, 3, 4])] {
    var setup = PageSetup()
    setup.layout = layout
    setup.quality = .draft
    let raster = try! PrintEngine.raster(document, pages: pages, rotate: false, fit: true, setup: setup)
    // Paper with its unprintable margin, 0.5 px per point at this size.
    let scale: CGFloat = 1.1
    let paper = CGSize(width: setup.paper.points.width * scale, height: setup.paper.points.height * scale)
    let context = CGContext(data: nil, width: Int(paper.width), height: Int(paper.height), bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(gray: 1, alpha: 1)
    context.fill(CGRect(origin: .zero, size: paper))
    context.interpolationQuality = .high
    context.draw(sheetImage(raster, setup: setup), in: CGRect(
        x: PageSetup.marginLeft * scale, y: PageSetup.marginBottom * scale,
        width: setup.printableSize.width * scale, height: setup.printableSize.height * scale))
    sheets.append(Tile(image: context.makeImage()!, radius: 4))
}
compose(sheets, dark: false, name: "layouts.png", spacing: 64)
exit(0)
