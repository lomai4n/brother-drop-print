// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import PDFKit
import ImageIO
import QuartzCore
import OSLog

enum FlashStage: Equatable { case hidden, pill, card, result }

private final class FlashWindow: NSPanel {
    var allowsKey = false
    var onCancel: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onCancel?() }
    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }
}

/// Dashed receiving area of the expanded card.
private final class DashedZoneView: NSView {
    private let border = CAShapeLayer()
    var active = false { didSet { style() } }
    var rejected = false { didSet { style() } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 12
        border.fillColor = nil
        border.lineWidth = 1.2
        border.lineDashPattern = [5, 4]
        layer?.addSublayer(border)
        style()
    }
    required init?(coder: NSCoder) { nil }
    override func layout() {
        super.layout()
        border.frame = bounds
        border.path = CGPath(roundedRect: bounds.insetBy(dx: 0.6, dy: 0.6), cornerWidth: 12,
                             cornerHeight: 12, transform: nil)
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); style() }
    private func style() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let tint: NSColor = rejected ? .systemRed : .controlAccentColor
            layer?.backgroundColor = tint.withAlphaComponent(active ? 0.16 : 0.06).cgColor
            border.strokeColor = tint.withAlphaComponent(active ? 0.9 : 0.5).cgColor
        }
    }
}

/// QQ-style receiver: a capsule under the menu bar icon while a file is dragged,
/// an expanded card when the drag reaches it, and a print panel in place after the drop.
final class FlashDropController: NSObject {
    let dropView = FileDropView()
    var anchor: () -> NSRect? = { nil }
    var printerSummary: () -> String = { "" }
    var onPrint: (([QueuedPrintFile]) -> Void)?
    var onPreview: (() -> Void)?
    var onAdd: (() -> Void)?
    var onClear: (([QueuedPrintFile]) -> Void)?
    var onSettings: (() -> Void)?
    var presets: () -> [PrintPreset] = { PrintPreset.load() }
    /// Set by the app while a window it opened for the panel (such as a file chooser) is up.
    var holdOpen = false
    private(set) var stage = FlashStage.hidden
    private(set) var files: [QueuedPrintFile] = []

