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
let raster = try PrintEngine.raster(document, page: 1, rotate: false, fit: true)
let header = Data("P4\n4825 6817\n".utf8)
expect(raster.starts(with: header), "PBM header")
expect(raster.count == header.count + PrintEngine.rowBytes * PrintEngine.height, "exact raster length")
let body = Array(raster.dropFirst(header.count))
let topBlack = body[PrintEngine.rowBytes * 100..<(PrintEngine.rowBytes * 101)].reduce(0) { $0 + $1.nonzeroBitCount }
let bottomBlack = body[PrintEngine.rowBytes * 6700..<(PrintEngine.rowBytes * 6701)].reduce(0) { $0 + $1.nonzeroBitCount }
expect(topBlack > 4000 && bottomBlack == 0, "PDF top stays at the top of the printer raster")
for row in 0..<PrintEngine.height {
    expect(body[(row + 1) * PrintEngine.rowBytes - 1] & 0x7f == 0, "white row padding")
}
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
expect(StatusDropView.acceptedFile(from: dragBoard) == pdfURL, "Finder file URL drag is accepted")
dragBoard.clearContents()
dragBoard.writeObjects([pdfURL as NSURL, pngURL as NSURL])
expect(StatusDropView.acceptedFile(from: dragBoard) == nil, "multiple simultaneous file drops are rejected")
dragBoard.clearContents()
dragBoard.writeObjects([folder.appendingPathComponent("unsupported.docx") as NSURL])
expect(StatusDropView.acceptedFile(from: dragBoard) == nil, "unsupported file drop is rejected")
let imageRaster = Array(try PrintEngine.raster(imageDocument, page: 1, rotate: false, fit: true).dropFirst(header.count))
let middleRow = PrintEngine.height / 2 * PrintEngine.rowBytes
expect(imageRaster[middleRow + (PrintEngine.width / 4) / 8] == 255, "black image pixels")
expect(imageRaster[middleRow + (PrintEngine.width * 3 / 4) / 8] == 0, "transparent image background stays white")

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
}
print("Core checks passed: validation, PDF/PNG rendering, raster layout, TCP delivery and complete print stream.")
