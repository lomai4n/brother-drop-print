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
expect(document.url == pdfURL && document.printableURL == pdfURL, "native PDF keeps its source URL")
expect(OfficeDocumentConverter.fontSubstitutionXML.contains("宋体") &&
       OfficeDocumentConverter.fontSubstitutionXML.contains("微软雅黑") &&
       OfficeDocumentConverter.fontSubstitutionXML.contains("Songti SC") &&
       OfficeDocumentConverter.fontSubstitutionXML.contains("Heiti SC"),
       "office conversion configures bundled Chinese font substitutions")
let fontconfig = OfficeDocumentConverter.fontconfigXML(fontDirectories: [folder],
                                                        cacheDirectory: folder.appendingPathComponent("cache"))
expect(fontconfig.contains(folder.path) && fontconfig.contains("<cachedir>"),
       "office conversion exposes bundled fonts through fontconfig")
expect(FlashDropController.thumbnail(for: document, page: 0) != nil &&
       FlashDropController.thumbnail(for: document, page: 1) != nil,
       "floating preview can render every PDF page")

let fakeSoffice = folder.appendingPathComponent("fake-soffice")
let fakeScript = """
#!/bin/sh
out=""
source=""
while [ "$#" -gt 0 ]; do
  if [ "$1" = "--outdir" ]; then
    shift
    out="$1"
  else
    source="$1"
  fi
  shift
done
base="$(basename "$source")"
cp "$source" "$out/${base%.*}.pdf"
"""
try Data(fakeScript.utf8).write(to: fakeSoffice)
try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeSoffice.path)
let officeURL = folder.appendingPathComponent("quarterly report.docx")
try Data(contentsOf: pdfURL).write(to: officeURL)
setenv("BROTHER_DROP_PRINT_SOFFICE", fakeSoffice.path, 1)
var convertedDirectory: URL?
do {
    let officeDocument = try PrintDocument(url: officeURL)
    convertedDirectory = officeDocument.printableURL.deletingLastPathComponent().deletingLastPathComponent()
    expect(officeDocument.url == officeURL && officeDocument.printableURL != officeURL,
           "office document preserves source and uses a converted PDF")
    expect(officeDocument.pageCount == 2 && officeDocument.isPDF, "converted office PDF page count")
    expect(FileManager.default.fileExists(atPath: officeDocument.printableURL.path),
           "converted PDF exists while document is retained")
}
unsetenv("BROTHER_DROP_PRINT_SOFFICE")
expect(convertedDirectory.map { !FileManager.default.fileExists(atPath: $0.path) } == true,
       "converted document directory is removed after release")
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
expect(PrintPreset.load(preferencesStore) == PrintPreset.builtIn &&
       PrintPreset.builtIn.map(\.name) == ["标准", "2 合 1", "草稿", "省墨", "手动双面"],
       "built-in presets when none are saved")
var presetList = try PrintPreset.saving(PrintPreset(name: "  讲义 ", setup: rememberedSetup), into: PrintPreset.builtIn)
expect(presetList.count == 6 && presetList[5].name == "讲义", "a new preset is appended with a trimmed name")
presetList = try PrintPreset.saving(PrintPreset(name: "草稿", setup: rememberedSetup), into: presetList)
expect(presetList.count == 6 && presetList[2].setup == rememberedSetup, "a preset with the same name is replaced")
expect(rejected { _ = try PrintPreset.saving(PrintPreset(name: "  ", setup: PageSetup()), into: presetList) },
       "an empty preset name is rejected")
PrintPreset.store(presetList, preferencesStore)
expect(PrintPreset.load(preferencesStore) == presetList, "presets are stored")
expect(PrintPreset.matching(rememberedSetup, in: presetList)?.name == "草稿" &&
       PrintPreset.matching(draftA5, in: presetList) == nil, "the matching preset is found by setup")
PrintPreset.store([], preferencesStore)
expect(PrintPreset.load(preferencesStore) == presetList, "an empty preset list is never stored")
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
expect(FileDropView.unsupportedReason(dragBoard) == nil,
       "the flash card accepts a supported office document")
