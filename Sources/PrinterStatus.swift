// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import Darwin

/// What the printer reported, from SNMP (Printer MIB / Host Resources MIB) or PJL INFO STATUS.
struct PrinterStatusReport: Equatable {
    enum Severity: Int, Comparable {
        case ok, warning, error
        static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    var source: String
    var state: String
    var problems: [String] = []
    var display: String?
    var tonerPercent: Int?
    var pageCount: Int?
    var severity = Severity.ok

    var summary: String {
        var parts = [problems.isEmpty ? state : problems.joined(separator: "、")]
        if let toner = tonerPercent { parts.append("碳粉 \(toner)%") }
        return parts.joined(separator: " · ")
    }
}

enum PrinterStatusMode: String, CaseIterable {
    case off, snmp, snmpAndPJL

    var label: String {
        switch self {
        case .off: return "不查询"
        case .snmp: return "仅 SNMP（UDP）"
        case .snmpAndPJL: return "自动：SNMP，不通时经打印端口查询 PJL"
        }
    }
}

// MARK: - SNMP

enum SNMPValue: Equatable {
    case integer(Int)
    case octets([UInt8])
    case missing
}

/// Minimal SNMP v2c GET over BER, enough for the read-only status OIDs below.
enum SNMP {
    static let deviceStatus = "1.3.6.1.2.1.25.3.2.1.5.1"
    static let printerStatus = "1.3.6.1.2.1.25.3.5.1.1.1"
    static let detectedErrorState = "1.3.6.1.2.1.25.3.5.1.2.1"
    static let consoleDisplay = "1.3.6.1.2.1.43.16.5.1.2.1.1"
    static let pageCount = "1.3.6.1.2.1.43.10.2.1.4.1.1"
    static let tonerLevel = "1.3.6.1.2.1.43.11.1.1.9.1.1"
    static let tonerCapacity = "1.3.6.1.2.1.43.11.1.1.8.1.1"
    static let statusOIDs = [deviceStatus, printerStatus, detectedErrorState, consoleDisplay,
                             pageCount, tonerLevel, tonerCapacity]

    static func length(_ count: Int) -> [UInt8] {
        if count < 0x80 { return [UInt8(count)] }
        var bytes: [UInt8] = []
        var value = count
        while value > 0 { bytes.insert(UInt8(value & 0xff), at: 0); value >>= 8 }
        return [0x80 | UInt8(bytes.count)] + bytes
    }

    static func tlv(_ tag: UInt8, _ body: [UInt8]) -> [UInt8] { [tag] + length(body.count) + body }

    static func integer(_ value: Int) -> [UInt8] {
        var bytes: [UInt8] = []
        var remaining = value
        repeat {
            bytes.insert(UInt8(truncatingIfNeeded: remaining), at: 0)
            remaining >>= 8
        } while remaining != 0 && remaining != -1
        if value >= 0, bytes[0] & 0x80 != 0 { bytes.insert(0, at: 0) }
        if value < 0, bytes[0] & 0x80 == 0 { bytes.insert(0xff, at: 0) }
        return tlv(0x02, bytes)
    }

    static func oid(_ dotted: String) -> [UInt8] {
        let arcs = dotted.split(separator: ".").compactMap { Int($0) }
        precondition(arcs.count >= 2)
        var body = [UInt8(arcs[0] * 40 + arcs[1])]
        for arc in arcs.dropFirst(2) {
            var chunk = [UInt8(arc & 0x7f)]
            var value = arc >> 7
            while value > 0 { chunk.insert(UInt8(value & 0x7f) | 0x80, at: 0); value >>= 7 }
            body += chunk
        }
        return tlv(0x06, body)
    }

    static func getRequest(community: String, requestID: Int, oids: [String]) -> [UInt8] {
        let bindings = oids.flatMap { tlv(0x30, oid($0) + [0x05, 0x00]) }
        let pdu = tlv(0xa0, integer(requestID) + integer(0) + integer(0) + tlv(0x30, bindings))
        return tlv(0x30, integer(1) + tlv(0x04, Array(community.utf8)) + pdu)
    }

