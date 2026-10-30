// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import QuartzCore
import OSLog

enum DragTransition: Equatable { case none, began, ended }

struct FileDragState {
    private(set) var isFileDrag = false
    private var lastChangeCount: Int

    init(changeCount: Int) { lastChangeCount = changeCount }

    mutating func beginGesture() { isFileDrag = false }

    mutating func observe(pressed: Bool, changeCount: Int, hasFileType: Bool) -> DragTransition {
        if !pressed {
            let wasDragging = isFileDrag
            isFileDrag = false
            lastChangeCount = changeCount
            return wasDragging ? .ended : .none
        }
        guard changeCount != lastChangeCount else { return .none }
        lastChangeCount = changeCount
        guard hasFileType, !isFileDrag else { return .none }
        isFileDrag = true
        return .began
    }
}

final class GlobalFileDragMonitor {
    var onBegan: (() -> Void)?
    var onEnded: (() -> Void)?
    var onContinue: (() -> Void)?
    private var global: Any?
    private var local: Any?
    private var timer: Timer?
    private var state = FileDragState(changeCount: NSPasteboard(name: .drag).changeCount)
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "org.brotherdropprint.app",
                                category: "drag")

    func start() {
        guard timer == nil else { return }
        state = FileDragState(changeCount: NSPasteboard(name: .drag).changeCount)
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        global = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] in self?.event($0) }
        local = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.event(event)
            return event
        }
        let poll = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            self?.sample(pressed: NSEvent.pressedMouseButtons & 1 != 0)
        }
        poll.tolerance = 0.05
        RunLoop.main.add(poll, forMode: .common)
        timer = poll
    }

    func stop() {
        if let global = global { NSEvent.removeMonitor(global) }
        if let local = local { NSEvent.removeMonitor(local) }
        global = nil
        local = nil
        timer?.invalidate()
        timer = nil
        onEnded?()
    }

    private func event(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            if state.isFileDrag { onEnded?() }
            state.beginGesture()
        case .leftMouseDragged: sample(pressed: true)
        case .leftMouseUp: sample(pressed: false)
        default: break
        }
    }

    private func sample(pressed: Bool) {
        let board = NSPasteboard(name: .drag)
        switch state.observe(pressed: pressed, changeCount: board.changeCount,
                             hasFileType: FileDropView.hasFileRepresentation(board)) {
        case .began:
            logger.notice("external_file_drag_began")
            onBegan?()
        case .ended:
            logger.notice("file_drag_ended")
            onEnded?()
        case .none: break
        }
        if state.isFileDrag { onContinue?() }
    }
}

