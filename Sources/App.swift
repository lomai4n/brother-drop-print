// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import PDFKit
import ImageIO
import QuartzCore
import OSLog

final class StandalonePrintApp: NSObject, NSApplicationDelegate, NSWindowDelegate,
                                 NSTableViewDataSource, NSTableViewDelegate {
    private var window: NSWindow!
    private var item: NSStatusItem!
    private var splitController: NSSplitViewController!
    private var jobs: [QueuedPrintFile] = []
    private var selectedID: UUID?
    private var busy = false
    private var ownedDirectories = Set<URL>()
    private var openingURLs: [URL] = []
    private var fileChooser: NSOpenPanel?
    private let settings = SettingsController()
    private let dragMonitor = GlobalFileDragMonitor()
    private let flash = FlashDropController()
    private let dropArea = FileDropView()
    private let table = NSTableView()
    private let pdf = PDFView()
    private let image = NSImageView()
    private let emptyPreview = NSTextField(labelWithString: "选中文件后在这里预览")
    private let listTitle = NSTextField(labelWithString: "文件列表")
    private let connection = NSTextField(labelWithString: "")
    private let filename = NSTextField(labelWithString: "尚未选择文件")
    private let status = NSTextField(wrappingLabelWithString: "拖入 PDF 或图片，选择参数后打印。")
    private let progress = NSProgressIndicator()
    private let copies = NSTextField(string: "1")
    private let firstPage = NSTextField(string: "1")
    private let lastPage = NSTextField(string: "1")
    private let rotate = NSButton(checkboxWithTitle: "输出旋转 90°", target: nil, action: nil)
    private let fit = NSButton(checkboxWithTitle: "适应纸张可打印区域", target: nil, action: nil)
    private let paperPopup = NSPopUpButton()
    private let qualityPopup = NSPopUpButton()
    private let mediaPopup = NSPopUpButton()
    private let densityPopup = NSPopUpButton()
    private let setupSummary = NSTextField(labelWithString: "")
    private var selectedButton: NSButton!
    private var allButton: NSButton!
    private var removeButton: NSButton!
    private var suppressSelection = false
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "org.brotherdropprint.app",
                                category: "drag")

    private var selectedJob: QueuedPrintFile? { jobs.first { $0.id == selectedID } }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        buildWindow()
        buildStatusItem()
        settings.canSave = { [weak self] in self?.busy == false }
        settings.onSaved = { [weak self] in
            self?.refreshPreferences()
            self?.flash.reloadResult()
        }
        dragMonitor.onBegan = { [weak self] in self?.flash.beginDrag() }
        dragMonitor.onContinue = { [weak self] in self?.flash.dragMoved() }
        dragMonitor.onEnded = { [weak self] in self?.flash.endDrag() }
        wireFlash()
        wireDrop(dropArea)
        refreshPreferences()
        if openingURLs.isEmpty { showMain() }
        else {
            accept(openingURLs)
            openingURLs.removeAll()
        }
    }

    private func buildMenu() {
        let bar = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于 Brother Drop Print", action: #selector(about), keyEquivalent: "").target = self
        appMenu.addItem(withTitle: "设置…", action: #selector(showSettings), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 Brother Drop Print", action: #selector(quit), keyEquivalent: "q").target = self
        appItem.submenu = appMenu
        bar.addItem(appItem)
        let fileItem = NSMenuItem()
        fileItem.title = "文件"
        let files = NSMenu(title: "文件")
        files.addItem(withTitle: "添加文件…", action: #selector(chooseFiles), keyEquivalent: "o").target = self
        files.addItem(withTitle: "准备校准页", action: #selector(testPage), keyEquivalent: "").target = self
        files.addItem(withTitle: "显示打印工作台", action: #selector(showMain), keyEquivalent: "1").target = self
        fileItem.submenu = files
        bar.addItem(fileItem)
        NSApp.mainMenu = bar
    }

    private func buildStatusItem() {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = item.button else { return }
        button.image = NSImage(systemSymbolName: "printer.fill", accessibilityDescription: "Brother Drop Print")
        button.toolTip = "Brother Drop Print：打开工作台或拖入文件"
        button.wantsLayer = true
        let drop = FileDropView(frame: button.bounds)
        drop.drawsTarget = false
        drop.autoresizingMask = [.width, .height]
        drop.onClick = { [weak self] in self?.showMain() }
        drop.onContextMenu = { [weak self] in self?.statusMenu() }
        drop.onHover = { [weak self] in self?.animateIcon($0) }
        wireDrop(drop)
        button.addSubview(drop)
    }

    private func wireFlash() {
        flash.anchor = { [weak self] in self?.item?.button?.window?.frame }
        flash.printerSummary = {
            let preferences = PrinterPreferences()
            return preferences.host.isEmpty ? "未设置" : "\(preferences.host):\(preferences.port)"
        }
        flash.onPrint = { [weak self] files in self?.printFromFlash(files) }
        flash.onPreview = { [weak self] in
            guard let self = self else { return }
            if let file = self.flash.files.first, let index = self.jobs.firstIndex(where: { $0.id == file.id }) {
                self.table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
                self.select(file)
            }
            self.flash.hide()
            self.showMain()
        }
        flash.onSettings = { [weak self] in self?.showSettings() }
        flash.onAdd = { [weak self] in self?.chooseFilesForFlash() }
        flash.onClear = { [weak self] files in self?.remove(files) }
        let view = flash.dropView
        view.onAccepted = { [weak self] in
            self?.fileChooser?.cancel(nil)
            self?.flash.showResult()
            self?.logger.notice("file_drop_accepted target=flash")
        }
        view.onFiles = { [weak self] urls, directory in
            if let directory = directory { self?.ownedDirectories.insert(directory) }
            self?.accept(urls, intoFlash: true)
        }
        view.onReceiving = { [weak self] directory in
            self?.ownedDirectories.insert(directory)
            self?.flash.setStatus("正在接收拖入的文件…")
        }
        view.onError = { [weak self] message in self?.flash.setStatus(message) }
    }

    private func wireDrop(_ view: FileDropView) {
        view.onAccepted = { [weak self] in
            self?.fileChooser?.cancel(nil)
            self?.flash.cancelDrag()
            self?.showMain()
            self?.logger.notice("file_drop_accepted")
        }
        view.onFiles = { [weak self] urls, directory in
            if let directory = directory { self?.ownedDirectories.insert(directory) }
            self?.accept(urls)
        }
        view.onReceiving = { [weak self] directory in
            self?.ownedDirectories.insert(directory)
            self?.status.stringValue = "正在接收拖入的文件…"
        }
        view.onError = { [weak self] message in
            if NSEvent.pressedMouseButtons & 1 == 0 { self?.showMain() }
            self?.status.stringValue = message
        }
    }

    private func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 720),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "Brother Drop Print"
        window.minSize = NSSize(width: 880, height: 660)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        let canvas = FileDropView()
        canvas.drawsTarget = false
        wireDrop(canvas)
        window.contentView = canvas
        let root = NSStackView()
        root.orientation = .vertical
        root.distribution = .fill
        root.alignment = .leading
        root.spacing = 14
        root.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 20),
            root.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -20),
            root.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 18),
            root.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -18)
        ])
        let title = NSTextField(labelWithString: "打印工作台")
        title.font = .systemFont(ofSize: 24, weight: .semibold)
        connection.font = .systemFont(ofSize: 11)
        connection.textColor = .secondaryLabelColor
        let titles = NSStackView(views: [title, connection])
        titles.orientation = .vertical
        titles.alignment = .leading
        titles.spacing = 4
        let add = NSButton(title: "添加文件…", target: self, action: #selector(chooseFiles))
        let preferences = NSButton(title: "设置…", target: self, action: #selector(showSettings))
        preferences.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        preferences.imagePosition = .imageLeading
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let heading = NSStackView(views: [titles, spacer, add, preferences])
        heading.spacing = 12
        root.addArrangedSubview(heading)
        heading.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        heading.heightAnchor.constraint(equalToConstant: 52).isActive = true

        dropArea.heightAnchor.constraint(equalToConstant: 74).isActive = true
        dropArea.onClick = { [weak self] in self?.chooseFiles() }
        let dropIcon = NSImageView()
        dropIcon.image = NSImage(systemSymbolName: "tray.and.arrow.down.fill", accessibilityDescription: nil)
        dropIcon.contentTintColor = .controlAccentColor
        dropIcon.widthAnchor.constraint(equalToConstant: 28).isActive = true
        dropIcon.heightAnchor.constraint(equalToConstant: 28).isActive = true
        let dropTitle = NSTextField(labelWithString: "拖入文件，接着选择怎么打印")
        dropTitle.font = .systemFont(ofSize: 15, weight: .semibold)
        let help = NSTextField(labelWithString: "PDF、PNG、JPEG · 可多选 · 也可拖到自动出现的接收浮窗")
        help.textColor = .secondaryLabelColor
        help.font = .systemFont(ofSize: 11)
        let dropText = NSStackView(views: [dropTitle, help])
        dropText.orientation = .vertical
        dropText.alignment = .leading
        dropText.spacing = 5
        let dropContents = NSStackView(views: [dropIcon, dropText])
        dropContents.spacing = 14
        dropContents.translatesAutoresizingMaskIntoConstraints = false
        dropArea.addSubview(dropContents)
        NSLayoutConstraint.activate([
            dropContents.centerXAnchor.constraint(equalTo: dropArea.centerXAnchor),
            dropContents.centerYAnchor.constraint(equalTo: dropArea.centerYAnchor)
        ])
        root.addArrangedSubview(dropArea)
        dropArea.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true

        splitController = NSSplitViewController()
        splitController.splitView.isVertical = true
        splitController.splitView.dividerStyle = .thin
        let sidebar = NSViewController()
        sidebar.view = makeSidebar()
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 220
        sidebarItem.maximumThickness = 340
        sidebarItem.canCollapse = false
        let preview = NSViewController()
        preview.view = makePreview()
        splitController.addSplitViewItem(sidebarItem)
        splitController.addSplitViewItem(NSSplitViewItem(viewController: preview))
        let split = splitController.view
        root.addArrangedSubview(split)
        split.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        split.heightAnchor.constraint(greaterThanOrEqualToConstant: 270).isActive = true
        split.setContentHuggingPriority(.defaultLow, for: .vertical)

        let options = NSStackView()
        options.orientation = .horizontal
        options.spacing = 10
        func field(_ value: NSTextField, label: String) -> NSTextField {
            value.setAccessibilityLabel(label)
            value.widthAnchor.constraint(equalToConstant: 54).isActive = true
            return value
        }
        for view in [NSTextField(labelWithString: "份数"), field(copies, label: "打印份数"),
                     NSTextField(labelWithString: "页码"), field(firstPage, label: "开始页码"),
                     NSTextField(labelWithString: "至"), field(lastPage, label: "结束页码"), fit, rotate] {
            options.addArrangedSubview(view)
        }
        root.addArrangedSubview(options)
        options.heightAnchor.constraint(equalToConstant: 26).isActive = true
        paperPopup.addItems(withTitles: PaperSize.allCases.map(\.label))
        qualityPopup.addItems(withTitles: PrintQuality.allCases.map(\.label))
        mediaPopup.addItems(withTitles: MediaType.allCases.map(\.label))
        densityPopup.addItems(withTitles: PageSetup.densityRange.map { $0 == 0 ? "浓度 0" : String(format: "浓度 %+d", $0) })
        for (popup, label) in [(paperPopup, "纸张尺寸"), (qualityPopup, "打印质量"),
                               (mediaPopup, "纸张类型"), (densityPopup, "碳粉浓度")] {
            popup.setAccessibilityLabel(label)
            popup.target = self
            popup.action = #selector(setupChanged)
        }
        let setupRow = NSStackView(views: [NSTextField(labelWithString: "纸张"), paperPopup, mediaPopup,
                                           NSTextField(labelWithString: "质量"), qualityPopup, densityPopup])
        setupRow.spacing = 10
        root.addArrangedSubview(setupRow)
        setupRow.heightAnchor.constraint(equalToConstant: 26).isActive = true
        status.font = .systemFont(ofSize: 12)
        status.maximumNumberOfLines = 2
        status.preferredMaxLayoutWidth = 980
        root.addArrangedSubview(status)
        status.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        status.heightAnchor.constraint(equalToConstant: 34).isActive = true
        progress.style = .bar
        progress.isIndeterminate = true
        progress.isHidden = true
        root.addArrangedSubview(progress)
        progress.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        selectedButton = NSButton(title: "打印所选文件", target: self, action: #selector(printSelected))
        selectedButton.keyEquivalent = "\r"
        allButton = NSButton(title: "打印全部待处理", target: self, action: #selector(printWaiting))
        let test = NSButton(title: "准备校准页", target: self, action: #selector(testPage))
        setupSummary.textColor = .secondaryLabelColor
        setupSummary.font = .systemFont(ofSize: 11)
        let actions = NSStackView(views: [test, setupSummary, NSView(), allButton, selectedButton])
        actions.spacing = 12
        root.addArrangedSubview(actions)
        actions.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        actions.heightAnchor.constraint(equalToConstant: 30).isActive = true
        show(PageSetup.saved())
        updateControls()
    }

    private func makeSidebar() -> NSView {
        let root = NSStackView()
        root.orientation = .vertical
        root.distribution = .fill
        root.alignment = .leading
        root.spacing = 10
        listTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        root.addArrangedSubview(listTitle)
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("file")))
        table.headerView = nil
        table.rowHeight = 56
        table.delegate = self
        table.dataSource = self
        table.allowsEmptySelection = true
        table.style = .plain
        table.setAccessibilityLabel("待打印文件列表")
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        root.addArrangedSubview(scroll)
        scroll.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        removeButton = NSButton(title: "从列表移除", target: self, action: #selector(removeSelected))
        root.addArrangedSubview(removeButton)
        return root
    }

    private func makePreview() -> NSView {
        let container = NSStackView()
        container.orientation = .vertical
        container.distribution = .fill
        container.alignment = .leading
        container.spacing = 7
        filename.font = .systemFont(ofSize: 14, weight: .semibold)
        filename.lineBreakMode = .byTruncatingMiddle
        container.addArrangedSubview(filename)
        let note = NSTextField(labelWithString: "文档原文预览 · 打印输出按下方设置转换")
        note.textColor = .secondaryLabelColor
        note.font = .systemFont(ofSize: 10)
        container.addArrangedSubview(note)
        let root = NSView()
        root.wantsLayer = true
        root.layer?.cornerRadius = 12
        root.layer?.masksToBounds = true
        pdf.autoScales = true
        pdf.displayMode = .singlePageContinuous
        pdf.backgroundColor = .controlBackgroundColor
        pdf.unregisterDraggedTypes()
        image.imageScaling = .scaleProportionallyUpOrDown
        image.setAccessibilityLabel("图片文档预览")
        emptyPreview.textColor = .secondaryLabelColor
        for view in [pdf, image] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
                view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                view.topAnchor.constraint(equalTo: root.topAnchor),
                view.bottomAnchor.constraint(equalTo: root.bottomAnchor)
            ])
            view.isHidden = true
        }
        emptyPreview.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(emptyPreview)
        NSLayoutConstraint.activate([
            emptyPreview.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            emptyPreview.centerYAnchor.constraint(equalTo: root.centerYAnchor)
        ])
        container.addArrangedSubview(root)
        root.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true
        root.heightAnchor.constraint(greaterThanOrEqualToConstant: 210).isActive = true
        root.setContentHuggingPriority(.defaultLow, for: .vertical)
        return container
    }

    private func refreshPreferences() {
        let preferences = PrinterPreferences()
        if preferences.automaticDropWindow { dragMonitor.start() }
        else { dragMonitor.stop(); flash.cancelDrag() }
        let route = preferences.interface.isEmpty ? "系统路由" : "绑定 \(preferences.interface)"
        connection.stringValue = preferences.host.isEmpty ? "请先在设置中连接打印机" : "打印机已配置 · \(route)"
        updateControls()
    }

    private func accept(_ urls: [URL], intoFlash: Bool = false) {
        // A delayed file-promise receipt must not interrupt a newer drag gesture.
        if !intoFlash && NSEvent.pressedMouseButtons & 1 == 0 { showMain() }
        if !busy { try? storeForm() }
        var imported: [QueuedPrintFile] = []
        var errors: [String] = []
        var existing: QueuedPrintFile?
        for url in urls {
            if let duplicate = jobs.first(where: { $0.document.url.standardizedFileURL == url.standardizedFileURL }) {
                existing = duplicate
                continue
            }
            do {
                let file = QueuedPrintFile(document: try PrintDocument(url: url))
                jobs.append(file)
                imported.append(file)
            } catch { errors.append("\(url.lastPathComponent)：\(error.localizedDescription)") }
        }
        reloadList()
        if let file = imported.first ?? existing, let index = jobs.firstIndex(where: { $0.id == file.id }) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            select(file)
        } else if !errors.isEmpty && !busy {
            table.deselectAll(nil)
            select(nil)
        }
        if intoFlash {
            flash.add(imported + (existing.map { [$0] } ?? []))
            if !errors.isEmpty { flash.setStatus(errors.prefix(2).joined(separator: "\n")) }
        }
        if !errors.isEmpty { status.stringValue = errors.prefix(2).joined(separator: "\n") }
        else if !imported.isEmpty {
            status.stringValue = busy ? "已加入 \(imported.count) 个文件，将留在列表中等待下一批打印。" :
                "已添加 \(imported.count) 个文件。可预览、调整参数，再打印所选或全部待处理文件。"
        } else if existing != nil { status.stringValue = "文件已在列表中，可选中后再次打印。" }
        logger.notice("documents_received count=\(urls.count, privacy: .public)")
        updateControls()
    }

    private func select(_ file: QueuedPrintFile?) {
        selectedID = file?.id
        pdf.document = nil
        image.image = nil
        pdf.isHidden = true
        image.isHidden = true
        emptyPreview.isHidden = file != nil
        if let file = file {
            filename.stringValue = file.document.url.lastPathComponent
            copies.stringValue = String(file.copies)
            firstPage.stringValue = String(file.firstPage)
            lastPage.stringValue = String(file.lastPage)
            rotate.state = file.rotate ? .on : .off
            fit.state = file.fit ? .on : .off
            show(file.setup)
            if file.document.isPDF {
                pdf.document = PDFDocument(url: file.document.url)
                pdf.isHidden = false
            } else if let source = CGImageSourceCreateWithURL(file.document.url as CFURL, nil),
                      let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: 1800
                      ] as CFDictionary) {
                image.image = NSImage(cgImage: thumbnail, size: .zero)
                image.isHidden = false
            }
            if let error = file.error { status.stringValue = error }
        } else { filename.stringValue = "尚未选择文件" }
        updateControls()
    }

    private func storeForm() throws {
        guard !busy, let file = selectedJob else { return }
        let count = Int(copies.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        let first = Int(firstPage.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        let last = Int(lastPage.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        try PrintOptions.validatePages(copies: count, firstPage: first, lastPage: last,
                                       pageCount: file.document.pageCount)
        file.copies = count
        file.firstPage = first
        file.lastPage = last
        file.rotate = rotate.state == .on
        file.fit = fit.state == .on
        file.setup = formSetup()
    }

    private func formSetup() -> PageSetup {
        var setup = PageSetup()
        setup.paper = PaperSize.allCases[max(paperPopup.indexOfSelectedItem, 0)]
        setup.quality = PrintQuality.allCases[max(qualityPopup.indexOfSelectedItem, 0)]
        setup.media = MediaType.allCases[max(mediaPopup.indexOfSelectedItem, 0)]
        setup.density = Array(PageSetup.densityRange)[max(densityPopup.indexOfSelectedItem, 0)]
        return setup
    }

    private func show(_ setup: PageSetup) {
        paperPopup.selectItem(at: PaperSize.allCases.firstIndex(of: setup.paper) ?? 0)
        qualityPopup.selectItem(at: PrintQuality.allCases.firstIndex(of: setup.quality) ?? 0)
        mediaPopup.selectItem(at: MediaType.allCases.firstIndex(of: setup.media) ?? 0)
        densityPopup.selectItem(at: Array(PageSetup.densityRange).firstIndex(of: setup.density) ?? 6)
        setupSummary.stringValue = "\(setup.summary) · 黑白单面"
    }

    @objc private func setupChanged() {
        let setup = formSetup()
        setup.save()
        selectedJob?.setup = setup
        show(setup)
        flash.reloadResult()
    }

    @objc private func chooseFiles() {
        showMain()
        if let chooser = fileChooser {
            chooser.makeKeyAndOrderFront(nil)
            return
        }
        let panel = NSOpenPanel()
        fileChooser = panel
        panel.allowedContentTypes = [.pdf, .png, .jpeg]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.beginSheetModal(for: window) { [weak self] result in
            self?.fileChooser = nil
            if result == .OK { self?.accept(panel.urls) }
        }
    }

    @objc private func removeSelected() {
        guard !busy, let id = selectedID, let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs.remove(at: index)
        selectedID = nil
        reloadList()
        if !jobs.isEmpty {
            let next = min(index, jobs.count - 1)
            table.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
            select(jobs[next])
        } else { select(nil) }
        status.stringValue = "已从列表移除，原始文件未改动。"
    }

    private func remove(_ files: [QueuedPrintFile]) {
        guard !busy else { return }
        let ids = Set(files.map(\.id))
        jobs.removeAll { ids.contains($0.id) }
        if let id = selectedID, ids.contains(id) {
            selectedID = nil
            select(nil)
        }
        reloadList()
        status.stringValue = "已从列表移除，原始文件未改动。"
    }

    private func chooseFilesForFlash() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf, .png, .jpeg]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] result in
            if result == .OK { self?.accept(panel.urls, intoFlash: true) }
        }
    }

    private func printFromFlash(_ files: [QueuedPrintFile]) {
        // The panel edits the queued files directly; reload the workbench form so storeForm keeps those values.
        if let selected = selectedJob, files.contains(where: { $0.id == selected.id }) { select(selected) }
        start(files)
    }

    @objc private func printSelected() {
        guard let selected = selectedJob else { return }
        start([selected])
    }
    @objc private func printWaiting() { start(jobs.filter { $0.state == .waiting }) }

    private func start(_ files: [QueuedPrintFile]) {
        guard !busy, !files.isEmpty else { return }
        do {
            try storeForm()
            let preferences = PrinterPreferences()
            let tasks = files.map { $0.task(connection: preferences) }
            for task in tasks { try task.options.validate(pageCount: task.document.pageCount) }
            guard let encoder = Bundle.main.url(forResource: "brother-encoder", withExtension: nil) else {
                throw PrintFailure(message: "找不到编码器，请重新构建应用。")
            }
            setBusy(true)
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                do {
                    try PrintBatch.run(tasks, encoder: encoder) { event in
                        DispatchQueue.main.async { self?.handle(event) }
                    }
                    DispatchQueue.main.async {
                        self?.setBusy(false)
                        self?.report("本批次数据发送完成，请确认实际出纸。未自动发送后来加入的文件。")
                    }
                } catch {
                    DispatchQueue.main.async {
                        self?.setBusy(false)
                        self?.report("\(error.localizedDescription)\n已停止本批次，未发送的文件仍留在待处理列表。")
                    }
                }
            }
        } catch {
            report(error.localizedDescription)
            if PrinterPreferences().host.isEmpty { showSettings() }
        }
    }

    private func handle(_ event: PrintBatchEvent) {
        switch event {
        case .state(let id, let value): jobs.first { $0.id == id }?.state = value
        case .progress(_, let message): report(message)
        case .sent(let id, let sheets):
            if let file = jobs.first(where: { $0.id == id }) { file.state = .sent; file.error = nil }
            report("已发送 \(sheets) 页数据，请确认实际出纸。")
        case .failed(let id, let error):
            if let file = jobs.first(where: { $0.id == id }) { file.state = .failed; file.error = error }
        }
        reloadList()
        flash.reloadResult()
    }

    private func report(_ message: String) {
        status.stringValue = message
        flash.setStatus(message)
    }

    private func setBusy(_ value: Bool) {
        busy = value
        flash.setBusy(value)
        progress.isHidden = !value
        if value { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }
        animateIcon(value)
        updateControls()
    }

    private func updateControls() {
        guard selectedButton != nil else { return }
        let file = selectedJob
        for field in [copies, firstPage, lastPage] { field.isEnabled = !busy && file != nil }
        rotate.isEnabled = !busy && file != nil
        for popup in [paperPopup, qualityPopup, mediaPopup, densityPopup] { popup.isEnabled = !busy && file != nil }
        fit.isEnabled = !busy && file?.document.isPDF == true
        selectedButton.isEnabled = !busy && file != nil
        allButton.isEnabled = !busy && jobs.contains { $0.state == .waiting }
        removeButton.isEnabled = !busy && file != nil
    }

    private func reloadList() {
        suppressSelection = true
        table.reloadData()
        if let selectedID = selectedID, let index = jobs.firstIndex(where: { $0.id == selectedID }) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
        suppressSelection = false
        listTitle.stringValue = "文件列表 · \(jobs.count)"
        updateControls()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { jobs.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard jobs.indices.contains(row) else { return nil }
        let file = jobs[row]
        let name = NSTextField(labelWithString: file.document.url.lastPathComponent)
        name.lineBreakMode = .byTruncatingMiddle
        name.font = .systemFont(ofSize: 12, weight: .medium)
        let detail = NSTextField(labelWithString: "\(file.document.pageCount) 页 · \(file.state.rawValue)")
        detail.font = .systemFont(ofSize: 10)
        detail.textColor = file.state == .failed ? .systemRed : .secondaryLabelColor
        let stack = NSStackView(views: [name, detail])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        let cell = NSTableCellView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        cell.setAccessibilityLabel("\(file.document.url.lastPathComponent)，\(file.state.rawValue)")
        return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelection else { return }
        select(jobs.indices.contains(table.selectedRow) ? jobs[table.selectedRow] : nil)
    }
    func selectionShouldChange(in tableView: NSTableView) -> Bool {
        do { try storeForm(); return true }
        catch { status.stringValue = error.localizedDescription; return false }
    }

    @objc private func testPage() {
        do {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("BrotherDropPrint-Test-\(UUID())", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                   attributes: [.posixPermissions: 0o700])
            ownedDirectories.insert(directory)
            let url = directory.appendingPathComponent("打印校准页.pdf")
            try PrintEngine.calibrationPDF(to: url)
            accept([url])
            selectedJob?.fit = false
            fit.state = .off
            // The calibration sheet is drawn on A4.
            selectedJob?.setup.paper = .a4
            if let setup = selectedJob?.setup { show(setup) }
            status.stringValue = "校准页已准备，尚未发送。打印后检查边框、方向、灰阶与 100 mm 标尺。"
        } catch { status.stringValue = error.localizedDescription }
    }

    private func animateIcon(_ active: Bool) {
        guard let button = item?.button else { return }
        button.contentTintColor = active ? .controlAccentColor : nil
        button.layer?.removeAnimation(forKey: "pulse")
        if active && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let animation = CABasicAnimation(keyPath: "opacity")
            animation.fromValue = 1
            animation.toValue = 0.4
            animation.duration = 0.45
            animation.autoreverses = true
            animation.repeatCount = .infinity
            button.layer?.add(animation, forKey: "pulse")
        }
    }

    @objc private func showMain() {
        guard window != nil else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
    @objc private func showSettings() { settings.show() }
    @objc private func about() { NSApp.orderFrontStandardAboutPanel(nil) }
    @objc private func toggleDragWindow() {
        var preferences = PrinterPreferences()
        preferences.automaticDropWindow.toggle()
        do { try preferences.save(); refreshPreferences() }
        catch { showMain(); status.stringValue = error.localizedDescription }
    }
    @objc private func openSource() {
        NSWorkspace.shared.open(URL(string: "https://github.com/lomai4n/brother-drop-print")!)
    }
    private func statusMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "显示打印工作台", action: #selector(showMain), keyEquivalent: "").target = self
        menu.addItem(withTitle: "设置…", action: #selector(showSettings), keyEquivalent: "").target = self
        let automatic = menu.addItem(withTitle: "拖文件自动显示浮窗", action: #selector(toggleDragWindow), keyEquivalent: "")
        automatic.target = self
        automatic.state = PrinterPreferences().automaticDropWindow ? .on : .off
        menu.addItem(.separator())
        menu.addItem(withTitle: "GitHub 源码", action: #selector(openSource), keyEquivalent: "").target = self
        menu.addItem(withTitle: "退出", action: #selector(quit), keyEquivalent: "q").target = self
        if let event = NSApp.currentEvent, let button = item.button {
            NSMenu.popUpContextMenu(menu, with: event, for: button)
        }
    }
    @objc private func quit() {
        if busy { showMain(); status.stringValue = "当前任务发送中，完成后再退出，以免产生不完整页面。" }
        else { NSApp.terminate(nil) }
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        if window == nil { openingURLs.append(contentsOf: urls) }
        else { accept(urls) }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMain()
        return true
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) {
        dragMonitor.stop()
        flash.hide()
        for directory in ownedDirectories { try? FileManager.default.removeItem(at: directory) }
    }
}