    private struct Reader {
        let bytes: [UInt8]
        var offset = 0
        mutating func next() -> (tag: UInt8, body: ArraySlice<UInt8>)? {
            guard offset + 2 <= bytes.count else { return nil }
            let tag = bytes[offset]
            var count = Int(bytes[offset + 1])
            offset += 2
            if count & 0x80 != 0 {
                let size = count & 0x7f
                guard size <= 3, offset + size <= bytes.count else { return nil }
                count = bytes[offset..<offset + size].reduce(0) { $0 << 8 | Int($1) }
                offset += size
            }
            guard offset + count <= bytes.count else { return nil }
            defer { offset += count }
            return (tag, bytes[offset..<offset + count])
        }
    }

    static func decodeInteger(_ body: ArraySlice<UInt8>) -> Int {
        guard let first = body.first else { return 0 }
        return body.dropFirst().reduce(first & 0x80 != 0 ? -1 << 8 | Int(first) : Int(first)) { $0 << 8 | Int($1) }
    }

    static func decodeOID(_ body: ArraySlice<UInt8>) -> String {
        guard let first = body.first else { return "" }
        var arcs = [Int(first) / 40, Int(first) % 40]
        var value = 0
        for byte in body.dropFirst() {
            value = value << 7 | Int(byte & 0x7f)
            if byte & 0x80 == 0 { arcs.append(value); value = 0 }
        }
        return arcs.map(String.init).joined(separator: ".")
    }

    /// Parses a GetResponse; returns nil for anything else or a different request id.
    static func parseResponse(_ data: [UInt8], requestID: Int) -> [String: SNMPValue]? {
        var message = Reader(bytes: data)
        guard let outer = message.next(), outer.tag == 0x30 else { return nil }
        var fields = Reader(bytes: Array(outer.body))
        guard fields.next()?.tag == 0x02, fields.next()?.tag == 0x04,
              let pdu = fields.next(), pdu.tag == 0xa2 else { return nil }
        var pduFields = Reader(bytes: Array(pdu.body))
        guard let id = pduFields.next(), id.tag == 0x02, decodeInteger(id.body) == requestID,
              let errorStatus = pduFields.next(), decodeInteger(errorStatus.body) == 0,
              pduFields.next() != nil, let list = pduFields.next(), list.tag == 0x30 else { return nil }
        var bindings = Reader(bytes: Array(list.body))
        var values: [String: SNMPValue] = [:]
        while let binding = bindings.next() {
            var pair = Reader(bytes: Array(binding.body))
            guard let name = pair.next(), name.tag == 0x06, let value = pair.next() else { continue }
            switch value.tag {
            case 0x02: values[decodeOID(name.body)] = .integer(decodeInteger(value.body))
            case 0x41, 0x42, 0x43:
                // Counter32, Gauge32 and TimeTicks are unsigned even when an agent omits the leading zero.
                values[decodeOID(name.body)] = .integer(value.body.reduce(0) { $0 << 8 | Int($1) })
            case 0x04: values[decodeOID(name.body)] = .octets(Array(value.body))
            default: values[decodeOID(name.body)] = .missing
            }
        }
        return values
    }

    /// hrPrinterDetectedErrorState bits, most significant bit of the first byte first.
    static let errorBits: [(name: String, severity: PrinterStatusReport.Severity)] = [
        ("纸张将尽", .warning), ("缺纸", .error), ("碳粉不足", .warning), ("碳粉耗尽", .error),
        ("机盖打开", .error), ("卡纸", .error), ("脱机", .error), ("需要维修", .error),
        ("纸盒未装好", .error), ("出纸托盘未装好", .warning), ("未装硒鼓或墨粉盒", .error),
        ("出纸托盘将满", .warning), ("出纸托盘已满", .error), ("纸盒无纸", .error), ("需要保养", .warning)
    ]