final class FileDropView: NSView {
    var onFiles: (([URL], URL?) -> Void)?
    var onReceiving: ((URL) -> Void)?
    var onError: ((String) -> Void)?
    var onHover: ((Bool) -> Void)?
    var onAccepted: (() -> Void)?
    var onClick: (() -> Void)?
    var onContextMenu: (() -> Void)?
    var onRejected: ((String) -> Void)?
    var drawsTarget = true { didSet { style() } }
    var rejectsUnsupported = false
    private var highlighted = false
    private var rejectedSequence: Int?
    private let receiveQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 2
        queue.name = "BrotherDropPrint.FilePromises"
        return queue
    }()
    private static let legacyFiles = NSPasteboard.PasteboardType("NSFilenamesPboardType")
    private static var promiseTypes: [NSPasteboard.PasteboardType] {
        NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL, Self.legacyFiles] + Self.promiseTypes)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("文件拖放区")
        setAccessibilityHelp("拖入 PDF、PNG 或 JPEG，打开文档预览和打印操作。")
        style()
    }
    required init?(coder: NSCoder) { nil }
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func rightMouseDown(with event: NSEvent) { onContextMenu?() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); style() }

    static func hasFileRepresentation(_ pasteboard: NSPasteboard) -> Bool {
        let types = Set(pasteboard.types ?? [])
        return types.contains(.fileURL) || types.contains(legacyFiles) ||
            !types.isDisjoint(with: promiseTypes)
    }

    static func fileURLs(_ pasteboard: NSPasteboard) -> [URL] {
        if let objects = pasteboard.readObjects(forClasses: [NSURL.self],
                                                options: [.urlReadingFileURLsOnly: true]) {
            let urls = objects.compactMap { $0 as? URL }.filter(\.isFileURL)
            if !urls.isEmpty { return urls }
        }
        return (pasteboard.propertyList(forType: legacyFiles) as? [String] ?? [])
            .filter { $0.hasPrefix("/") }.map { URL(fileURLWithPath: $0) }
    }

    /// Only plain file URLs reveal their type while dragging; promised files are checked after receipt.
    static func unsupportedReason(_ pasteboard: NSPasteboard) -> String? {
        let urls = fileURLs(pasteboard)
        guard !urls.isEmpty,
              !urls.contains(where: { ["pdf", "png", "jpg", "jpeg"].contains($0.pathExtension.lowercased()) })
        else { return nil }
        let ext = urls[0].pathExtension.isEmpty ? "此类文件" : ".\(urls[0].pathExtension)"
        return "暂不支持 \(ext)，请先导出为 PDF"
    }

    static func validReceivedURL(_ url: URL, directory: URL) -> Bool {
        url.isFileURL && url.resolvingSymlinksInPath().standardizedFileURL.path
            .hasPrefix(directory.resolvingSymlinksInPath().standardizedFileURL.path + "/")
    }

    private func style() {
        layer?.cornerRadius = 16
        layer?.borderWidth = drawsTarget ? (highlighted ? 2 : 1) : 0
        layer?.borderColor = (highlighted ? NSColor.controlAccentColor :
                                 NSColor.separatorColor).cgColor
        layer?.backgroundColor = drawsTarget ?
            (highlighted ? NSColor.controlAccentColor.withAlphaComponent(0.14) :
                NSColor.controlBackgroundColor.withAlphaComponent(0.45)).cgColor : NSColor.clear.cgColor
    }
    private func hover(_ value: Bool) {
        highlighted = value
        style()
        onHover?(value)
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        rejectedSequence = nil
        var accepted = Self.hasFileRepresentation(sender.draggingPasteboard)
        if accepted, rejectsUnsupported, let reason = Self.unsupportedReason(sender.draggingPasteboard) {
            accepted = false
            rejectedSequence = sender.draggingSequenceNumber
            onRejected?(reason)
        }
        hover(accepted)
        return accepted ? .copy : []
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        rejectedSequence != sender.draggingSequenceNumber &&
            Self.hasFileRepresentation(sender.draggingPasteboard) ? .copy : []
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { hover(false) }
    override func draggingEnded(_ sender: NSDraggingInfo) { hover(false) }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        rejectedSequence != sender.draggingSequenceNumber && Self.hasFileRepresentation(sender.draggingPasteboard)
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        hover(false)
        let promises = sender.draggingPasteboard.readObjects(
            forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver] ?? []
        if promises.isEmpty {
            let urls = Self.fileURLs(sender.draggingPasteboard)
            guard !urls.isEmpty else { return false }
            onAccepted?()
            onFiles?(urls, nil)
            return true
        }
        do {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("BrotherDropPrint-Received-\(UUID())", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                   attributes: [.posixPermissions: 0o700])
            onAccepted?()
            onReceiving?(directory)
            for promise in promises {
                promise.receivePromisedFiles(atDestination: directory, options: [:],
                                             operationQueue: receiveQueue) { [weak self] url, error in
                    DispatchQueue.main.async {
                        if let error = error {
                            self?.onError?("接收文件失败：\(error.localizedDescription)")
                        } else if Self.validReceivedURL(url, directory: directory) {
                            self?.onFiles?([url], directory)
                        } else {
                            self?.onError?("文件提供程序返回了无效路径，未打开文件。")
                        }
                    }
                }
            }
            return true
        } catch {
            onError?(error.localizedDescription)
            return false
        }
    }
}
