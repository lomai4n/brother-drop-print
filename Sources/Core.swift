// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import CoreGraphics
import ImageIO
import CoreText
import Darwin
import SystemConfiguration

struct NetworkAdapter {
    let name: String
    let label: String
}

struct PrintFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct PrintDocument {
    let url: URL
    let pageCount: Int
    let isPDF: Bool

    init(url: URL) throws {
        guard url.isFileURL,
              try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw PrintFailure(message: "请拖入一个文件。")
        }
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" {
            guard let pdf = CGPDFDocument(url as CFURL), pdf.isUnlocked,
                  pdf.numberOfPages > 0 else {
                throw PrintFailure(message: "PDF 无法读取或需要密码，请先解锁后再打印。")
            }
            isPDF = true
            pageCount = pdf.numberOfPages
        } else if ["png", "jpg", "jpeg"].contains(ext),
                  let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  CGImageSourceGetCount(source) > 0 {
            isPDF = false
            pageCount = 1
        } else {
            throw PrintFailure(message: "支持 PDF、PNG 和 JPEG。其他文档请先导出为 PDF。")
        }
        self.url = url
    }
}

enum PaperSize: String, CaseIterable {
    case a4 = "A4", a5 = "A5", a6 = "A6", b5 = "B5"
    case letter = "LETTER", legal = "LEGAL", executive = "EXECUTIVE"

    var label: String {
        switch self {
        case .a4: return "A4"
        case .a5: return "A5"
        case .a6: return "A6"
        case .b5: return "B5"
        case .letter: return "Letter"
        case .legal: return "Legal"
        case .executive: return "Executive"
        }
    }

    /// Size in points; must match the table in native/Encoder.cpp.
    var points: CGSize {
        switch self {
        case .a4: return CGSize(width: 595, height: 842)
        case .a5: return CGSize(width: 420, height: 595)
        case .a6: return CGSize(width: 297, height: 420)
        case .b5: return CGSize(width: 499, height: 709)
        case .letter: return CGSize(width: 612, height: 792)
        case .legal: return CGSize(width: 612, height: 1008)
        case .executive: return CGSize(width: 522, height: 756)
        }
    }
}

enum PrintQuality: String, CaseIterable {
    case standard, draft, tonerSave

    var label: String {
        switch self {
        case .standard: return "标准 600 dpi"
        case .draft: return "草稿 300 dpi"
        case .tonerSave: return "省墨 600 dpi"
        }
    }
    var dpi: Int { self == .draft ? 300 : 600 }
}

enum MediaType: String, CaseIterable {
    case plain = "PLAIN", thin = "THIN", thick = "THICK", thicker = "THICKER", bond = "BOND", envelope = "ENV"

    var label: String {
        switch self {
        case .plain: return "普通纸"
        case .thin: return "薄纸"
        case .thick: return "厚纸"
        case .thicker: return "较厚纸"
        case .bond: return "证券纸"
        case .envelope: return "信封"
        }
    }
}

/// Paper and output settings for one job. Geometry follows the upstream brlaser margins
/// (left 8, bottom 8, right 8, top 16 points), which A4 600 dpi output has confirmed.
struct PageSetup: Equatable {
    var paper = PaperSize.a4
    var quality = PrintQuality.standard
    var media = MediaType.plain
    var density = 0

    static let marginLeft: CGFloat = 8
    static let marginBottom: CGFloat = 8
    static let densityRange = -6...6

    var printableSize: CGSize {
        CGSize(width: paper.points.width - 16, height: paper.points.height - 24)
    }
    var width: Int { Int((printableSize.width * CGFloat(quality.dpi) / 72).rounded()) }
    var height: Int { Int((printableSize.height * CGFloat(quality.dpi) / 72).rounded()) }
    var rowBytes: Int { (width + 7) / 8 }
    var summary: String { "\(paper.label) · \(quality.label) · \(media.label)" }

    var encoderArguments: [String] {
        [paper.rawValue, String(quality.dpi), quality == .tonerSave ? "1" : "0", String(density), media.rawValue]
    }

