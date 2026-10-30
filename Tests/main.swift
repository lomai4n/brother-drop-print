// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import CoreGraphics
import ImageIO
import Darwin
import AppKit

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fputs("FAIL: \(message)\n", stderr); exit(1) }
}
func rejected(_ operation: () throws -> Void) -> Bool {
    do { try operation(); return false } catch { return true }
}
final class LazyDragData: NSObject, NSPasteboardItemDataProvider {
    var reads = 0
    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem,
                    provideDataForType type: NSPasteboard.PasteboardType) {
        reads += 1
        item.setString("file:///example/fixture.pdf", forType: type)
    }
}
let folder = FileManager.default.temporaryDirectory.appendingPathComponent("BrotherDropPrintTests-\(UUID())")
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
defer { try? FileManager.default.removeItem(at: folder) }
let pdfURL = folder.appendingPathComponent("orientation.pdf")
var box = CGRect(x: 0, y: 0, width: 595, height: 842)
let consumer = CGDataConsumer(url: pdfURL as CFURL)!
let pdfContext = CGContext(consumer: consumer, mediaBox: &box, nil)!
for _ in 0..<2 {
    pdfContext.beginPDFPage(nil)
    pdfContext.setFillColor(gray: 1, alpha: 1)
    pdfContext.fill(box)
    pdfContext.setFillColor(gray: 0, alpha: 1)
    pdfContext.fill(CGRect(x: 0, y: 700, width: 595, height: 142))
    pdfContext.endPDFPage()
}
pdfContext.closePDF()
let document = try PrintDocument(url: pdfURL)
expect(document.pageCount == 2 && document.isPDF, "PDF page count")
let valid = PrintOptions(host: "192.0.2.10", port: 9100, copies: 1, firstPage: 1, lastPage: 2,
                         rotate: false, fit: true)
try valid.validate(pageCount: 2)
expect(rejected {
    try PrintOptions(host: "example.invalid;command", port: 9100, copies: 1,
                     firstPage: 1, lastPage: 2, rotate: false, fit: true).validate(pageCount: 2)
}, "invalid IP rejected")
expect(rejected {
    try PrintOptions(host: "192.0.2.10", port: 9100, copies: 1,
                     firstPage: 2, lastPage: 3, rotate: false, fit: true).validate(pageCount: 2)
}, "out-of-range pages rejected")
expect(rejected {
    try PrintOptions(host: "192.0.2.10", port: 70000, copies: 0,
                     firstPage: 1, lastPage: 2, rotate: false, fit: true).validate(pageCount: 2)
}, "invalid port/copies rejected")
let preferencesName = "org.brotherdropprint.tests.\(UUID())"
let preferencesStore = UserDefaults(suiteName: preferencesName)!
defer { preferencesStore.removePersistentDomain(forName: preferencesName) }
var preferences = PrinterPreferences(defaults: preferencesStore)
expect(preferences.host.isEmpty && preferences.port == 9100 && preferences.automaticDropWindow,
       "V1.1 preferences preserve empty connection and default automatic drop")
preferences.automaticDropWindow = false
try preferences.save(to: preferencesStore)
expect(!PrinterPreferences(defaults: preferencesStore).automaticDropWindow,
       "automatic drop can be disabled before configuring a printer")
preferences.host = "192.0.2.10"
preferences.port = 19100
preferences.interface = "lo0"
try preferences.save(to: preferencesStore)
let restored = PrinterPreferences(defaults: preferencesStore)
expect(restored.host == preferences.host && restored.port == 19100 && restored.interface == "lo0",
       "connection preferences round trip")
preferences.host = "invalid destination"
expect(rejected { try preferences.save(to: preferencesStore) }, "invalid settings rejected")
expect(PrinterPreferences(defaults: preferencesStore).host == "192.0.2.10",
       "failed settings save does not overwrite prior connection")

var dragState = FileDragState(changeCount: 10)
dragState.beginGesture()
expect(dragState.observe(pressed: true, changeCount: 10, hasFileType: true) == .none,
       "stale drag metadata does not reveal a window")
expect(dragState.observe(pressed: true, changeCount: 11, hasFileType: false) == .none,
       "text drag does not reveal a file window")
expect(dragState.observe(pressed: false, changeCount: 11, hasFileType: false) == .none,
       "ordinary mouse release needs no cleanup")
dragState.beginGesture()
expect(dragState.observe(pressed: true, changeCount: 12, hasFileType: true) == .began,
       "new file drag reveals before entering a target")
expect(dragState.observe(pressed: true, changeCount: 12, hasFileType: true) == .none,
       "same drag reveals only once")
