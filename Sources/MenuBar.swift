// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import QuartzCore
import UniformTypeIdentifiers

final class StatusDropView: NSView {
    var dropped: ((URL) -> Void)?
    var pressed: (() -> Void)?
    var contextMenu: (() -> Void)?
    var hovered: ((Bool) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Brother Drop Print")
        setAccessibilityHelp("拖入 PDF、PNG 或 JPEG 打开打印设置，或点按选择文件。")
    }
    required init?(coder: NSCoder) { nil }
    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event: NSEvent) { pressed?() }
    override func rightMouseDown(with event: NSEvent) { contextMenu?() }
    override func accessibilityPerformPress() -> Bool { pressed?(); return true }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 49 { pressed?() }
        else { super.keyDown(with: event) }
    }
    static func acceptedFile(from pasteboard: NSPasteboard) -> URL? {
        guard let objects = pasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]),
              objects.count == 1, let url = objects.first as? URL,
              ["pdf", "png", "jpg", "jpeg"].contains(url.pathExtension.lowercased()) else { return nil }
        return url
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard Self.acceptedFile(from: sender.draggingPasteboard) != nil else { return [] }
        hovered?(true)
        return .copy
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { hovered?(false) }
    override func draggingEnded(_ sender: NSDraggingInfo) { hovered?(false) }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        hovered?(false)
        guard let url = Self.acceptedFile(from: sender.draggingPasteboard) else { return false }
        dropped?(url)
        return true
    }
}