    /// The last setup used, so new files start from it.
    static func saved(_ defaults: UserDefaults = .standard) -> PageSetup {
        var setup = PageSetup()
        if let value = defaults.string(forKey: "pagePaper"), let paper = PaperSize(rawValue: value) { setup.paper = paper }
        if let value = defaults.string(forKey: "pageQuality"), let quality = PrintQuality(rawValue: value) {
            setup.quality = quality
        }
        if let value = defaults.string(forKey: "pageMedia"), let media = MediaType(rawValue: value) { setup.media = media }
        let density = defaults.integer(forKey: "pageDensity")
        if densityRange.contains(density) { setup.density = density }
        return setup
    }

    func save(_ defaults: UserDefaults = .standard) {
        defaults.set(paper.rawValue, forKey: "pagePaper")
        defaults.set(quality.rawValue, forKey: "pageQuality")
        defaults.set(media.rawValue, forKey: "pageMedia")
        defaults.set(density, forKey: "pageDensity")
    }
}

struct PrintOptions {
    let host: String
    let port: Int
    let copies: Int
    let firstPage: Int
    let lastPage: Int
    let rotate: Bool
    let fit: Bool
    var interface: String = ""
    var setup = PageSetup()

    static func validateAddress(host: String, port: Int) throws {
        var address = in_addr()
        guard host.withCString({ inet_pton(AF_INET, $0, &address) }) == 1 else {
            throw PrintFailure(message: "请输入打印机或转发路由器的 IPv4 地址。")
        }
        guard (1...65535).contains(port) else {
            throw PrintFailure(message: "端口必须在 1–65535 之间。")
        }
    }

    static func validatePages(copies: Int, firstPage: Int, lastPage: Int, pageCount: Int) throws {
        guard (1...99).contains(copies) else {
            throw PrintFailure(message: "份数必须在 1–99 之间。")
        }
        guard firstPage >= 1, lastPage >= firstPage, lastPage <= pageCount else {
            throw PrintFailure(message: "页码范围超出了文档页数。")
        }
    }

    func validate(pageCount: Int) throws {
        try Self.validateAddress(host: host, port: port)
        try Self.validatePages(copies: copies, firstPage: firstPage, lastPage: lastPage, pageCount: pageCount)
        guard interface.isEmpty || if_nametoindex(interface) != 0 else {
            throw PrintFailure(message: "选定的网卡不可用，请检查有线连接或重新选择网卡。")
        }
    }
}

struct PreparedJob {
    let directory: URL
    let dataURL: URL
    let sheets: Int
    func remove() { try? FileManager.default.removeItem(at: directory) }
}

enum PrintEngine {
    // The calibration page stays A4.
    static let paperWidth: CGFloat = 595
    static let paperHeight: CGFloat = 842