expect(dragState.observe(pressed: true, changeCount: 13, hasFileType: true) == .none,
       "additional items within a drag do not duplicate reveal")
expect(dragState.observe(pressed: false, changeCount: 13, hasFileType: true) == .ended,
       "release ends the active global drag")
expect(dragState.observe(pressed: false, changeCount: 13, hasFileType: true) == .none,
       "release cleanup is not repeated")
dragState.beginGesture()
expect(dragState.observe(pressed: true, changeCount: 14, hasFileType: true) == .began,
       "a later file drag can reveal again")
let raster = try PrintEngine.raster(document, page: 1, rotate: false, fit: true)
let header = Data("P4\n4825 6817\n".utf8)
expect(raster.starts(with: header), "PBM header")
expect(raster.count == header.count + PageSetup().rowBytes * PageSetup().height, "exact raster length")
let body = Array(raster.dropFirst(header.count))
let topBlack = body[PageSetup().rowBytes * 100..<(PageSetup().rowBytes * 101)].reduce(0) { $0 + $1.nonzeroBitCount }
let bottomBlack = body[PageSetup().rowBytes * 6700..<(PageSetup().rowBytes * 6701)].reduce(0) { $0 + $1.nonzeroBitCount }
expect(topBlack > 4000 && bottomBlack == 0, "PDF top stays at the top of the printer raster")
for row in 0..<PageSetup().height {
    expect(body[(row + 1) * PageSetup().rowBytes - 1] & 0x7f == 0, "white row padding")
}
expect(PageSetup().width == 4825 && PageSetup().height == 6817 && PageSetup().rowBytes == 604,
       "A4 600 dpi keeps the calibrated V1 raster size")
var draftA5 = PageSetup()
draftA5.paper = .a5
draftA5.quality = .draft
let a5Raster = try PrintEngine.raster(document, page: 1, rotate: false, fit: true, setup: draftA5)
let a5Header = Data("P4\n1683 2379\n".utf8)
expect(a5Raster.starts(with: a5Header) && a5Raster.count == a5Header.count + 211 * 2379, "A5 draft raster size")
expect(draftA5.encoderArguments == ["A5", "300", "0", "0", "PLAIN"], "encoder receives the page setup")
var rememberedSetup = PageSetup()
rememberedSetup.paper = .letter
rememberedSetup.quality = .tonerSave
rememberedSetup.media = .thick
rememberedSetup.density = 3
rememberedSetup.save(preferencesStore)
expect(PageSetup.saved(preferencesStore) == rememberedSetup, "page setup is remembered")
let invalid = folder.appendingPathComponent("invalid.pdf")
try Data("not a pdf".utf8).write(to: invalid)
expect(rejected { _ = try PrintDocument(url: invalid) }, "malformed PDF rejected")
let calibration = folder.appendingPathComponent("calibration.pdf")
try PrintEngine.calibrationPDF(to: calibration)
let calibrationDocument = try PrintDocument(url: calibration)
expect(calibrationDocument.pageCount == 1, "calibration page generated")
if CommandLine.arguments.count > 2 {
    try Data(contentsOf: calibration).write(to: URL(fileURLWithPath: CommandLine.arguments[2]), options: .atomic)
}
let pngURL = folder.appendingPathComponent("transparent.png")
let rgba = Data([0, 0, 0, 255, 0, 0, 0, 0])
let image = CGImage(width: 2, height: 1, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 8,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                    provider: CGDataProvider(data: rgba as CFData)!, decode: nil,
                    shouldInterpolate: false, intent: .defaultIntent)!
let destination = CGImageDestinationCreateWithURL(pngURL as CFURL, "public.png" as CFString, 1, nil)!
CGImageDestinationAddImage(destination, image, nil)
expect(CGImageDestinationFinalize(destination), "PNG fixture written")
let imageDocument = try PrintDocument(url: pngURL)
expect(imageDocument.pageCount == 1 && !imageDocument.isPDF, "PNG input accepted")
let dragBoard = NSPasteboard.withUniqueName()
defer { dragBoard.releaseGlobally() }
expect(dragBoard.writeObjects([pdfURL as NSURL]), "write a synthetic file drag")
expect(FileDropView.fileURLs(dragBoard) == [pdfURL], "Finder file URL drag is accepted")
dragBoard.clearContents()
dragBoard.writeObjects([pdfURL as NSURL, pngURL as NSURL])
expect(FileDropView.fileURLs(dragBoard) == [pdfURL, pngURL], "multiple simultaneous file drops are received")
expect(FileDropView.unsupportedReason(dragBoard) == nil, "supported files are not rejected while dragging")
dragBoard.clearContents()
dragBoard.writeObjects([folder.appendingPathComponent("unsupported.docx") as NSURL])
expect(FileDropView.fileURLs(dragBoard).count == 1, "local file payload is received before format validation")
expect(FileDropView.unsupportedReason(dragBoard)?.contains(".docx") == true,
       "the flash card rejects an unsupported document before the drop")