    private let panel: FlashWindow
    private let glass = NSVisualEffectView()
    private let pill = NSStackView()
    private let card = NSStackView()
    private let result = NSStackView()
    private let pillText = NSTextField(labelWithString: "")
    private let zone = DashedZoneView()
    private let paper = NSImageView()
    private let cardHint = NSTextField(labelWithString: "")
    private let thumbnail = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let copies = NSTextField(string: "1")
    private let stepper = NSStepper()
    private let firstPage = NSTextField(string: "1")
    private let lastPage = NSTextField(string: "1")
    private var pageRow: NSStackView!
    private let paperPopup = NSPopUpButton()
    private let qualityPopup = NSPopUpButton()
    private let presetPopup = NSPopUpButton()
    private let layoutPopup = NSPopUpButton()
    private let duplexBox = NSButton(checkboxWithTitle: "手动双面", target: nil, action: nil)
    private let chipRow = NSStackView()
    /// Set when the drop landed on a preset chip, for files that arrive from this drag.
    private var pendingPreset: PrintPreset?
    private var clickMonitors: [Any] = []
    private var gestureHadFileDrag = false
    private let printer = NSTextField(labelWithString: "")
    private let status = NSTextField(wrappingLabelWithString: "")
    private var printButton: NSButton!
    private var trash: NSButton!
    private var busy = false
    private var printerStatus = ""
    private var printerSeverity = PrinterStatusReport.Severity.ok
    private var topLeft = NSPoint.zero
    private var screenNumber: NSNumber?
    private var hiding: DispatchWorkItem?
    private var collapsing: DispatchWorkItem?
    private var carousel: Timer?
    private var carouselIndex = 0
    private let carouselTexts = ["文件拖到这，直接用 Brother 打印", "PDF、图片拖到这儿，即可打印"]
    private let cardHintText = "支持 PDF、PNG、JPEG · 本机转换，不经云端"
    private let width: CGFloat = 300
    private let pillSize = NSSize(width: 292, height: 36)
    private let cardHeight: CGFloat = 384
    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "org.brotherdropprint.app",
                                category: "drag")

    override init() {
        panel = FlashWindow(contentRect: NSRect(origin: .zero, size: pillSize),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        super.init()
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.title = "Brother 闪印"
        glass.material = .popover
        glass.state = .active
        glass.wantsLayer = true
        glass.layer?.masksToBounds = true
        panel.contentView = glass
        dropView.drawsTarget = false
        dropView.rejectsUnsupported = true
        pin(dropView, in: glass, inset: 0)
        buildPill()
        buildCard()
        buildResult()
        panel.onCancel = { [weak self] in self?.hide() }
        dropView.onHover = { [weak self] active in self?.hover(active) }
        dropView.onRejected = { [weak self] reason in self?.reject(reason) }
    }

    // MARK: Drag lifecycle

    func beginDrag() {
        // A file drag that starts while the print panel is open may be adding files to it.
        if stage == .result { gestureHadFileDrag = true }
        hiding?.cancel()
        hiding = nil
        pendingPreset = nil
        guard stage == .hidden else { return }
        place()
        show(.pill)
        logger.notice("flash_pill_shown_without_activation")
    }

    /// Called from the drag monitor while a file drag is in progress.
    func dragMoved() {
        guard stage == .pill || stage == .card else { return }
        let pointer = NSEvent.mouseLocation
        if number(of: screen(at: pointer)) != screenNumber {
            place()
            panel.setFrame(frame(for: panel.frame.size), display: true)
        }
        if stage == .pill && panel.frame.insetBy(dx: -28, dy: -28).contains(pointer) { show(.card) }
        else if stage == .card && !panel.frame.insetBy(dx: -48, dy: -48).contains(pointer) { scheduleCollapse() }
    }

    func endDrag() {
        guard stage == .pill || stage == .card else { return }
        hiding?.cancel()
        // Leave time for performDragOperation, which arrives after the mouse is released.
        let task = DispatchWorkItem { [weak self] in
            guard let self = self, self.stage != .result else { return }
            self.hide()
        }
        hiding = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: task)
    }

    /// Hides the capsule or card, but keeps a print panel the user is working in.
    func cancelDrag() { if stage != .result { hide() } }

    func showResult() {
        hiding?.cancel()
        hiding = nil
        if stage == .hidden { place() }
        status.stringValue = "正在读取文件…"
        show(.result)
        logger.notice("flash_result_shown")
    }

    func hide() {
        hiding?.cancel()
        collapsing?.cancel()
        hiding = nil
        collapsing = nil
        carousel?.invalidate()
        carousel = nil
        let wasVisible = panel.isVisible
        panel.orderOut(nil)
        panel.allowsKey = false
        stopWatchingClicks()
        stage = .hidden
        files.removeAll()
        pendingPreset = nil
        zone.active = false
        zone.rejected = false
        if wasVisible { logger.notice("flash_hidden") }
    }

    // MARK: Result content

    func add(_ received: [QueuedPrintFile]) {
        for file in received where !files.contains(where: { $0.id == file.id }) {
            if let preset = pendingPreset { file.setup = preset.setup }
            files.append(file)
        }
        if !received.isEmpty && !busy {
            let applied = pendingPreset.map { "已应用预设“\($0.name)”。" } ?? ""
            status.stringValue = PrinterPreferences().host.isEmpty ? "请先在设置中填写打印机地址。" :
                applied + "确认份数和页码后点“打印”。"
        }
        reloadResult()
    }

    func setStatus(_ message: String) {
        guard stage == .result else { return }
        status.stringValue = message
        fitResult()
    }

    func setPrinterStatus(_ text: String, severity: PrinterStatusReport.Severity) {
        printerStatus = text
        printerSeverity = severity
        if stage == .result { reloadResult() }
    }

    func setBusy(_ value: Bool) {
        busy = value
        reloadResult()
    }

    func reloadResult() {
        let single = files.count == 1 ? files[0] : nil
        if let first = files.first { thumbnail.image = Self.thumbnail(for: first.document) }
        else { thumbnail.image = NSImage(systemSymbolName: "doc", accessibilityDescription: nil) }
        let bytes = files.reduce(Int64(0)) { total, file in
            total + Int64((try? file.document.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        let pages = files.reduce(0) { $0 + $1.document.pageCount }
        if let file = single {
            name.stringValue = file.document.url.lastPathComponent
            detail.stringValue = "\(pages) 页 · \(size) · \(file.state.rawValue)"
            copies.stringValue = String(file.copies)
            firstPage.stringValue = String(file.firstPage)
            lastPage.stringValue = String(file.lastPage)
        } else {
            name.stringValue = files.isEmpty ? "尚未收到文件" : "\(files.count) 个文件"
            detail.stringValue = files.isEmpty ? "" : "共 \(pages) 页 · \(size)"
            if let file = files.first { copies.stringValue = String(file.copies) }
        }
        stepper.integerValue = Int(copies.stringValue) ?? 1
        let setup = files.first?.setup ?? .saved()
        paperPopup.selectItem(at: PaperSize.allCases.firstIndex(of: setup.paper) ?? 0)
        qualityPopup.selectItem(at: PrintQuality.allCases.firstIndex(of: setup.quality) ?? 0)
        layoutPopup.selectItem(at: PageSetup.layouts.firstIndex(of: setup.layout) ?? 0)
        duplexBox.state = setup.manualDuplex ? .on : .off
        let list = presets()
        presetPopup.removeAllItems()
        presetPopup.addItems(withTitles: list.map(\.name))
        if let match = PrintPreset.matching(setup, in: list), let index = list.firstIndex(of: match) {
            presetPopup.selectItem(at: index)
        } else {
            presetPopup.addItem(withTitle: "自定义")
            presetPopup.lastItem?.isEnabled = false
            presetPopup.select(presetPopup.lastItem)
        }
        pageRow.isHidden = single == nil
        printer.stringValue = [printerSummary(), printerStatus].filter { !$0.isEmpty }.joined(separator: " · ")
        printer.textColor = printerSeverity == .error ? .systemRed :
            printerSeverity == .warning ? .systemOrange : .labelColor
        printer.toolTip = printer.stringValue
        let sent = !files.isEmpty && files.allSatisfy { $0.state == .sent || $0.state == .printed }
        printButton.title = sent ? "再次打印" : "打印"
        printButton.isEnabled = !busy && !files.isEmpty
        trash.isEnabled = !busy && !files.isEmpty
        for control in [copies, firstPage, lastPage, stepper, paperPopup, qualityPopup, presetPopup,
                        layoutPopup, duplexBox] as [NSControl] {
            control.isEnabled = !busy
        }
        fitResult()
    }

    private func fitResult() {
        guard stage == .result else { return }
        result.layoutSubtreeIfNeeded()
        // Go through the animator so this size replaces any expansion still in flight.
        let target = frame(for: NSSize(width: width, height: resultHeight))
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduceMotion ? 0 : 0.12
            panel.animator().setFrame(target, display: true)
        }
    }

    // MARK: Stages

    private var resultHeight: CGFloat { result.fittingSize.height + 24 }

    private func show(_ next: FlashStage) {
        collapsing?.cancel()
        collapsing = nil
        let previous = stage
        stage = next
        pill.isHidden = next != .pill
        card.isHidden = next != .card
        result.isHidden = next != .result
        panel.allowsKey = next == .result
        if next == .result { watchOutsideClicks() } else { stopWatchingClicks() }
        if next == .pill { startCarousel() } else { carousel?.invalidate(); carousel = nil }
        if next == .card {
            zone.rejected = false
            cardHint.stringValue = cardHintText
            cardHint.textColor = .secondaryLabelColor
            if previous != .card { rebuildChips() }
        }
        if next == .result { reloadResult() }
        let size: NSSize
        switch next {
        case .pill: size = pillSize
        case .card: size = NSSize(width: width, height: cardHeight)
        default: size = NSSize(width: width, height: resultHeight)
        }
        glass.layer?.cornerRadius = next == .pill ? pillSize.height / 2 : 16
        let target = frame(for: size)
        if !panel.isVisible {
            panel.setFrame(target, display: true)
            panel.alphaValue = reduceMotion ? 1 : 0
            panel.orderFrontRegardless()
            if !reduceMotion { NSAnimationContext.runAnimationGroup { $0.duration = 0.15; panel.animator().alphaValue = 1 } }
        } else if previous != next {
            if reduceMotion { panel.setFrame(target, display: true) }
            else {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.18
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    panel.animator().setFrame(target, display: true)
                }
            }
        }
    }

    /// Like a popover: a click elsewhere closes the print panel. The files stay in the workbench list.
    private func watchOutsideClicks() {
        guard clickMonitors.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseUp, .rightMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.outsideClick(event)
        }) { clickMonitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            // Only this app's ordinary windows count; menus and pop-up lists from the panel do not.
            if let self = self, let window = event.window, window !== self.panel, window.level == .normal {
                self.outsideClick(event)
            }
            return event
        }) { clickMonitors.append(local) }
    }

    private func stopWatchingClicks() {
        clickMonitors.forEach(NSEvent.removeMonitor)
        clickMonitors.removeAll()
    }

    private func outsideClick(_ event: NSEvent) {
        guard stage == .result, !holdOpen else { return }
        switch event.type {
        case .leftMouseDown: gestureHadFileDrag = false
        // Decide on release, so a file dragged from elsewhere can still be added to the panel.
        case .leftMouseUp: if !gestureHadFileDrag { hide() }
        default: hide()
        }
    }

    private func hover(_ active: Bool) {
        if active {
            collapsing?.cancel()
            collapsing = nil
            if stage == .pill { show(.card) }
            zone.active = stage == .card
            animatePaper(stage == .card)
        } else {
            zone.active = false
            animatePaper(false)
            if stage == .card { scheduleCollapse() }
        }
    }

    private func reject(_ reason: String) {
        if stage == .pill { show(.card) }
        zone.rejected = true
        cardHint.stringValue = reason
        cardHint.textColor = .systemRed
        if stage == .result { status.stringValue = reason }
    }

    private func scheduleCollapse() {
        guard collapsing == nil else { return }
        let task = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.collapsing = nil
            guard self.stage == .card, NSEvent.pressedMouseButtons & 1 != 0,
                  !self.panel.frame.contains(NSEvent.mouseLocation) else { return }
            self.show(.pill)
        }
        collapsing = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: task)
    }

    private func startCarousel() {
        carouselIndex = 0
        pillText.stringValue = carouselTexts[0]
        carousel?.invalidate()
        let timer = Timer(timeInterval: 2.6, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.carouselIndex = (self.carouselIndex + 1) % self.carouselTexts.count
            if !self.reduceMotion {
                let fade = CATransition()
                fade.type = .push
                fade.subtype = .fromTop
                fade.duration = 0.25
                self.pillText.layer?.add(fade, forKey: "carousel")
            }
            self.pillText.stringValue = self.carouselTexts[self.carouselIndex]
        }
        RunLoop.main.add(timer, forMode: .common)
        carousel = timer
    }

    private func animatePaper(_ active: Bool) {
        paper.layer?.removeAnimation(forKey: "drop")
        guard active, !reduceMotion else { return }
        let drop = CABasicAnimation(keyPath: "transform.translation.y")
        drop.fromValue = 0
        drop.toValue = -12
        drop.duration = 0.45
        drop.autoreverses = true
        drop.repeatCount = .infinity
        paper.layer?.add(drop, forKey: "drop")
    }

    // MARK: Placement

    private func screen(at point: NSPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
    }

    private func number(of screen: NSScreen?) -> NSNumber? {
        screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
    }

    /// Under the menu bar icon when it is on the pointer's screen, else at the top right of that screen.
    private func place() {
        guard let screen = screen(at: NSEvent.mouseLocation) else { return }
        screenNumber = number(of: screen)
        let visible = screen.visibleFrame
        if let icon = anchor(), icon.width > 0, screen.frame.intersects(icon) {
            topLeft = NSPoint(x: icon.minX - 12, y: visible.maxY - 6)
        } else {
            topLeft = NSPoint(x: visible.maxX - width - 72, y: visible.maxY - 6)
        }
    }

    private func frame(for size: NSSize) -> NSRect {
        let visible = (NSScreen.screens.first { number(of: $0) == screenNumber } ?? NSScreen.main)?.visibleFrame ?? .zero
        let x = min(max(topLeft.x, visible.minX + 8), visible.maxX - size.width - 8)
        let y = max(topLeft.y - size.height, visible.minY + 8)
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    // MARK: Building

    private func pin(_ view: NSView, in parent: NSView, inset: CGFloat) {
        view.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: inset),
            view.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -inset),
            view.topAnchor.constraint(equalTo: parent.topAnchor, constant: inset),
            view.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -inset)
        ])
    }

    private func symbol(_ name: String, size: CGFloat, tint: NSColor? = .controlAccentColor) -> NSImageView {
        let view = NSImageView()
        view.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: .regular))
        view.contentTintColor = tint
        return view
    }

    private func iconButton(_ name: String, label: String, action: @escaping () -> Void) -> NSButton {
        let button = ClosureButton(image: NSImage(systemSymbolName: name, accessibilityDescription: label)!,
                                   handler: action)
        button.isBordered = false
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = label
        return button
    }

    private func header(_ title: String) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [symbol("printer.fill", size: 13), label, spacer])
        row.spacing = 7
        row.heightAnchor.constraint(equalToConstant: 22).isActive = true
        return row
    }

    private func buildPill() {
        pillText.font = .systemFont(ofSize: 13, weight: .medium)
        pillText.wantsLayer = true
        pillText.lineBreakMode = .byTruncatingTail
        pillText.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pill.setViews([symbol("printer.fill", size: 13), pillText], in: .leading)
        pill.spacing = 8
        pill.edgeInsets = NSEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
        pin(pill, in: dropView, inset: 0)
    }

    private func buildCard() {
        card.orientation = .vertical
        card.alignment = .leading
        card.spacing = 10
        card.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 14, right: 14)
        let head = header("松手添加文件")
        card.addArrangedSubview(head)
        head.widthAnchor.constraint(equalTo: card.widthAnchor, constant: -28).isActive = true

        let printerIcon = symbol("printer.fill", size: 50)
        paper.image = NSImage(systemSymbolName: "doc.text.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 26, weight: .regular))
        paper.contentTintColor = .secondaryLabelColor
        paper.wantsLayer = true
        let art = NSView()
        for view in [paper, printerIcon] {
            view.translatesAutoresizingMaskIntoConstraints = false
            art.addSubview(view)
            view.centerXAnchor.constraint(equalTo: art.centerXAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            art.heightAnchor.constraint(equalToConstant: 88),
            art.widthAnchor.constraint(equalToConstant: 100),
            paper.topAnchor.constraint(equalTo: art.topAnchor),
            printerIcon.bottomAnchor.constraint(equalTo: art.bottomAnchor)
        ])
        let title = NSTextField(labelWithString: "文件拖到这\n发送到 Brother 打印机")
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        title.alignment = .center
        title.maximumNumberOfLines = 2
        cardHint.font = .systemFont(ofSize: 11)
        cardHint.alignment = .center
        cardHint.textColor = .secondaryLabelColor
        cardHint.stringValue = cardHintText
        let inner = NSStackView(views: [art, title, cardHint])
        inner.orientation = .vertical
        inner.spacing = 12
        inner.translatesAutoresizingMaskIntoConstraints = false
        zone.addSubview(inner)
        NSLayoutConstraint.activate([
            inner.centerXAnchor.constraint(equalTo: zone.centerXAnchor),
            inner.centerYAnchor.constraint(equalTo: zone.centerYAnchor),
            inner.widthAnchor.constraint(lessThanOrEqualTo: zone.widthAnchor, constant: -16)
        ])
        card.addArrangedSubview(zone)
        zone.widthAnchor.constraint(equalTo: card.widthAnchor, constant: -28).isActive = true
        zone.setContentHuggingPriority(.defaultLow, for: .vertical)
        zone.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        let chipTitle = NSTextField(labelWithString: "或拖到预设上，直接带上该预设的设置")
        chipTitle.font = .systemFont(ofSize: 11)
        chipTitle.textColor = .secondaryLabelColor
        card.addArrangedSubview(chipTitle)
        chipRow.distribution = .fillEqually
        chipRow.spacing = 8
        card.addArrangedSubview(chipRow)
        chipRow.widthAnchor.constraint(equalTo: card.widthAnchor, constant: -28).isActive = true
        chipRow.heightAnchor.constraint(equalToConstant: 34).isActive = true
        // Pinned to the top only: the card keeps its height while the panel is a capsule.
        card.translatesAutoresizingMaskIntoConstraints = false
        dropView.addSubview(card)
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: dropView.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: dropView.trailingAnchor),
            card.topAnchor.constraint(equalTo: dropView.topAnchor),
            card.heightAnchor.constraint(equalToConstant: cardHeight)
        ])
    }

    private func buildResult() {
        result.orientation = .vertical
        result.alignment = .leading
        result.spacing = 9
        result.translatesAutoresizingMaskIntoConstraints = false
        dropView.addSubview(result)
        NSLayoutConstraint.activate([
            result.leadingAnchor.constraint(equalTo: dropView.leadingAnchor, constant: 14),
            result.trailingAnchor.constraint(equalTo: dropView.trailingAnchor, constant: -14),
            result.topAnchor.constraint(equalTo: dropView.topAnchor, constant: 12),
            // Fixed width: long names truncate instead of widening the panel past its buttons.
            result.widthAnchor.constraint(equalToConstant: width - 28)
        ])
        func full(_ view: NSView) {
            result.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: result.widthAnchor).isActive = true
        }
        func spacer() -> NSView {
            let view = NSView()
            view.setContentHuggingPriority(.defaultLow, for: .horizontal)
            return view
        }
        full(header("Brother 闪印"))

        let add = iconButton("plus", label: "继续添加文件") { [weak self] in self?.onAdd?() }
        trash = iconButton("trash", label: "从列表移除这些文件") { [weak self] in
            guard let self = self else { return }
            self.onClear?(self.files)
            self.hide()
        }
        thumbnail.imageScaling = .scaleProportionallyUpOrDown
        thumbnail.setAccessibilityLabel("首页预览")
        let box = NSView()
        box.wantsLayer = true
        box.layer?.cornerRadius = 10
        box.layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.08).cgColor
        for view in [add, trash!, thumbnail] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            box.addSubview(view)
        }
        NSLayoutConstraint.activate([
            box.heightAnchor.constraint(equalToConstant: 132),
            add.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 8),
            add.topAnchor.constraint(equalTo: box.topAnchor, constant: 8),
            trash.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -8),
            trash.topAnchor.constraint(equalTo: box.topAnchor, constant: 8),
            thumbnail.centerXAnchor.constraint(equalTo: box.centerXAnchor),
            thumbnail.centerYAnchor.constraint(equalTo: box.centerYAnchor),
            thumbnail.heightAnchor.constraint(equalToConstant: 112),
            thumbnail.widthAnchor.constraint(equalToConstant: 112)
        ])
        full(box)

        name.font = .systemFont(ofSize: 13, weight: .semibold)
        name.lineBreakMode = .byTruncatingMiddle
        for label in [name, detail, printer, status] {
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        name.alignment = .center
        full(name)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        let settings = ClosureButton(title: "设置", handler: { [weak self] in self?.onSettings?() })
        settings.isBordered = false
        settings.contentTintColor = .controlAccentColor
        settings.font = .systemFont(ofSize: 11)
        let divider = NSTextField(labelWithString: "|")
        divider.textColor = .tertiaryLabelColor
        divider.font = .systemFont(ofSize: 11)
        let info = NSStackView(views: [spacer(), detail, divider, settings, spacer()])
        info.spacing = 5
        full(info)
        info.arrangedSubviews[0].widthAnchor.constraint(equalTo: info.arrangedSubviews[4].widthAnchor).isActive = true

        let line = NSBox()
        line.boxType = .separator
        full(line)

        func label(_ text: String) -> NSTextField {
            let view = NSTextField(labelWithString: text)
            view.font = .systemFont(ofSize: 12)
            view.textColor = .secondaryLabelColor
            view.widthAnchor.constraint(equalToConstant: 40).isActive = true
            return view
        }
        func numeric(_ field: NSTextField, _ accessibility: String) {
            field.alignment = .center
            field.setAccessibilityLabel(accessibility)
            field.widthAnchor.constraint(equalToConstant: 44).isActive = true
        }
        numeric(copies, "打印份数")
        stepper.minValue = 1
        stepper.maxValue = 99
        stepper.integerValue = 1
        stepper.valueWraps = false
        stepper.target = self
        stepper.action = #selector(stepped)
        full(NSStackView(views: [label("份数"), copies, stepper, spacer()]))
        numeric(firstPage, "开始页码")
        numeric(lastPage, "结束页码")
        pageRow = NSStackView(views: [label("页码"), firstPage, NSTextField(labelWithString: "至"), lastPage, spacer()])
        full(pageRow)
        paperPopup.addItems(withTitles: PaperSize.allCases.map(\.label))
        paperPopup.setAccessibilityLabel("纸张尺寸")
        qualityPopup.addItems(withTitles: PrintQuality.allCases.map(\.label))
        qualityPopup.setAccessibilityLabel("打印质量")
        presetPopup.autoenablesItems = false
        presetPopup.setAccessibilityLabel("打印预设")
        layoutPopup.addItems(withTitles: PageSetup.layouts.map { "\($0) 合 1" })
        layoutPopup.setAccessibilityLabel("每张纸的页数")
        duplexBox.setAccessibilityHelp("先印正面，翻面放回纸盒后再印背面")
        for control in [presetPopup, paperPopup, qualityPopup, layoutPopup, duplexBox] as [NSControl] {
            control.target = self
            control.action = #selector(setupChosen(_:))
        }
        full(NSStackView(views: [label("预设"), presetPopup, spacer()]))
        full(NSStackView(views: [label("纸张"), paperPopup, spacer()]))
        full(NSStackView(views: [label("质量"), qualityPopup, spacer()]))
        full(NSStackView(views: [label("版式"), layoutPopup, duplexBox, spacer()]))
        printer.font = .systemFont(ofSize: 12)
        printer.lineBreakMode = .byTruncatingTail
        full(NSStackView(views: [label("打印机"), printer, spacer()]))

        let preview = ClosureButton(title: "预览", handler: { [weak self] in self?.onPreview?() })
        preview.bezelStyle = .rounded
        printButton = ClosureButton(title: "打印", handler: { [weak self] in self?.printTapped() })
        printButton.bezelStyle = .rounded
        printButton.keyEquivalent = "\r"
        printButton.bezelColor = .controlAccentColor
        full(NSStackView(views: [preview, spacer(), printButton]))
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.maximumNumberOfLines = 3
        status.preferredMaxLayoutWidth = width - 28
        full(status)
    }

    @objc private func stepped() { copies.stringValue = String(stepper.integerValue) }

    @objc private func setupChosen(_ sender: NSControl) {
        guard !files.isEmpty else { return }
        var setup = files[0].setup
        if sender === presetPopup {
            let list = presets()
            guard list.indices.contains(presetPopup.indexOfSelectedItem) else { return }
            setup = list[presetPopup.indexOfSelectedItem].setup
        } else {
            setup.paper = PaperSize.allCases[max(paperPopup.indexOfSelectedItem, 0)]
            setup.quality = PrintQuality.allCases[max(qualityPopup.indexOfSelectedItem, 0)]
            setup.layout = PageSetup.layouts[max(layoutPopup.indexOfSelectedItem, 0)]
            setup.manualDuplex = duplexBox.state == .on
        }
        for file in files { file.setup = setup }
        setup.save()
        reloadResult()
    }

    private func rebuildChips() {
        for view in chipRow.arrangedSubviews { chipRow.removeArrangedSubview(view); view.removeFromSuperview() }
        for preset in presets().prefix(3) {
            let chip = FileDropView()
            chip.rejectsUnsupported = true
            chip.setAccessibilityLabel("拖到这里，使用预设“\(preset.name)”")
            let title = NSTextField(labelWithString: preset.name)
            title.font = .systemFont(ofSize: 12, weight: .medium)
            title.lineBreakMode = .byTruncatingTail
            title.translatesAutoresizingMaskIntoConstraints = false
            chip.addSubview(title)
            NSLayoutConstraint.activate([
                title.centerXAnchor.constraint(equalTo: chip.centerXAnchor),
                title.centerYAnchor.constraint(equalTo: chip.centerYAnchor),
                title.widthAnchor.constraint(lessThanOrEqualTo: chip.widthAnchor, constant: -10)
            ])
            chip.toolTip = preset.setup.summary
            chip.onHover = { [weak self] active in
                guard let self = self else { return }
                if active { self.collapsing?.cancel(); self.collapsing = nil }
                else if self.stage == .card { self.scheduleCollapse() }
            }
            chip.onRejected = { [weak self] reason in self?.reject(reason) }
            // Same receipt path as the main area; only the preset differs.
            chip.onAccepted = { [weak self] in
                self?.pendingPreset = preset
                self?.dropView.onAccepted?()
            }
            chip.onFiles = { [weak self] urls, directory in self?.dropView.onFiles?(urls, directory) }
            chip.onReceiving = { [weak self] directory in self?.dropView.onReceiving?(directory) }
            chip.onError = { [weak self] message in self?.dropView.onError?(message) }
            chipRow.addArrangedSubview(chip)
        }
    }

    private func printTapped() {
        guard !files.isEmpty else { return }
        let count = Int(copies.stringValue.trimmingCharacters(in: .whitespaces)) ?? 0
        do {
            if files.count == 1 {
                let first = Int(firstPage.stringValue.trimmingCharacters(in: .whitespaces)) ?? 0
                let last = Int(lastPage.stringValue.trimmingCharacters(in: .whitespaces)) ?? 0
                try PrintOptions.validatePages(copies: count, firstPage: first, lastPage: last,
                                               pageCount: files[0].document.pageCount)
                files[0].firstPage = first
                files[0].lastPage = last
            }
            for file in files {
                try PrintOptions.validatePages(copies: count, firstPage: file.firstPage,
                                               lastPage: file.lastPage, pageCount: file.document.pageCount)
            }
            for file in files { file.copies = count }
            files[0].setup.save()
            onPrint?(files)
        } catch { status.stringValue = error.localizedDescription }
    }

    static func thumbnail(for document: PrintDocument) -> NSImage? {
        if document.isPDF {
            // Keep the document alive while its page draws.
            guard let pdf = PDFDocument(url: document.url), let page = pdf.page(at: 0) else { return nil }
            return page.thumbnail(of: NSSize(width: 224, height: 224), for: .mediaBox)
        }
        guard let source = CGImageSourceCreateWithURL(document.url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 448
              ] as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: .zero)
    }
}

/// Button with a closure action, so panel controls need no extra @objc targets.
final class ClosureButton: NSButton {
    private var handler: () -> Void = {}
    convenience init(image: NSImage, handler: @escaping () -> Void) {
        self.init(image: image, target: nil, action: nil)
        bind(handler)
    }
    convenience init(title: String, handler: @escaping () -> Void) {
        self.init(title: title, target: nil, action: nil)
        bind(handler)
    }
    private func bind(_ handler: @escaping () -> Void) {
        self.handler = handler
        target = self
        action = #selector(run)
    }
    @objc private func run() { handler() }
}
