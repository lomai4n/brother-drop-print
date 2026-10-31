// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import Darwin
import CoreText

enum DocumentFormatSupport {
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg"]
    static let officeExtensions: Set<String> = [
        "doc", "docx", "odt", "rtf", "txt",
        "xls", "xlsx", "xlsm", "ods", "csv", "tsv",
        "ppt", "pptx", "odp"
    ]
    static let supportedExtensions = imageExtensions.union(officeExtensions).union(["pdf"])

    static func supports(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }
}

final class ConvertedDocumentStorage {
    let directory: URL
    let pdfURL: URL

    init(directory: URL, pdfURL: URL) {
        self.directory = directory
        self.pdfURL = pdfURL
    }

    deinit { try? FileManager.default.removeItem(at: directory) }
}

enum OfficeDocumentConverter {
    private static let substitutions: [(String, String)] = [
        ("宋体", "Songti SC"), ("SimSun", "Songti SC"),
        ("新宋体", "Songti SC"), ("NSimSun", "Songti SC"),
        ("仿宋", "Songti SC"), ("仿宋_GB2312", "Songti SC"),
        ("FangSong", "Songti SC"), ("楷体", "Songti SC"),
        ("楷体_GB2312", "Songti SC"), ("KaiTi", "Songti SC"),
        ("黑体", "Heiti SC"), ("SimHei", "Heiti SC"),
        ("微软雅黑", "Heiti SC"), ("Microsoft YaHei", "Heiti SC"),
        ("Microsoft YaHei UI", "Heiti SC"),
        ("方正小标宋简体", "Songti SC"), ("方正小标宋_GBK", "Songti SC")
    ]

