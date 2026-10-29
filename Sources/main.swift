// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.first == "--configure", (3...4).contains(arguments.count),
   let port = Int(arguments[2]), (1...65535).contains(port) {
    UserDefaults.standard.set(arguments[1], forKey: "printerHost")
    UserDefaults.standard.set(port, forKey: "printerPort")
    if arguments.count == 4 {
        UserDefaults.standard.set(arguments[3], forKey: "printerInterface")
    }
    exit(0)
}
let application = NSApplication.shared
let delegate = MenuBarApp()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
