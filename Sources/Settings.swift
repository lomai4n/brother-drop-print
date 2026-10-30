// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit

struct PrinterPreferences {
    var host: String
    var port: Int
    var interface: String
    var automaticDropWindow: Bool

    init(defaults: UserDefaults = .standard) {
        host = defaults.string(forKey: "printerHost") ?? ""
        let savedPort = defaults.integer(forKey: "printerPort")
        port = savedPort > 0 ? savedPort : 9100
        interface = defaults.string(forKey: "printerInterface") ?? ""
        automaticDropWindow = defaults.object(forKey: "automaticDropWindow") as? Bool ?? true
    }

    func save(to defaults: UserDefaults = .standard) throws {
        guard (1...65535).contains(port) else {
            throw PrintFailure(message: "端口必须在 1–65535 之间。")
        }
        if !host.isEmpty { try PrintOptions.validateAddress(host: host, port: port) }
        defaults.set(host, forKey: "printerHost")
        defaults.set(port, forKey: "printerPort")
        defaults.set(interface, forKey: "printerInterface")
        defaults.set(automaticDropWindow, forKey: "automaticDropWindow")
    }
}

final class SettingsController: NSObject {
    var onSaved: (() -> Void)?
    var canSave: () -> Bool = { true }
    private var window: NSWindow!
    private let host = NSTextField()
    private let port = NSTextField()
    private let network = NSPopUpButton()
    private let automatic = NSButton(checkboxWithTitle: "拖动文件时自动显示接收浮窗", target: nil, action: nil)
    private let message = NSTextField(wrappingLabelWithString: "")

    override init() { super.init(); build() }

    func show() {
        let preferences = PrinterPreferences()
        host.stringValue = preferences.host
        port.stringValue = String(preferences.port)
        automatic.state = preferences.automaticDropWindow ? .on : .off
        network.removeAllItems()
        network.addItem(withTitle: "自动（系统路由）")
        network.lastItem?.representedObject = ""
        for adapter in PrintEngine.networkAdapters() {
            network.addItem(withTitle: adapter.label)
            network.lastItem?.representedObject = adapter.name
        }
        if let item = network.itemArray.first(where: { $0.representedObject as? String == preferences.interface }) {
            network.select(item)
        } else if !preferences.interface.isEmpty {
            network.addItem(withTitle: "\(preferences.interface)（已断开）")
            network.lastItem?.representedObject = preferences.interface
            network.select(network.lastItem)
        }
        message.stringValue = "连接参数只保存在本机。绑定网卡不可用时，打印任务会停止，不改走其他网络。"
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func build() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 510, height: 410),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Brother Drop Print 设置"
        window.isReleasedWhenClosed = false
        window.center()
        host.placeholderString = "打印机或转发入口的 IPv4 地址"
        host.setAccessibilityLabel("打印机 IP")
        port.setAccessibilityLabel("打印端口")
        network.setAccessibilityLabel("发送网卡")
        for view in [host, port] {
            view.widthAnchor.constraint(equalToConstant: 280).isActive = true
        }
        network.widthAnchor.constraint(equalToConstant: 280).isActive = true
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 18
        root.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 24),
            root.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -24),
            root.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 24)
        ])
        let title = NSTextField(labelWithString: "打印机与拖放")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        root.addArrangedSubview(title)
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "打印机 IP"), host],
            [NSTextField(labelWithString: "打印端口"), port],
            [NSTextField(labelWithString: "发送网卡"), network]
        ])
        grid.columnSpacing = 16
        grid.rowSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .leading
        root.addArrangedSubview(grid)
        root.addArrangedSubview(automatic)
        message.maximumNumberOfLines = 3
        message.preferredMaxLayoutWidth = 450
        message.font = .systemFont(ofSize: 12)
        message.textColor = .secondaryLabelColor
        root.addArrangedSubview(message)
        let cancel = NSButton(title: "取消", target: self, action: #selector(close))
        let save = NSButton(title: "保存设置", target: self, action: #selector(save))
        save.keyEquivalent = "\r"
        let buttons = NSStackView(views: [cancel, save])
        buttons.spacing = 12
        root.addArrangedSubview(buttons)
    }

    @objc private func close() { window.close() }

    @objc private func save() {
        guard canSave() else {
            message.stringValue = "当前批次发送中，完成后再保存连接设置。"
            return
        }
        var preferences = PrinterPreferences()
        preferences.host = host.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        preferences.port = Int(port.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        preferences.interface = network.selectedItem?.representedObject as? String ?? ""
        preferences.automaticDropWindow = automatic.state == .on
        do {
            try preferences.save()
            onSaved?()
            window.close()
        } catch { message.stringValue = error.localizedDescription }
    }
}