    static var fontSubstitutionXML: String {
        let pairs = substitutions.enumerated().map { index, pair in
            """
            <node oor:name="BrotherDropPrint\(index)" oor:op="replace">
              <prop oor:name="ReplaceFont" oor:op="fuse"><value>\(pair.0)</value></prop>
              <prop oor:name="SubstituteFont" oor:op="fuse"><value>\(pair.1)</value></prop>
              <prop oor:name="OnScreenOnly" oor:op="fuse"><value>false</value></prop>
              <prop oor:name="Always" oor:op="fuse"><value>true</value></prop>
            </node>
            """
        }.joined(separator: "\n")
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <oor:items xmlns:oor="http://openoffice.org/2001/registry">
          <item oor:path="/org.openoffice.Office.Common/Font/Substitution">
            <prop oor:name="Replacement" oor:op="fuse"><value>true</value></prop>
          </item>
          <item oor:path="/org.openoffice.Office.Common/Font/Substitution/FontPairs">
        \(pairs)
          </item>
        </oor:items>
        """
    }

    static func bundledFontDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        let candidate = environment["BROTHER_DROP_PRINT_FONT_DIR"].map(URL.init(fileURLWithPath:)) ??
            Bundle.main.resourceURL?.appendingPathComponent("Fonts", isDirectory: true)
        guard let directory = candidate,
              FileManager.default.fileExists(atPath: directory.path) else { return nil }
        return directory
    }

    private static func xmlEscaped(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func fontconfigXML(fontDirectories: [URL], cacheDirectory: URL) -> String {
        let directories = fontDirectories.map { "  <dir>\(xmlEscaped($0.path))</dir>" }
            .joined(separator: "\n")
        return """
        <?xml version="1.0"?>
        <!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
        <fontconfig>
        \(directories)
          <cachedir>\(xmlEscaped(cacheDirectory.path))</cachedir>
          <config><rescan><int>0</int></rescan></config>
        </fontconfig>
        """
    }

    private static func configureFonts(profile: URL, process: Process) throws {
        let user = profile.appendingPathComponent("user", isDirectory: true)
        try FileManager.default.createDirectory(at: user, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try Data(fontSubstitutionXML.utf8).write(
            to: user.appendingPathComponent("registrymodifications.xcu"), options: .atomic)
        guard let fonts = bundledFontDirectory() else { return }
        let fontFiles = (try? FileManager.default.contentsOfDirectory(at: fonts,
            includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        for font in fontFiles where ["otf", "ttf", "ttc"].contains(font.pathExtension.lowercased()) {
            CTFontManagerRegisterFontsForURL(font as CFURL, .session, nil)
        }
        var environment = ProcessInfo.processInfo.environment
        let fontconfig = profile.appendingPathComponent("fontconfig", isDirectory: true)
        let cache = fontconfig.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var fontDirectories = [fonts,
            URL(fileURLWithPath: "/System/Library/Fonts", isDirectory: true),
            URL(fileURLWithPath: "/System/Library/Fonts/Supplemental", isDirectory: true),
            URL(fileURLWithPath: "/Library/Fonts", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Fonts", isDirectory: true)]
        if let executable = process.executableURL {
            let officeFonts = executable.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Resources/fonts/truetype", isDirectory: true)
            fontDirectories.append(officeFonts)
        }
        let configuration = fontconfig.appendingPathComponent("fonts.conf")
        try Data(fontconfigXML(fontDirectories: fontDirectories, cacheDirectory: cache).utf8)
            .write(to: configuration, options: .atomic)
        environment["FONTCONFIG_FILE"] = configuration.path
        if let existing = environment["SAL_FONTPATH"], !existing.isEmpty {
            environment["SAL_FONTPATH"] = fonts.path + ":" + existing
        } else {
            environment["SAL_FONTPATH"] = fonts.path
        }
        process.environment = environment
    }

    static func executable(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        var candidates: [String] = []
        if let override = environment["BROTHER_DROP_PRINT_SOFFICE"], !override.isEmpty {
            candidates.append(override)
        }
        candidates += [
            "/Applications/LibreOffice.app/Contents/MacOS/soffice",
            "/Applications/LibreOffice.app/Contents/MacOS/LibreOffice",
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications/LibreOffice.app/Contents/MacOS/soffice").path,
            "/opt/homebrew/bin/soffice", "/usr/local/bin/soffice"
        ]
        if let path = environment["PATH"] {
            candidates += path.split(separator: ":").map { "\($0)/soffice" }
        }
        return candidates.lazy.map { URL(fileURLWithPath: $0) }.first {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }
    }

    static func convert(_ source: URL) throws -> ConvertedDocumentStorage {
        guard let soffice = executable() else {
            throw PrintFailure(message: "打印 Word、Excel、PowerPoint 等办公文档需要先安装 LibreOffice。安装后重新打开本应用即可使用。")
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrotherDropPrint-Convert-\(UUID().uuidString)", isDirectory: true)
        let output = root.appendingPathComponent("output", isDirectory: true)
        let profile = root.appendingPathComponent("profile", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let process = Process()
            process.executableURL = soffice
            try configureFonts(profile: profile, process: process)
            process.arguments = [
                "-env:UserInstallation=\(profile.absoluteString)", "--headless", "--nologo",
                "--nodefault", "--nofirststartwizard", "--norestore",
                "--convert-to", "pdf", "--outdir", output.path, source.path
            ]
            let messages = Pipe()
            process.standardOutput = messages
            process.standardError = messages
            let finished = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in finished.signal() }
            try process.run()
            if finished.wait(timeout: .now() + 90) == .timedOut {
                process.terminate()
                if finished.wait(timeout: .now() + 3) == .timedOut {
                    kill(process.processIdentifier, SIGKILL)
                    process.waitUntilExit()
                }
                throw PrintFailure(message: "办公文档转换超时。请关闭可能正在等待密码的文档窗口，然后重试。")
            }
            let messageData = messages.fileHandleForReading.readDataToEndOfFile()
            let detail = String(decoding: messageData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard process.terminationStatus == 0 else {
                throw PrintFailure(message: detail.isEmpty ? "办公文档转换失败，请确认文件未损坏或加密。" :
                    "办公文档转换失败：\(detail)")
            }
            let pdfs = try FileManager.default.contentsOfDirectory(at: output,
                includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
                .filter { $0.pathExtension.lowercased() == "pdf" }
            guard pdfs.count == 1, let pdf = pdfs.first,
                  try pdf.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true,
                  let size = try pdf.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0 else {
                throw PrintFailure(message: "办公文档没有转换出可打印的 PDF，请检查文档内容、密码保护和打印区域。")
            }
            return ConvertedDocumentStorage(directory: root, pdfURL: pdf)
        } catch {
            try? FileManager.default.removeItem(at: root)
            if let failure = error as? PrintFailure { throw failure }
            throw PrintFailure(message: "办公文档转换失败：\(error.localizedDescription)")
        }
    }
}