dragBoard.clearContents()
dragBoard.writeObjects([folder.appendingPathComponent("unsupported.xyz") as NSURL])
expect(FileDropView.unsupportedReason(dragBoard)?.contains(".xyz") == true,
       "the flash card rejects an unsupported file before the drop")
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

// Printer status: SNMP encoding, decoding and a loopback agent; PJL parsing; page-counter confirmation.
func berLength(_ bytes: [UInt8], _ index: inout Int) -> Int {
    let first = Int(bytes[index]); index += 1
    guard first & 0x80 != 0 else { return first }
    var value = 0
    for _ in 0..<(first & 0x7f) { value = value << 8 | Int(bytes[index]); index += 1 }
    return value
}
func snmpResponse(requestID: Int, bindings: [(String, [UInt8])]) -> [UInt8] {
    let list = bindings.flatMap { SNMP.tlv(0x30, SNMP.oid($0.0) + $0.1) }
    let pdu = SNMP.tlv(0xa2, SNMP.integer(requestID) + SNMP.integer(0) + SNMP.integer(0) + SNMP.tlv(0x30, list))
    return SNMP.tlv(0x30, SNMP.integer(1) + SNMP.tlv(0x04, Array("public".utf8)) + pdu)
}
let statusBindings: [(String, [UInt8])] = [
    (SNMP.printerStatus, SNMP.integer(3)),
    (SNMP.deviceStatus, SNMP.integer(3)),
    (SNMP.detectedErrorState, SNMP.tlv(0x04, [0x40])),
    (SNMP.consoleDisplay, SNMP.tlv(0x04, Array("No Paper  ".utf8))),
    (SNMP.pageCount, SNMP.tlv(0x41, [0x80, 0x00, 0x00, 0x05])),
    (SNMP.tonerLevel, SNMP.integer(60)),
    (SNMP.tonerCapacity, SNMP.integer(100))
]
expect(SNMP.oid("1.3.6.1.2.1.43.10.2.1.4.1.1") ==
       [0x06, 0x0c, 0x2b, 0x06, 0x01, 0x02, 0x01, 0x2b, 0x0a, 0x02, 0x01, 0x04, 0x01, 0x01],
       "SNMP OID encoding")
expect(SNMP.integer(128) == [0x02, 0x02, 0x00, 0x80] && SNMP.integer(-1) == [0x02, 0x01, 0xff],
       "SNMP integer encoding keeps the sign")
let parsedStatus = SNMP.parseResponse(snmpResponse(requestID: 77, bindings: statusBindings), requestID: 77)
expect(SNMP.parseResponse(snmpResponse(requestID: 77, bindings: statusBindings), requestID: 78) == nil,
       "SNMP responses to other requests are ignored")
let snmpReport = parsedStatus.flatMap(SNMP.report)
expect(snmpReport?.state == "就绪" && snmpReport?.problems == ["缺纸"] && snmpReport?.severity == .error,
       "SNMP error bits become a readable problem")
expect(snmpReport?.tonerPercent == 60 && snmpReport?.display == "No Paper" && snmpReport?.pageCount == 2_147_483_653,
       "SNMP toner, panel text and unsigned page counter")
let pjlReport = PJLStatus.report(from: "@PJL INFO STATUS\r\nCODE=41002\r\nDISPLAY=\"No Paper\"\r\nONLINE=FALSE\r\n\u{0c}")
expect(pjlReport?.problems == ["缺纸"] && pjlReport?.severity == .error && pjlReport?.display == "No Paper",
       "PJL INFO STATUS is parsed")
// Recorded from the DCP-1618W on 2026-10-29.
let recorded = PJLStatus.report(from: "@PJL INFO STATUS\r\nCODE=10001\r\nDISPLAY=\"准备就绪\"\r\nONLINE=TRUE\r\n\u{0c}" +
                                 "@PJL INFO PAGECOUNT\r\nPAGECOUNT=5215\r\n\u{0c}")
