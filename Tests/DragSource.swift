// SPDX-License-Identifier: GPL-2.0-or-later
// Local UI fixture. It only drags the supplied synthetic test PDF.
import AppKit
import UniformTypeIdentifiers
import OSLog

final class SourceTile: NSView, NSDraggingSource, NSFilePromiseProviderDelegate {
    let file: URL
    let promise: Bool
    init(file: URL, promise: Bool, frame: NSRect) {
        self.file = file
        self.promise = promise
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.15).cgColor
        layer?.cornerRadius = 16
        let label = NSTextField(labelWithString: promise ? "拖动：延迟提供 PDF" : "拖动：本地 PDF 文件")
        label.font = .systemFont(ofSize: 17, weight: .semibold)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        setAccessibilityLabel(promise ? "文件承诺拖动测试" : "本地文件拖动测试")
    }
    required init?(coder: NSCoder) { nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDragged(with event: NSEvent) {
        Logger(subsystem: "org.brotherdropprint.drag-test-source", category: "fixture").notice("drag_started promise=\(self.promise, privacy: .public)")
        let writer: NSPasteboardWriting = promise ?
            NSFilePromiseProvider(fileType: UTType.pdf.identifier, delegate: self) : file as NSURL
        let item = NSDraggingItem(pasteboardWriter: writer)
        let icon = NSImage(systemSymbolName: "doc.richtext.fill", accessibilityDescription: "测试 PDF")!
        item.setDraggingFrame(NSRect(x: event.locationInWindow.x - frame.minX,
                                    y: event.locationInWindow.y - frame.minY,
                                    width: 40, height: 40), contents: icon)
        beginDraggingSession(with: [item], event: event, source: self)
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        Logger(subsystem: "org.brotherdropprint.drag-test-source", category: "fixture").notice("drag_ended operation=\(operation.rawValue, privacy: .public)")
    }
    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        "Promised-Calibration.pdf"
    }
    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider,
                             writePromiseTo url: URL, completionHandler: @escaping (Error?) -> Void) {
        do { try FileManager.default.copyItem(at: file, to: url); completionHandler(nil) }
        catch { completionHandler(error) }
    }
}

final class SourceApp: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let file = Bundle.main.url(forResource: "Calibration", withExtension: "pdf") else {
            NSApp.terminate(nil)
            return
        }
        let screen = NSScreen.main!.visibleFrame
        window = NSWindow(contentRect: screen,
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.setFrame(screen, display: false)
        window.title = "V1.1 Drag Test Source"
        window.isReleasedWhenClosed = false
        let height = window.contentView!.bounds.height
        let local = SourceTile(file: file, promise: false, frame: NSRect(x: 40, y: height - 150, width: 320, height: 100))
        let deferred = SourceTile(file: file, promise: true, frame: NSRect(x: 40, y: height - 290, width: 320, height: 100))
        window.contentView!.addSubview(local)
        window.contentView!.addSubview(deferred)
        let menu = NSMenu()
        let item = NSMenuItem()
        let actions = NSMenu()
        actions.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.submenu = actions
        menu.addItem(item)
        NSApp.mainMenu = menu
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

let application = NSApplication.shared
let delegate = SourceApp()
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()