    static func report(from values: [String: SNMPValue]) -> PrinterStatusReport? {
        func int(_ oid: String) -> Int? { if case .integer(let value)? = values[oid] { return value }; return nil }
        guard int(deviceStatus) != nil || int(printerStatus) != nil || int(pageCount) != nil else { return nil }
        var report = PrinterStatusReport(source: "SNMP", state: "已连接")
        switch int(printerStatus) {
        case 3?: report.state = "就绪"
        case 4?: report.state = "打印中"
        case 5?: report.state = "预热中"
        default: break
        }
        if int(deviceStatus) == 5 { report.state = "故障"; report.severity = .error }
        else if int(deviceStatus) == 3 { report.severity = .warning }
        if case .octets(let bits)? = values[detectedErrorState] {
            for (index, bit) in errorBits.enumerated() where index / 8 < bits.count {
                if bits[index / 8] & (0x80 >> UInt8(index % 8)) != 0 {
                    report.problems.append(bit.name)
                    report.severity = max(report.severity, bit.severity)
                }
            }
        }
        if case .octets(let text)? = values[consoleDisplay] {
            let line = String(decoding: text, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if !line.isEmpty { report.display = line }
        }
        report.pageCount = int(pageCount).flatMap { $0 >= 0 ? $0 : nil }
        if let level = int(tonerLevel), let capacity = int(tonerCapacity), level >= 0, capacity > 0 {
            report.tonerPercent = min(100, level * 100 / capacity)
        }
        return report
    }
}

// MARK: - PJL

enum PJLStatus {
    static let query = Array("\u{1b}%-12345X@PJL\r\n@PJL INFO STATUS\r\n@PJL INFO PAGECOUNT\r\n\u{1b}%-12345X".utf8)
    /// One form feed ends each INFO reply.
    static let replies = 2

    static func report(from text: String) -> PrinterStatusReport? {
        guard text.contains("INFO STATUS") else { return nil }
        var code: Int?
        var display: String?
        var online: Bool?
        var pages: Int?
        for raw in text.components(separatedBy: CharacterSet.newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("CODE=") { code = Int(line.dropFirst(5)) }
            else if line.hasPrefix("DISPLAY=") {
                display = String(line.dropFirst(8)).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            } else if line.hasPrefix("ONLINE=") { online = line.dropFirst(7).uppercased() == "TRUE" }
            else if line.hasPrefix("PAGECOUNT=") { pages = Int(line.dropFirst(10)) }
        }
        guard let status = code else { return nil }
        var report = PrinterStatusReport(source: "PJL", state: "已连接", display: display, pageCount: pages)
        switch status {
        case 10001, 10002: report.state = "就绪"
        case 10003: report.state = "预热中"
        case 10023: report.state = "打印中"
        case 10006, 40038: report.state = "就绪"; report.problems = ["碳粉不足"]; report.severity = .warning
        case 35078, 10005: report.state = "节能模式"
        case 40021: report.problems = ["机盖打开"]; report.severity = .error
        case 40022, 42000..<43000: report.problems = ["卡纸"]; report.severity = .error
        case 41000..<42000: report.problems = ["缺纸"]; report.severity = .error
        case 40079: report.problems = ["脱机"]; report.severity = .error
        default:
            report.state = display ?? "状态码 \(status)"
            if status >= 30000 { report.severity = .warning }
        }
        if online == false && report.problems.isEmpty { report.problems = ["脱机"]; report.severity = .error }
        return report
    }
}

// MARK: - Client

enum PrinterStatusClient {
    private static let lock = NSLock()
    private static var pjlAnswered = false