expect(recorded?.state == "就绪" && recorded?.display == "准备就绪" && recorded?.pageCount == 5215 &&
       recorded?.severity == .ok, "recorded DCP-1618W PJL reply")
expect(PJLStatus.report(from: "garbage") == nil, "non-PJL replies are ignored")

let agent = socket(AF_INET, SOCK_DGRAM, 0)
var agentAddress = sockaddr_in()
agentAddress.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
agentAddress.sin_family = sa_family_t(AF_INET)
agentAddress.sin_addr.s_addr = inet_addr("127.0.0.1")
let agentBound = withUnsafePointer(to: &agentAddress) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(agent, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
    }
}
var agentSize = socklen_t(MemoryLayout<sockaddr_in>.size)
_ = withUnsafeMutablePointer(to: &agentAddress) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(agent, $0, &agentSize) }
}
expect(agentBound == 0, "bind loopback SNMP agent")
let agentPort = Int(UInt16(bigEndian: agentAddress.sin_port))
var agentRequests = 0
DispatchQueue.global().async {
    var buffer = [UInt8](repeating: 0, count: 2048)
    var peer = sockaddr_storage()
    var peerSize = socklen_t(MemoryLayout<sockaddr_storage>.size)
    let count = withUnsafeMutablePointer(to: &peer) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            recvfrom(agent, &buffer, buffer.count, 0, $0, &peerSize)
        }
    }
    guard count > 0 else { return }
    agentRequests += 1
    let request = Array(buffer[0..<count])
    // SEQUENCE { version, community, GetRequest { request-id, ... } }
    var index = 1
    _ = berLength(request, &index)
    index += 3
    index += 1
    index += berLength(request, &index)
    guard request[index] == 0xa0 else { return }
    index += 1
    _ = berLength(request, &index)
    index += 1
    let idLength = berLength(request, &index)
    let id = request[index..<index + idLength].reduce(0) { $0 << 8 | Int($1) }
    let reply = snmpResponse(requestID: id, bindings: statusBindings)
    _ = reply.withUnsafeBytes { bytes in
        withUnsafePointer(to: &peer) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(agent, bytes.baseAddress, bytes.count, 0, $0, peerSize)
            }
        }
    }
}
let liveReport = PrinterStatusClient.querySNMP(host: "127.0.0.1", port: agentPort, interface: "lo0")
expect(liveReport?.problems == ["缺纸"] && liveReport?.pageCount == 2_147_483_653,
       "SNMP status is read from a loopback agent through the selected interface")
close(agent)
expect(PrinterStatusClient.querySNMP(host: "127.0.0.1", port: agentPort, interface: "",
                                     attempts: 1, timeoutMilliseconds: 200) == nil,
       "a silent SNMP port means unknown status, not an error")
expect(PrinterStatusClient.query(host: "127.0.0.1", printPort: 9100, interface: "", mode: .off) == nil,
       "status queries are skipped when turned off")

let firstSent = UUID()
let secondSent = UUID()
var counter = [100, 101, 101, 103].makeIterator()
var confirmed: [UUID] = []
let allPrinted = PrintBatch.confirm(baseline: 100, sent: [(firstSent, 1), (secondSent, 2)], status: {
    counter.next().map { PrinterStatusReport(source: "SNMP", state: "打印中", pageCount: $0) }
}, token: CancellationToken(), wait: { _ in }) { event in
    if case .printed(let id) = event { confirmed.append(id) }
}
expect(allPrinted && confirmed == [firstSent, secondSent], "page counter confirms files in sending order")
var notices: [String] = []
let stalled = PrintBatch.confirm(baseline: 100, sent: [(firstSent, 1)], status: {
    PrinterStatusReport(source: "SNMP", state: "就绪", problems: ["卡纸"], pageCount: 100, severity: .error)
}, token: CancellationToken(), timeout: 4, wait: { _ in }) { event in
    if case .notice(let message) = event { notices.append(message) }
}
expect(!stalled && notices.count == 2 && notices[0].contains("卡纸") && notices[1].contains("未能"),
       "a stalled counter reports the printer problem once, then gives up")
