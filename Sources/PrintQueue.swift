// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

enum PrintJobState: String {
    case waiting = "待处理"
    case preparing = "转换中"
    case sending = "发送中"
    case flipping = "等待翻面"
    case sent = "已发送"
    case printed = "已出纸"
    case failed = "需检查"
}

final class QueuedPrintFile {
    let id = UUID()
    let document: PrintDocument
    var state: PrintJobState = .waiting
    var copies = 1
    var firstPage = 1
    var lastPage: Int
    var rotate = false
    var fit = true
    var setup: PageSetup
    var error: String?

    init(document: PrintDocument, setup: PageSetup = .saved()) {
        self.document = document
        self.setup = setup
        lastPage = document.pageCount
    }

    func task(connection: PrinterPreferences) -> PrintTask {
        PrintTask(id: id, document: document, options: PrintOptions(
            host: connection.host, port: connection.port, copies: copies,
            firstPage: firstPage, lastPage: lastPage, rotate: rotate, fit: fit,
            interface: connection.interface, setup: setup))
    }
}

struct PrintTask {
    let id: UUID
    let document: PrintDocument
    let options: PrintOptions
}

enum PrintBatchEvent {
    case state(UUID, PrintJobState)
    case progress(UUID, String)
    case sent(UUID, Int)
    case failed(UUID, String)
    case printed(UUID)
    case notice(String)
}

final class CancellationToken {
    private let lock = NSLock()
    private var value = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func cancel() { lock.lock(); value = true; lock.unlock() }
}

enum PrintBatch {
    /// `flip` is called between the two passes of a manual duplex job with the front page count;
    /// it blocks until the user has turned the stack over and returns false to stop.
    static func run(_ tasks: [PrintTask], encoder: URL,
                    flip: (UUID, Int) -> Bool = { _, _ in true },
                    event: (PrintBatchEvent) -> Void) throws {
        // Validate every job's options before generating or sending the first job.
        for task in tasks { try task.options.validate(pageCount: task.document.pageCount) }
        for task in tasks {
            do {
                event(.state(task.id, .preparing))
                let prepared = try PrintEngine.prepare(task.document, options: task.options, encoder: encoder) {
                    event(.progress(task.id, $0))
                }
                defer { prepared.remove() }
                event(.state(task.id, .sending))
                try PrintEngine.send(prepared.dataURL, host: task.options.host, port: task.options.port,
                                     interface: task.options.interface) {
                    event(.progress(task.id, $0))
                }
                var sheets = prepared.sheets
                if let back = prepared.back {
                    event(.state(task.id, .flipping))
                    guard flip(task.id, prepared.sheets) else {
                        throw PrintFailure(message: "已取消背面，正面 \(prepared.sheets) 页已发送。")
                    }
                    event(.state(task.id, .sending))
                    try PrintEngine.send(back.dataURL, host: task.options.host, port: task.options.port,
                                         interface: task.options.interface) {
                        event(.progress(task.id, $0))
                    }
                    sheets += back.sheets
                }
                event(.sent(task.id, sheets))
            } catch {
                event(.failed(task.id, error.localizedDescription))
                throw error
            }
        }
    }

    /// Watches the printer's page counter until the sent sheets have come out, in sending order.
    /// Returns true when every job was confirmed. Other people's jobs on the same printer also
    /// advance the counter, so this confirms "this many pages left the printer", not ownership.
    @discardableResult
    static func confirm(baseline: Int, sent: [(id: UUID, sheets: Int)],
                        status: () -> PrinterStatusReport?, token: CancellationToken,
                        interval: TimeInterval = 2, timeout: TimeInterval? = nil,
                        wait: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
                        event: (PrintBatchEvent) -> Void) -> Bool {
        let total = sent.reduce(0) { $0 + $1.sheets }
        // DCP-1600 series print about 20 pages a minute; allow warm-up and generous slack.
        let limit = timeout ?? 45 + 8 * Double(total)
        var waited: TimeInterval = 0
        var confirmed = 0
        var lastNotice = ""
        while waited <= limit, !token.isCancelled {
            if let report = status() {
                if let count = report.pageCount {
                    let printed = count - baseline
                    var cumulative = 0
                    for (index, job) in sent.enumerated() {
                        cumulative += job.sheets
                        if index >= confirmed && printed >= cumulative {
                            event(.printed(job.id))
                            confirmed = index + 1
                        }
                    }
                    if confirmed == sent.count { return true }
                }
                let notice = report.severity == .error ? "打印机报告：\(report.summary)" : ""
                if notice != lastNotice {
                    if !notice.isEmpty { event(.notice(notice)) }
                    lastNotice = notice
                }
            }
            wait(interval)
            waited += interval
        }
        if !token.isCancelled {
            event(.notice("未能在预计时间内确认出纸（已确认 \(confirmed)/\(sent.count) 个文件），请到打印机旁检查。"))
        }
        return false
    }
}