dragBoard.writeObjects([pdfURL as NSURL])
expect(FileDropView.unsupportedReason(dragBoard) == nil, "a mixed drag with one printable file is accepted")
dragBoard.clearContents()
dragBoard.writeObjects([NSURL(string: "https://example.com/document.pdf")!])
expect(!FileDropView.hasFileRepresentation(dragBoard), "plain web URL does not trigger the file helper")
expect(FileDropView.fileURLs(dragBoard).isEmpty, "plain web URL cannot become a local print file")
dragBoard.clearContents()
let provider = LazyDragData()
let lazyItem = NSPasteboardItem()
lazyItem.setDataProvider(provider, forTypes: [.fileURL])
dragBoard.writeObjects([lazyItem])
let priorReads = provider.reads
expect(FileDropView.hasFileRepresentation(dragBoard), "file type metadata is detected")
expect(provider.reads == priorReads, "global detection does not request the dragged URL data")
let receivedDirectory = folder.appendingPathComponent("received")
try FileManager.default.createDirectory(at: receivedDirectory, withIntermediateDirectories: false)
expect(FileDropView.validReceivedURL(receivedDirectory.appendingPathComponent("incoming.pdf"), directory: receivedDirectory),
       "promised file inside its private destination is valid")
expect(!FileDropView.validReceivedURL(pdfURL, directory: receivedDirectory),
       "promised file cannot escape its destination")
let escaped = receivedDirectory.appendingPathComponent("linked.pdf")
try FileManager.default.createSymbolicLink(at: escaped, withDestinationURL: pdfURL)
expect(!FileDropView.validReceivedURL(escaped, directory: receivedDirectory),
       "promised file symlink cannot escape its private destination")
let imageRaster = Array(try PrintEngine.raster(imageDocument, page: 1, rotate: false, fit: true).dropFirst(header.count))
let middleRow = PageSetup().height / 2 * PageSetup().rowBytes
expect(imageRaster[middleRow + (PageSetup().width / 4) / 8] == 255, "black image pixels")
expect(imageRaster[middleRow + (PageSetup().width * 3 / 4) / 8] == 0, "transparent image background stays white")