let cancelledToken = CancellationToken()
cancelledToken.cancel()
expect(!PrintBatch.confirm(baseline: 0, sent: [(firstSent, 1)], status: { nil }, token: cancelledToken,
                           wait: { _ in }, event: { _ in }), "a newer batch cancels the old confirmation")
let pjlListener = socket(AF_INET, SOCK_STREAM, 0)
var pjlAddress = sockaddr_in()
pjlAddress.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
pjlAddress.sin_family = sa_family_t(AF_INET)
pjlAddress.sin_addr.s_addr = inet_addr("127.0.0.1")
let pjlBound = withUnsafePointer(to: &pjlAddress) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(pjlListener, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
    }
}
var pjlSize = socklen_t(MemoryLayout<sockaddr_in>.size)
_ = withUnsafeMutablePointer(to: &pjlAddress) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(pjlListener, $0, &pjlSize) }
}
expect(pjlBound == 0 && listen(pjlListener, 1) == 0, "bind loopback PJL printer")
var pjlRequest = Data()
DispatchQueue.global().async {
    let peer = accept(pjlListener, nil, nil)
    guard peer >= 0 else { return }
    var chunk = [UInt8](repeating: 0, count: 512)
    while pjlRequest.range(of: Data("INFO PAGECOUNT\r\n\u{1b}%-12345X".utf8)) == nil {
        let count = recv(peer, &chunk, chunk.count, 0)
        if count <= 0 { break }
        pjlRequest.append(contentsOf: chunk.prefix(count))
    }
    let reply = Array(("@PJL INFO STATUS\r\nCODE=40021\r\nDISPLAY=\"Cover is Open\"\r\nONLINE=FALSE\r\n\u{0c}" +
                       "@PJL INFO PAGECOUNT\r\nPAGECOUNT=5215\r\n\u{0c}").utf8)
    _ = reply.withUnsafeBytes { Darwin.send(peer, $0.baseAddress, $0.count, 0) }
    close(peer)
}
let pjlLive = PrinterStatusClient.query(host: "127.0.0.1", printPort: Int(UInt16(bigEndian: pjlAddress.sin_port)),
                                        interface: "", mode: .snmpAndPJL, snmpPort: agentPort)
close(pjlListener)
expect(pjlLive?.source == "PJL" && pjlLive?.problems == ["机盖打开"] && pjlLive?.display == "Cover is Open" &&
       pjlLive?.pageCount == 5215,
       "PJL fallback reads status over the print port when SNMP is silent")
expect(pjlRequest == Data(PJLStatus.query), "the PJL query sends only INFO STATUS and INFO PAGECOUNT")
var statusDefaults = PrinterPreferences(defaults: preferencesStore)
expect(statusDefaults.statusMode == .snmpAndPJL && statusDefaults.snmpPort == 161,
       "status defaults to automatic SNMP, then PJL")
statusDefaults.statusMode = .snmp
statusDefaults.snmpPort = 10161
try statusDefaults.save(to: preferencesStore)
let reloadedStatus = PrinterPreferences(defaults: preferencesStore)
expect(reloadedStatus.statusMode == .snmp && reloadedStatus.snmpPort == 10161, "status settings are saved")


// Pages per sheet and manual duplex.
let a4Sheet = CGSize(width: 579, height: 818)
let a4Page = CGSize(width: 595, height: 842)
let twoUp = SheetGrid.best(count: 2, sheet: a4Sheet, page: a4Page)
expect(twoUp.columns == 2 && twoUp.rows == 1 && twoUp.rotated, "2 in 1 turns the sheet for two large portrait pages")
for (count, side) in [(4, 2), (9, 3), (16, 4)] {
    let grid = SheetGrid.best(count: count, sheet: a4Sheet, page: a4Page)
    expect(grid.columns == side && grid.rows == side && !grid.rotated, "\(count) in 1 is an upright square grid")
}
let square = SheetGrid.best(count: 4, sheet: a4Sheet, page: a4Page)
let topLeft = square.cell(0, order: .rightThenDown)
expect(topLeft.minX == 0 && topLeft.maxY == 818, "the first page starts at the top left")
expect(square.cell(1, order: .rightThenDown).minX > 0 && square.cell(1, order: .rightThenDown).maxY == 818,
       "left to right, then down")