    static func networkAdapters() -> [NetworkAdapter] {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        var active = Set<String>()
        if getifaddrs(&addresses) == 0 {
            defer { freeifaddrs(addresses) }
            var pointer = addresses
            while let entry = pointer {
                let interface = entry.pointee
                if interface.ifa_addr?.pointee.sa_family == sa_family_t(AF_INET),
                   interface.ifa_flags & UInt32(IFF_UP) != 0 {
                    active.insert(String(cString: interface.ifa_name))
                }
                pointer = interface.ifa_next
            }
        }
        let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] ?? []
        return interfaces.compactMap { interface in
            guard let name = SCNetworkInterfaceGetBSDName(interface) as String?,
                  active.contains(name),
                  let type = SCNetworkInterfaceGetInterfaceType(interface) as String?,
                  type == kSCNetworkInterfaceTypeEthernet as String ||
                    type == kSCNetworkInterfaceTypeIEEE80211 as String else { return nil }
            let display = SCNetworkInterfaceGetLocalizedDisplayName(interface) as String? ?? name
            let kind = type == kSCNetworkInterfaceTypeEthernet as String ? "有线" : "Wi-Fi"
            return NetworkAdapter(name: name, label: "\(display) · \(name)（\(kind)）")
        }.sorted { $0.name < $1.name }
    }

    static func prepare(_ document: PrintDocument, options: PrintOptions,
                        encoder: URL, progress: (String) -> Void) throws -> PreparedJob {
        try options.validate(pageCount: document.pageCount)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrotherDropPrint-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        do {
            let selectedPages = Array(options.firstPage...options.lastPage)
            let setup = options.setup
            let estimatedBytes = Int64(selectedPages.count) * Int64(setup.rowBytes * setup.height)
                * (1 + 2 * Int64(options.copies))
            let attributes = try FileManager.default.attributesOfFileSystem(forPath: directory.path)
            let free = (attributes[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
            guard free > estimatedBytes + 100_000_000 else {
                throw PrintFailure(message: "临时磁盘空间不足，请减少页数或份数后重试。")
            }
            var pages: [URL] = []
            for (index, page) in selectedPages.enumerated() {
                progress("正在转换第 \(index + 1)/\(selectedPages.count) 页…")
                let target = directory.appendingPathComponent("page-\(page).pbm")
                try raster(document, page: page, rotate: options.rotate, fit: options.fit, setup: setup)
                    .write(to: target)
                pages.append(target)
            }
            progress("正在生成打印数据…")
            let dataURL = directory.appendingPathComponent("job.prn")
            let process = Process()
            process.executableURL = encoder
            process.arguments = [dataURL.path, String(options.copies)] + setup.encoderArguments + pages.map(\.path)
            let errors = Pipe()
            process.standardError = errors
            try process.run()
            let errorData = errors.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw PrintFailure(message: "编码失败：\(String(decoding: errorData, as: UTF8.self))")
            }
            guard let size = try dataURL.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 128 else {
                throw PrintFailure(message: "打印数据为空，未发送任何任务。")
            }
            return PreparedJob(directory: directory, dataURL: dataURL,
                               sheets: selectedPages.count * options.copies)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    static func raster(_ document: PrintDocument, page number: Int,
                       rotate: Bool, fit: Bool, setup: PageSetup = PageSetup()) throws -> Data {
        guard (1...document.pageCount).contains(number) else {
            throw PrintFailure(message: "文档页码无效。")
        }
        let width = setup.width
        let height = setup.height
        let printableWidth = setup.printableSize.width
        let printableHeight = setup.printableSize.height
        var gray = [UInt8](repeating: 255, count: width * height)
        try gray.withUnsafeMutableBytes { memory in
            guard let context = CGContext(data: memory.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width,
                                          space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
                throw PrintFailure(message: "无法创建页面位图。")
            }
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.scaleBy(x: CGFloat(width) / printableWidth,
                            y: CGFloat(height) / printableHeight)
            context.interpolationQuality = .high
            if document.isPDF {
                guard let pdf = CGPDFDocument(document.url as CFURL), let page = pdf.page(at: number) else {
                    throw PrintFailure(message: "无法读取 PDF 页面。")
                }
                let box = page.getBoxRect(.cropBox)
                guard box.width.isFinite, box.height.isFinite, box.width > 0, box.height > 0 else {
                    throw PrintFailure(message: "PDF 页面尺寸无效。")
                }
                if fit {
                    context.concatenate(page.getDrawingTransform(
                        .cropBox,
                        rect: CGRect(x: 0, y: 0, width: printableWidth, height: printableHeight),
                        rotate: rotate ? 90 : 0, preserveAspectRatio: true))
                } else {
                    context.translateBy(x: setup.paper.points.width / 2 - PageSetup.marginLeft,
                                        y: setup.paper.points.height / 2 - PageSetup.marginBottom)
                    context.rotate(by: CGFloat(page.rotationAngle + (rotate ? 90 : 0)) * .pi / 180)
                    context.translateBy(x: -box.midX, y: -box.midY)
                }
                context.drawPDFPage(page)
            } else {
                let thumbnailOptions: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: max(width, height)
                ]
                guard let source = CGImageSourceCreateWithURL(document.url as CFURL, nil),
                      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
                    throw PrintFailure(message: "无法读取图片。")
                }
                context.translateBy(x: printableWidth / 2, y: printableHeight / 2)
                let imageWidth = CGFloat(rotate ? image.height : image.width)
                let imageHeight = CGFloat(rotate ? image.width : image.height)
                let scale = min(printableWidth / imageWidth, printableHeight / imageHeight)
                context.scaleBy(x: scale, y: scale)
                if rotate { context.rotate(by: .pi / 2) }
                context.draw(image, in: CGRect(x: -CGFloat(image.width) / 2, y: -CGFloat(image.height) / 2,
                                              width: CGFloat(image.width), height: CGFloat(image.height)))
            }
        }
        return pack(gray, width: width, height: height)
    }

    static func pack(_ gray: [UInt8], width: Int, height: Int) -> Data {
        precondition(gray.count == width * height)
        let rowBytes = (width + 7) / 8
        let bayer = [0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5]
        var pixels = [UInt8](repeating: 0, count: rowBytes * height)
        for y in 0..<height {
            for x in 0..<width {
                if Int(gray[y * width + x]) < bayer[(y & 3) * 4 + (x & 3)] * 16 + 8 {
                    pixels[y * rowBytes + x / 8] |= UInt8(0x80 >> (x & 7))
                }
            }
        }
        var result = Data("P4\n\(width) \(height)\n".utf8)
        result.append(contentsOf: pixels)
        return result
    }

    static func send(_ dataURL: URL, host: String, port: Int, interface: String = "",
                     progress: (String) -> Void) throws {
        let descriptor = try connect(host: host, port: port, interface: interface)
        defer { close(descriptor) }
        var timeout = timeval(tv_sec: 15, tv_usec: 0)
        guard setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout,
                         socklen_t(MemoryLayout<timeval>.size)) == 0 else {
            throw socketError("无法设置发送超时")
        }
        let input = try FileHandle(forReadingFrom: dataURL)
        defer { try? input.close() }
        var sent = 0
        while let chunk = try input.read(upToCount: 64 * 1024), !chunk.isEmpty {
            try chunk.withUnsafeBytes { memory in
                var offset = 0
                while offset < chunk.count {
                    let count = Darwin.send(descriptor, memory.baseAddress!.advanced(by: offset),
                                            chunk.count - offset, 0)
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else {
                        throw PrintFailure(message: "发送中断，部分页面可能已到达打印机。请检查出纸后再决定是否重试。")
                    }
                    offset += count
                    sent += count
                }
            }
            progress("正在发送… \(ByteCountFormatter.string(fromByteCount: Int64(sent), countStyle: .file))")
        }
        shutdown(descriptor, SHUT_WR)
    }

    /// Opens a blocking TCP connection, bound to `interface` when one is given. The caller closes it.
    static func connect(host: String, port: Int, interface: String = "",
                        timeoutMilliseconds: Int32 = 5000) throws -> Int32 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw socketError("无法创建打印连接") }
        var connected = false
        defer { if !connected { close(descriptor) } }
        var noSignal: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal,
                   socklen_t(MemoryLayout<Int32>.size))
        if !interface.isEmpty {
            var index = if_nametoindex(interface)
            guard index != 0 else {
                throw PrintFailure(message: "选定的网卡已断开，未发送打印数据。")
            }
            guard setsockopt(descriptor, IPPROTO_IP, IP_BOUND_IF, &index,
                             socklen_t(MemoryLayout<UInt32>.size)) == 0 else {
                throw socketError("无法绑定选定网卡")
            }
        }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        guard (1...65535).contains(port),
              host.withCString({ inet_pton(AF_INET, $0, &address.sin_addr) }) == 1 else {
            throw PrintFailure(message: "打印地址或端口无效。")
        }
        address.sin_port = UInt16(port).bigEndian
        let originalFlags = fcntl(descriptor, F_GETFL)
        guard originalFlags >= 0, fcntl(descriptor, F_SETFL, originalFlags | O_NONBLOCK) == 0 else {
            throw socketError("无法设置连接超时")
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if result != 0 {
            guard errno == EINPROGRESS else { throw socketError("无法连接打印机") }
            var event = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
            guard poll(&event, 1, timeoutMilliseconds) > 0 else {
                throw PrintFailure(message: "连接超时，请检查打印机 IP、端口和路由器转发。")
            }
            var socketStatus: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &socketStatus, &length) == 0 else {
                throw socketError("读取连接状态失败")
            }
            guard socketStatus == 0 else {
                throw PrintFailure(message: "无法连接打印机：\(String(cString: strerror(socketStatus)))")
            }
        }
        guard fcntl(descriptor, F_SETFL, originalFlags) == 0 else {
            throw socketError("无法准备打印连接")
        }
        connected = true
        return descriptor
    }

    static func socketError(_ prefix: String) -> PrintFailure {
        PrintFailure(message: "\(prefix)：\(String(cString: strerror(errno)))")
    }

    static func calibrationPDF(to url: URL) throws {
        var box = CGRect(x: 0, y: 0, width: paperWidth, height: paperHeight)
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: &box, nil) else {
            throw PrintFailure(message: "无法生成测试页。")
        }
        context.beginPDFPage(nil)
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(box)
        context.setStrokeColor(gray: 0, alpha: 1)
        context.setLineWidth(0.5)
        context.stroke(CGRect(x: 12, y: 12, width: 571, height: 814))
        for i in 0...10 {
            let x = 60 + CGFloat(i) * 10 * 72 / 25.4
            context.move(to: CGPoint(x: x, y: 710))
            context.addLine(to: CGPoint(x: x, y: 730))
        }
        context.move(to: CGPoint(x: 60, y: 720))
        context.addLine(to: CGPoint(x: 60 + 100 * 72 / 25.4, y: 720))
        context.strokePath()
        for i in 0..<8 {
            context.setFillColor(gray: CGFloat(i) / 7, alpha: 1)
            context.fill(CGRect(x: 60 + i * 60, y: 520, width: 60, height: 80))
        }
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 60, y: 780, width: 180, height: 18))
        context.fill(CGRect(x: 60, y: 80, width: 60, height: 18))
        func label(_ text: String, x: CGFloat, y: CGFloat, size: CGFloat = 12) {
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String):
                    CTFontCreateWithName("Helvetica" as CFString, size, nil),
                NSAttributedString.Key(kCTForegroundColorAttributeName as String):
                    CGColor(gray: 0, alpha: 1)
            ]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
            context.textPosition = CGPoint(x: x, y: y)
            CTLineDraw(line, context)
        }
        label("Brother Drop Print - Calibration", x: 60, y: 755, size: 18)
        label("100 mm at actual size (disable Fit)", x: 60, y: 690)
        label("Eight gray levels", x: 60, y: 500)
        label("TOP: long bar / BOTTOM: short bar", x: 60, y: 120)
        label("Check border, direction, gray levels and scale.", x: 60, y: 100)
        var noise = [UInt8](repeating: 0, count: 128 * 128)
        var seed: UInt32 = 0x51ab9c2d
        for index in noise.indices {
            seed = 1664525 &* seed &+ 1013904223
            noise[index] = UInt8(truncatingIfNeeded: seed >> 24)
        }
        if let provider = CGDataProvider(data: Data(noise) as CFData),
           let image = CGImage(width: 128, height: 128, bitsPerComponent: 8, bitsPerPixel: 8,
                               bytesPerRow: 128, space: CGColorSpaceCreateDeviceGray(),
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                               provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) {
            context.draw(image, in: CGRect(x: 60, y: 320, width: 96, height: 96))
            label("Dense-image test", x: 60, y: 300)
        }
        context.endPDFPage()
        context.closePDF()
    }
}