final class MenuBarApp: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var item: NSStatusItem!
    private var window: NSWindow!
    private var document: PrintDocument?
    private var busy = false
    private var temporaryDocuments: [URL] = []
    private let filename = NSTextField(wrappingLabelWithString: "拖入 PDF、PNG 或 JPEG")
    private let details = NSTextField(labelWithString: "菜单栏拖放 · 按 IP 直连 · 无需搜索设备")
    private let host = NSTextField()
    private let port = NSTextField(string: "9100")
    private let network = NSPopUpButton()
    private let copies = NSTextField(string: "1")
    private let firstPage = NSTextField(string: "1")
    private let lastPage = NSTextField(string: "1")
    private let rotate = NSButton(checkboxWithTitle: "旋转 90°", target: nil, action: nil)
    private let fit = NSButton(checkboxWithTitle: "适应 A4 可打印区域", target: nil, action: nil)
    private let status = NSTextField(wrappingLabelWithString: "首次使用请先打印测试页，确认方向、比例和灰阶。")
    private let progress = NSProgressIndicator()
    private var printButton: NSButton!
    private var chooseButton: NSButton!
    private var testButton: NSButton!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let applicationMenu = NSMenu()
        let applicationMenuItem = NSMenuItem()
        let applicationSubmenu = NSMenu()
        applicationSubmenu.addItem(withTitle: "退出 Brother Drop Print",
                                   action: #selector(quitApp), keyEquivalent: "q").target = self
        applicationMenuItem.submenu = applicationSubmenu
        applicationMenu.addItem(applicationMenuItem)
        NSApp.mainMenu = applicationMenu
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = item.button else { return }
        button.image = NSImage(systemSymbolName: "printer.fill", accessibilityDescription: "Brother Drop Print")
        button.toolTip = "拖入 PDF 或图片进行打印；右键打开菜单"
        button.wantsLayer = true
        let drop = StatusDropView(frame: button.bounds)
        drop.autoresizingMask = [.width, .height]
        drop.dropped = { [weak self] url in self?.load(url) }
        drop.pressed = { [weak self] in self?.showWindow() }
        drop.contextMenu = { [weak self] in self?.showMenu() }
        drop.hovered = { [weak self] active in self?.animate(active) }
        button.addSubview(drop)
        host.stringValue = UserDefaults.standard.string(forKey: "printerHost") ?? ""
        host.placeholderString = "例如：192.0.2.10"
        let savedPort = UserDefaults.standard.integer(forKey: "printerPort")
        if savedPort > 0 { port.stringValue = String(savedPort) }
        network.addItem(withTitle: "自动（系统路由）")
        network.lastItem?.representedObject = ""
        for adapter in PrintEngine.networkAdapters() {
            network.addItem(withTitle: adapter.label)
            network.lastItem?.representedObject = adapter.name
        }
        let savedInterface = UserDefaults.standard.string(forKey: "printerInterface") ?? ""
        if let selected = network.itemArray.first(where: { $0.representedObject as? String == savedInterface }) {
            network.select(selected)
        } else if !savedInterface.isEmpty {
            network.addItem(withTitle: "\(savedInterface)（已断开）")
            network.lastItem?.representedObject = savedInterface
            network.select(network.lastItem)
        }
        network.setAccessibilityLabel("发送网卡")
        network.widthAnchor.constraint(equalToConstant: 280).isActive = true
        fit.state = .on
        buildWindow()
        showWindow()
    }

    private func field(_ value: NSTextField, label: String, width: CGFloat = 70) -> NSTextField {
        value.setAccessibilityLabel(label)
        value.widthAnchor.constraint(equalToConstant: width).isActive = true
        return value
    }

    private func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 495),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Brother Drop Print"
        window.isReleasedWhenClosed = false
        window.delegate = self
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 12
        root.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 22),
            root.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -22),
            root.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 20)
        ])
        let title = NSTextField(labelWithString: "拖进来，选好，再打印。")
        title.font = .systemFont(ofSize: 21, weight: .semibold)
        root.addArrangedSubview(title)
        filename.font = .systemFont(ofSize: 14, weight: .medium)
        filename.maximumNumberOfLines = 2
        filename.preferredMaxLayoutWidth = 490
        root.addArrangedSubview(filename)
        details.font = .systemFont(ofSize: 11)
        details.textColor = .secondaryLabelColor
        root.addArrangedSubview(details)

        let pages = NSStackView(views: [
            field(firstPage, label: "开始页码"), NSTextField(labelWithString: "至"),
            field(lastPage, label: "结束页码")
        ])
        pages.spacing = 10
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "打印机 IP"), field(host, label: "打印机或转发路由器 IP", width: 280)],
            [NSTextField(labelWithString: "打印端口"), field(port, label: "打印端口")],
            [NSTextField(labelWithString: "发送网卡"), network],
            [NSTextField(labelWithString: "份数"), field(copies, label: "打印份数")],
            [NSTextField(labelWithString: "页码"), pages]
        ])
        grid.rowSpacing = 10
        grid.columnSpacing = 16
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .leading
        root.addArrangedSubview(grid)
        let options = NSStackView(views: [fit, rotate])
        options.spacing = 20
        root.addArrangedSubview(options)
        let paper = NSTextField(labelWithString: "首版：A4 · 600 dpi · 黑白 · 单面")
        paper.font = .systemFont(ofSize: 11)
        paper.textColor = .secondaryLabelColor
        root.addArrangedSubview(paper)
        status.maximumNumberOfLines = 3
        status.preferredMaxLayoutWidth = 485
        status.font = .systemFont(ofSize: 12)
        root.addArrangedSubview(status)
        progress.style = .bar
        progress.isIndeterminate = true
        progress.isHidden = true
        progress.widthAnchor.constraint(equalToConstant: 485).isActive = true
        root.addArrangedSubview(progress)
        chooseButton = NSButton(title: "选择文件…", target: self, action: #selector(chooseFile))
        testButton = NSButton(title: "准备测试页", target: self, action: #selector(testPage))
        printButton = NSButton(title: "打印", target: self, action: #selector(printDocument))
        printButton.bezelStyle = .rounded
        printButton.keyEquivalent = "\r"
        printButton.isEnabled = false
        let actions = NSStackView(views: [chooseButton, testButton, printButton])
        actions.spacing = 12
        root.addArrangedSubview(actions)
    }

    @objc private func chooseFile() {
        guard !busy else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf, .png, .jpeg]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.beginSheetModal(for: window) { [weak self] response in
            if response == .OK, let url = panel.url { self?.load(url) }
        }
    }

    private func load(_ url: URL) {
        guard !busy else { NSSound.beep(); return }
        showWindow()
        do {
            let loaded = try PrintDocument(url: url)
            document = loaded
            filename.stringValue = url.lastPathComponent
            details.stringValue = "\(loaded.pageCount) 页 · 本机转换，仅发送到指定打印机"
            firstPage.stringValue = "1"
            lastPage.stringValue = String(loaded.pageCount)
            fit.isEnabled = loaded.isPDF
            if !loaded.isPDF { fit.state = .on }
            status.stringValue = "请核对打印机 IP、端口及页码，然后点“打印”。"
            printButton.isEnabled = true
        } catch {
            document = nil
            filename.stringValue = url.lastPathComponent
            printButton.isEnabled = false
            status.stringValue = error.localizedDescription
        }
    }

    @objc private func testPage() {
        guard !busy else { return }
        do {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("BrotherDropPrint-test-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                   attributes: [.posixPermissions: 0o700])
            let url = directory.appendingPathComponent("打印校准页.pdf")
            try PrintEngine.calibrationPDF(to: url)
            temporaryDocuments.append(directory)
            load(url)
            fit.state = .off
            status.stringValue = "测试页已准备，尚未发送。点“打印”后检查边框、方向和灰阶是否完整。"
        } catch { status.stringValue = error.localizedDescription }
    }

    @objc private func printDocument() {
        guard !busy, let document = document else { return }
        let options = PrintOptions(
            host: host.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            port: Int(port.stringValue) ?? 0, copies: Int(copies.stringValue) ?? 0,
            firstPage: Int(firstPage.stringValue) ?? 0, lastPage: Int(lastPage.stringValue) ?? 0,
            rotate: rotate.state == .on, fit: fit.state == .on,
            interface: network.selectedItem?.representedObject as? String ?? "")
        do { try options.validate(pageCount: document.pageCount) }
        catch { status.stringValue = error.localizedDescription; return }
        guard let encoder = Bundle.main.url(forResource: "brother-encoder", withExtension: nil) else {
            status.stringValue = "找不到编码器，请重新构建应用。"
            return
        }
        UserDefaults.standard.set(options.host, forKey: "printerHost")
        UserDefaults.standard.set(options.port, forKey: "printerPort")
        UserDefaults.standard.set(options.interface, forKey: "printerInterface")
        setBusy(true)
        let update: (String) -> Void = { [weak self] text in
            DispatchQueue.main.async { self?.status.stringValue = text }
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let prepared = try PrintEngine.prepare(document, options: options, encoder: encoder, progress: update)
                defer { prepared.remove() }
                update("正在连接打印机…")
                try PrintEngine.send(prepared.dataURL, host: options.host, port: options.port,
                                     interface: options.interface, progress: update)
                DispatchQueue.main.async {
                    self?.status.stringValue = "已发送 \(prepared.sheets) 页数据。请确认实际出纸；发送完成不等于打印机已完成打印。"
                    self?.setBusy(false)
                }
            } catch {
                DispatchQueue.main.async {
                    self?.status.stringValue = error.localizedDescription
                    self?.setBusy(false)
                }
            }
        }
    }

    private func setBusy(_ value: Bool) {
        busy = value
        for view in [host, port, copies, firstPage, lastPage] { view.isEnabled = !value }
        network.isEnabled = !value
        for button in [chooseButton, testButton, printButton, rotate] { button?.isEnabled = !value }
        fit.isEnabled = !value && document?.isPDF == true
        progress.isHidden = !value
        if value { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }
        animate(value)
    }

    private func animate(_ active: Bool) {
        guard let button = item.button else { return }
        button.contentTintColor = active ? .controlAccentColor : nil
        button.layer?.removeAnimation(forKey: "dropPulse")
        if active && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let animation = CABasicAnimation(keyPath: "opacity")
            animation.fromValue = 1
            animation.toValue = 0.4
            animation.duration = 0.45
            animation.autoreverses = true
            animation.repeatCount = .infinity
            button.layer?.add(animation, forKey: "dropPulse")
        }
    }

    @objc private func showWindow() {
        guard window != nil else { return }
        if let button = item.button, let bar = button.window, let screen = bar.screen {
            let rect = bar.convertToScreen(button.convert(button.bounds, to: nil))
            let frame = screen.visibleFrame
            let x = min(max(frame.minX + 12, rect.midX - window.frame.width / 2),
                        frame.maxX - window.frame.width - 12)
            window.setFrameTopLeftPoint(NSPoint(x: x, y: frame.maxY - 10))
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func showMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "打开打印设置", action: #selector(showWindow), keyEquivalent: "").target = self
        menu.addItem(withTitle: "准备测试页", action: #selector(testPage), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "GitHub 源码", action: #selector(openSource), keyEquivalent: "").target = self
        let quit = menu.addItem(withTitle: "退出", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        quit.isEnabled = !busy
        if let event = NSApp.currentEvent, let button = item.button {
            NSMenu.popUpContextMenu(menu, with: event, for: button)
        }
    }
    @objc private func openSource() {
        NSWorkspace.shared.open(URL(string: "https://github.com/lomai4n/brother-drop-print")!)
    }
    @objc private func quitApp() { if !busy { NSApp.terminate(nil) } }
    func applicationWillTerminate(_ notification: Notification) {
        for url in temporaryDocuments { try? FileManager.default.removeItem(at: url) }
    }
}