expect(square.cell(1, order: .downThenRight).minX == 0 && square.cell(1, order: .downThenRight).maxY < 818,
       "top to bottom, then right")
expect(square.cell(0, order: .leftThenDown).minX > 0 && square.cell(0, order: .downThenLeft).minX > 0,
       "right-to-left orders start at the top right")

var twoUpSetup = PageSetup()
twoUpSetup.layout = 2
let twoUpRaster = Array(try PrintEngine.raster(document, pages: [1, 2], rotate: false, fit: true, setup: twoUpSetup)
    .dropFirst(header.count))
func blackInColumn(_ bits: [UInt8], _ x: Int) -> Int {
    (0..<PageSetup().height).filter { bits[$0 * PageSetup().rowBytes + x / 8] & UInt8(0x80 >> (x % 8)) != 0 }.count
}
// Each test page has a black band along its top; turned pages put their tops at the sheet's left edge.
expect(blackInColumn(twoUpRaster, 200) > 2000 && blackInColumn(twoUpRaster, PageSetup().width - 200) == 0,
       "2 in 1 pages are turned with their tops on the left")
expect(rejected { _ = try PrintEngine.raster(document, pages: [1, 2], rotate: false, fit: true, setup: PageSetup()) },
       "one page per sheet takes exactly one page")