let listener = socket(AF_INET, SOCK_STREAM, 0)
expect(listener >= 0, "create loopback listener")
var address = sockaddr_in()
address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
address.sin_family = sa_family_t(AF_INET)
address.sin_addr.s_addr = inet_addr("127.0.0.1")
let bound = withUnsafePointer(to: &address) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
    }
}
expect(bound == 0 && listen(listener, 1) == 0, "bind loopback listener")
var size = socklen_t(MemoryLayout<sockaddr_in>.size)
let named = withUnsafeMutablePointer(to: &address) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        getsockname(listener, $0, &size)
    }
}
expect(named == 0, "read loopback port")
let localPort = Int(UInt16(bigEndian: address.sin_port))
let payload = Data((0..<400_000).map { UInt8(truncatingIfNeeded: $0) })
let payloadURL = folder.appendingPathComponent("transport.bin")
try payload.write(to: payloadURL)
let received = DispatchSemaphore(value: 0)
var receivedData = Data()
DispatchQueue.global().async {
    let peer = accept(listener, nil, nil)
    if peer >= 0 {
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = recv(peer, &chunk, chunk.count, 0)
            if count <= 0 { break }
            receivedData.append(contentsOf: chunk.prefix(count))
        }
        close(peer)
    }
    received.signal()
}
try PrintEngine.send(payloadURL, host: "127.0.0.1", port: localPort, interface: "lo0", progress: { _ in })
expect(received.wait(timeout: .now() + 10) == .success, "loopback transfer completes")
expect(receivedData == payload, "all file bytes arrive unchanged")
close(listener)
expect(rejected {
    try PrintEngine.send(payloadURL, host: "127.0.0.1", port: localPort,
                         interface: "missing-test-interface", progress: { _ in })
}, "missing selected interface fails without fallback")
expect(rejected {
    try PrintEngine.send(payloadURL, host: "127.0.0.1", port: localPort, progress: { _ in })
}, "connection refusal is reported")
if CommandLine.arguments.count > 1 {
    let encoder = URL(fileURLWithPath: CommandLine.arguments[1])
    let job = try PrintEngine.prepare(document, options: valid, encoder: encoder, progress: { _ in })
    let bytes = try Data(contentsOf: job.dataURL)
    expect(job.sheets == 2, "selected page count")
    expect(bytes.range(of: Data("@PJL ENTER LANGUAGE = PCL".utf8)) != nil, "PJL header")
    expect(bytes.range(of: Data("\u{1b}*b1030m".utf8)) != nil, "1030 raster mode")
    expect(bytes.range(of: Data("@PJL EOJ".utf8)) != nil, "complete job terminator")
    job.remove()
    var a5Options = valid
    a5Options.setup = draftA5
    let a5Job = try PrintEngine.prepare(document, options: a5Options, encoder: encoder, progress: { _ in })
    let a5Bytes = try Data(contentsOf: a5Job.dataURL)
    expect(a5Bytes.range(of: Data("@PJL SET PAPER = A5".utf8)) != nil &&
           a5Bytes.range(of: Data("@PJL SET RESOLUTION = 300".utf8)) != nil,
           "A5 draft job reaches the encoder with its setup")
    a5Job.remove()
    let queued = QueuedPrintFile(document: document, setup: draftA5)
    queued.copies = 2
    queued.firstPage = 2
    queued.lastPage = 2
    queued.rotate = true
    var connection = PrinterPreferences(defaults: preferencesStore)
    connection.host = "192.0.2.10"
    connection.port = 9100
    connection.interface = "lo0"
    let task = queued.task(connection: connection)
    expect(task.id == queued.id && task.options.copies == 2 && task.options.firstPage == 2 &&
           task.options.lastPage == 2 && task.options.rotate && task.options.interface == "lo0",
           "queue snapshots retain per-file options and selected network binding")
    expect(task.options.setup == draftA5, "queue snapshots retain the page setup")
    var events: [PrintBatchEvent] = []
    let second = PrintTask(id: UUID(), document: document, options: valid)
    expect(rejected {
        try PrintBatch.run([task, second], encoder: folder.appendingPathComponent("missing-encoder")) {
            events.append($0)
        }
    }, "batch stops when its first conversion fails")
    let failed = events.compactMap { event -> UUID? in
        if case .failed(let id, _) = event { return id }
        return nil
    }
    let sent = events.contains { if case .sent = $0 { return true }; return false }
    expect(failed == [queued.id] && !sent, "failed batch never sends a later queued file")

    let batchListener = socket(AF_INET, SOCK_STREAM, 0)
    expect(batchListener >= 0, "create batch test listener")
    defer { close(batchListener) }
    var batchAddress = sockaddr_in()
    batchAddress.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    batchAddress.sin_family = sa_family_t(AF_INET)
    batchAddress.sin_addr.s_addr = inet_addr("127.0.0.1")
    let batchBound = withUnsafePointer(to: &batchAddress) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(batchListener, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    expect(batchBound == 0 && listen(batchListener, 2) == 0, "bind batch listener")
    var batchAddressSize = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &batchAddress) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            getsockname(batchListener, $0, &batchAddressSize)
        }
    }
    connection.host = "127.0.0.1"
    connection.port = Int(UInt16(bigEndian: batchAddress.sin_port))
    let nextFile = QueuedPrintFile(document: calibrationDocument)
    let firstTask = queued.task(connection: connection)
    let nextTask = nextFile.task(connection: connection)
    let batchFinished = DispatchSemaphore(value: 0)
    var receivedJobs: [Data] = []
    DispatchQueue.global().async {
        for _ in 0..<2 {
            let peer = accept(batchListener, nil, nil)
            guard peer >= 0 else { break }
            var data = Data()
            var chunk = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = recv(peer, &chunk, chunk.count, 0)
                if count <= 0 { break }
                data.append(contentsOf: chunk.prefix(count))
            }
            close(peer)
            receivedJobs.append(data)
        }
        batchFinished.signal()
    }
    var sentIDs: [UUID] = []
    try PrintBatch.run([firstTask, nextTask], encoder: encoder) { event in
        if case .sent(let id, _) = event { sentIDs.append(id) }
    }
    expect(batchFinished.wait(timeout: .now() + 10) == .success, "multi-file batch delivery finishes")
    expect(sentIDs == [queued.id, nextFile.id], "batch sends files in list order")
    expect(receivedJobs.count == 2, "each document uses one complete print connection")
    expect(receivedJobs.allSatisfy {
        $0.range(of: Data("@PJL EOJ".utf8)) != nil && $0.starts(with: Data(repeating: 0, count: 128))
    }, "both received jobs have complete protocol boundaries")
}
print("Core checks passed: drag state, settings, file receipts, PDF/PNG rendering, TCP binding and batch delivery.")