    /// Best effort and read only: never sends print data, and nil means "unknown", not "offline".
    /// In automatic mode the source that answered last is tried first, so a network without SNMP
    /// does not wait for an SNMP timeout on every poll.
    static func query(host: String, printPort: Int, interface: String, mode: PrinterStatusMode,
                      snmpPort: Int = 161) -> PrinterStatusReport? {
        guard mode != .off, !host.isEmpty else { return nil }
        guard mode == .snmpAndPJL else { return querySNMP(host: host, port: snmpPort, interface: interface) }
        lock.lock()
        let pjlFirst = pjlAnswered
        lock.unlock()
        let pjl = { queryPJL(host: host, port: printPort, interface: interface) }
        let snmp = { querySNMP(host: host, port: snmpPort, interface: interface, attempts: 1) }
        let report = pjlFirst ? (pjl() ?? snmp()) : (snmp() ?? pjl())
        lock.lock()
        if let source = report?.source { pjlAnswered = source == "PJL" }
        lock.unlock()
        return report
    }

    /// Re-reads from the same source as `report`, so page counters stay comparable.
    static func query(like report: PrinterStatusReport, host: String, printPort: Int, interface: String,
                      snmpPort: Int = 161) -> PrinterStatusReport? {
        report.source == "PJL" ? queryPJL(host: host, port: printPort, interface: interface) :
            querySNMP(host: host, port: snmpPort, interface: interface)
    }

    static func querySNMP(host: String, port: Int, interface: String, community: String = "public",
                          attempts: Int = 2, timeoutMilliseconds: Int32 = 1000) -> PrinterStatusReport? {
        let descriptor = socket(AF_INET, SOCK_DGRAM, 0)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        if !interface.isEmpty {
            var index = if_nametoindex(interface)
            guard index != 0, setsockopt(descriptor, IPPROTO_IP, IP_BOUND_IF, &index,
                                         socklen_t(MemoryLayout<UInt32>.size)) == 0 else { return nil }
        }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        guard (1...65535).contains(port), host.withCString({ inet_pton(AF_INET, $0, &address.sin_addr) }) == 1
        else { return nil }
        let requestID = Int.random(in: 1...0x7fff_ffff)
        let request = SNMP.getRequest(community: community, requestID: requestID, oids: SNMP.statusOIDs)
        var buffer = [UInt8](repeating: 0, count: 4096)
        for _ in 0..<attempts {
            let sent = request.withUnsafeBytes { bytes in
                withUnsafePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(descriptor, bytes.baseAddress, bytes.count, 0, $0,
                               socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
            guard sent == request.count else { return nil }
            let deadline = Date().addingTimeInterval(Double(timeoutMilliseconds) / 1000)
            while Date() < deadline {
                var event = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
                let wait = Int32(max(1, deadline.timeIntervalSinceNow * 1000))
                guard poll(&event, 1, wait) > 0 else { break }
                let count = recv(descriptor, &buffer, buffer.count, 0)
                guard count > 0 else { break }
                if let values = SNMP.parseResponse(Array(buffer[0..<count]), requestID: requestID) {
                    return SNMP.report(from: values)
                }
            }
        }
        return nil
    }

    static func queryPJL(host: String, port: Int, interface: String,
                         timeoutMilliseconds: Int32 = 3000) -> PrinterStatusReport? {
        guard let descriptor = try? PrintEngine.connect(host: host, port: port, interface: interface,
                                                        timeoutMilliseconds: 2000) else { return nil }
        defer { close(descriptor) }
        let written = PJLStatus.query.withUnsafeBytes { Darwin.send(descriptor, $0.baseAddress, $0.count, 0) }
        guard written == PJLStatus.query.count else { return nil }
        var received: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 1024)
        let deadline = Date().addingTimeInterval(Double(timeoutMilliseconds) / 1000)
        while Date() < deadline, received.filter({ $0 == 0x0c }).count < PJLStatus.replies {
            var event = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            guard poll(&event, 1, Int32(max(1, deadline.timeIntervalSinceNow * 1000))) > 0 else { break }
            let count = recv(descriptor, &buffer, buffer.count, 0)
            guard count > 0 else { break }
            received += buffer[0..<count]
        }
        return PJLStatus.report(from: String(decoding: received, as: UTF8.self))
    }
}