var duplexSetup = PageSetup()
duplexSetup.manualDuplex = true
let decoder = JSONDecoder()
let legacyPreset = try decoder.decode(PrintPreset.self, from: Data(
    #"{"name":"旧预设","setup":{"paper":"A5","quality":"draft","media":"PLAIN","density":0}}"#.utf8))
expect(legacyPreset.setup.paper == .a5 && legacyPreset.setup.layout == 1 && !legacyPreset.setup.manualDuplex,
       "presets saved before layouts existed still load")
expect(rejected { _ = try decoder.decode(PageSetup.self, from: Data(#"{"layout":3}"#.utf8)) },
       "an unsupported pages-per-sheet value is rejected")
expect(duplexSetup.summary.contains("手动双面") && twoUpSetup.summary.contains("2 合 1"), "summary names the layout")

if CommandLine.arguments.count > 1 {
    let encoder = URL(fileURLWithPath: CommandLine.arguments[1])
    func pages(_ url: URL) throws -> Int {
        let data = try Data(contentsOf: url)
        var count = 0
        var range = data.startIndex..<data.endIndex
        while let found = data.range(of: Data("1030M\u{0c}".utf8), in: range) {
            count += 1
            range = found.upperBound..<data.endIndex
        }
        return count
    }
    var options = valid
    options.setup = twoUpSetup
    let twoUpJob = try PrintEngine.prepare(document, options: options, encoder: encoder, progress: { _ in })
    let twoUpPages = try pages(twoUpJob.dataURL)
    expect(twoUpJob.sheets == 1 && twoUpJob.back == nil && twoUpPages == 1, "two pages print on one sheet")
    twoUpJob.remove()

    let threePages = folder.appendingPathComponent("three.pdf")
    var threeBox = CGRect(x: 0, y: 0, width: 595, height: 842)
    let threeContext = CGContext(consumer: CGDataConsumer(url: threePages as CFURL)!, mediaBox: &threeBox, nil)!
    for _ in 0..<3 { threeContext.beginPDFPage(nil); threeContext.endPDFPage() }
    threeContext.closePDF()
    let three = try PrintDocument(url: threePages)
    options = PrintOptions(host: "192.0.2.10", port: 9100, copies: 2, firstPage: 1, lastPage: 3,
                           rotate: false, fit: true, setup: duplexSetup)
    let duplexJob = try PrintEngine.prepare(three, options: options, encoder: encoder, progress: { _ in })
    // Per copy: fronts 1 and 3, backs 2 and a blank, so every copy ends on a complete sheet.
    let frontPages = try pages(duplexJob.dataURL)
    let backPages = try duplexJob.back.map { try pages($0.dataURL) }
    expect(duplexJob.sheets == 4 && duplexJob.back?.sheets == 4 && frontPages == 4 && backPages == 4,
           "manual duplex pads each copy to whole sheets")
    duplexJob.remove()
    options = PrintOptions(host: "192.0.2.10", port: 9100, copies: 1, firstPage: 1, lastPage: 1,
                           rotate: false, fit: true, setup: duplexSetup)
    let singleSheet = try PrintEngine.prepare(three, options: options, encoder: encoder, progress: { _ in })
    expect(singleSheet.back == nil && singleSheet.sheets == 1, "a single sheet needs no second pass")
    singleSheet.remove()

    func loopbackListener() -> (descriptor: Int32, port: Int) {
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        _ = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        listen(listener, 4)
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &size) }
        }
        return (listener, Int(UInt16(bigEndian: address.sin_port)))
    }
    func drain(_ listener: Int32, connections: Int, done: DispatchSemaphore, into counter: @escaping (Int) -> Void) {
        DispatchQueue.global().async {
            for _ in 0..<connections {
                let peer = accept(listener, nil, nil)
                guard peer >= 0 else { break }
                var chunk = [UInt8](repeating: 0, count: 4096)
                while recv(peer, &chunk, chunk.count, 0) > 0 {}
                close(peer)
                counter(1)
            }
            done.signal()
        }
    }
    let duplexPrinter = loopbackListener()
    let duplexDone = DispatchSemaphore(value: 0)
    var duplexConnections = 0
    drain(duplexPrinter.descriptor, connections: 2, done: duplexDone) { duplexConnections += $0 }
    let duplexFile = QueuedPrintFile(document: document, setup: duplexSetup)
    var duplexConnection = PrinterPreferences(defaults: preferencesStore)
    duplexConnection.host = "127.0.0.1"
    duplexConnection.port = duplexPrinter.port
    duplexConnection.interface = ""
    var flips: [Int] = []
    var states: [PrintJobState] = []
    var duplexSent = 0
    try PrintBatch.run([duplexFile.task(connection: duplexConnection)], encoder: encoder, flip: { _, fronts in
        flips.append(fronts)
        return true
    }) { event in
        if case .state(_, let state) = event { states.append(state) }
        if case .sent(_, let sheets) = event { duplexSent = sheets }
    }
    expect(duplexDone.wait(timeout: .now() + 10) == .success && duplexConnections == 2,
           "fronts and backs go out as two print jobs")
    expect(flips == [1] && states.contains(.flipping) && duplexSent == 2,
           "the batch waits for the flip between passes and counts both sides")
    close(duplexPrinter.descriptor)

    let cancelPrinter = loopbackListener()
    let cancelDone = DispatchSemaphore(value: 0)
    var cancelConnections = 0
    drain(cancelPrinter.descriptor, connections: 1, done: cancelDone) { cancelConnections += $0 }
    duplexConnection.port = cancelPrinter.port
    var cancelSent = false
    expect(rejected {
        try PrintBatch.run([duplexFile.task(connection: duplexConnection)], encoder: encoder,
                           flip: { _, _ in false }) { event in
            if case .sent = event { cancelSent = true }
        }
    }, "cancelling the flip stops the batch")
    expect(cancelDone.wait(timeout: .now() + 10) == .success && cancelConnections == 1 && !cancelSent,
           "only the fronts were sent")
    close(cancelPrinter.descriptor)
}

print("Core checks passed: drag state, settings, file receipts, PDF/PNG rendering, TCP binding, batch delivery, printer status, layouts and manual duplex.")
