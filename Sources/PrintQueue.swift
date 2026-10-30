// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

enum PrintJobState: String {
    case waiting = "待处理"
    case preparing = "转换中"
    case sending = "发送中"
    case sent = "已发送"
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
    var error: String?

    init(document: PrintDocument) {
        self.document = document
        lastPage = document.pageCount
    }

    func task(connection: PrinterPreferences) -> PrintTask {
        PrintTask(id: id, document: document, options: PrintOptions(
            host: connection.host, port: connection.port, copies: copies,
            firstPage: firstPage, lastPage: lastPage, rotate: rotate, fit: fit,
            interface: connection.interface))
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
}

enum PrintBatch {
    static func run(_ tasks: [PrintTask], encoder: URL,
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
                event(.sent(task.id, prepared.sheets))
            } catch {
                event(.failed(task.id, error.localizedDescription))
                throw error
            }
        }
    }
}
