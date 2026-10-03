import Foundation
import AppKit
import UniformTypeIdentifiers

/// Reads the Finder's selection, and optionally the text inside the selected files.
nonisolated enum FinderBridge {

    static let appName = "Finder"
    private static let bundleID = "com.apple.finder"

    /// Largest file we will inline into a prompt. Anything bigger is listed by name only —
    /// silently truncating a 40 MB log into a prompt helps nobody.
    static let maxInlineBytes = 120_000

    /// Text-ish types we are willing to read. Everything else is referenced by path.
    private static let readableTypes: [UTType] = [
        .plainText, .utf8PlainText, .rtf, .sourceCode, .script, .json, .xml, .yaml,
        .commaSeparatedText, .tabSeparatedText, .propertyList, .html, .delimitedText,
    ]

    static func captureSelection(includeFileContents: Bool = true) async throws -> CapturedContext {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty else {
            throw AutomationError.notRunning(app: appName)
        }

        switch AutomationPermission.status(bundleIdentifier: bundleID, prompt: true) {
        case .denied: throw AutomationError.permissionDenied(app: appName)
        case .needsPrompt: throw AutomationError.permissionNotGranted(app: appName)
        case .granted, .targetNotRunning, .unknown: break
        }

        let raw = try await AppleScriptRunner.runForString(script, appName: appName)
        let paths = raw
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !paths.isEmpty else { throw AutomationError.noResult(app: appName) }

        let urls = paths.map { URL(fileURLWithPath: $0) }
        return context(for: urls, includeFileContents: includeFileContents)
    }

    /// Selected items, falling back to the front window's folder when nothing is selected.
    private static var script: String {
        AppleScriptRunner.timed("""
        set output to ""
        tell application id "com.apple.finder"
            set theItems to selection
            if (count of theItems) is 0 then
                try
                    set output to POSIX path of (target of front window as alias)
                end try
            else
                repeat with anItem in theItems
                    try
                        set output to output & (POSIX path of (anItem as alias)) & linefeed
                    end try
                end repeat
            end if
        end tell
        return output
        """)
    }

    // MARK: - Body building

    static func context(for urls: [URL], includeFileContents: Bool) -> CapturedContext {
        var lines: [String] = []
        var inlined = 0
        var skipped = 0

        for url in urls {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey, .contentTypeKey])
            let isDirectory = values?.isDirectory ?? false
            let size = values?.fileSize ?? 0

            lines.append("• \(url.lastPathComponent) — \(url.path)")

            guard includeFileContents, !isDirectory else { continue }

            guard let type = values?.contentType, readableTypes.contains(where: { type.conforms(to: $0) }) else {
                skipped += 1
                continue
            }

            guard size <= maxInlineBytes else {
                lines.append("  (\(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)) — too large to include)")
                skipped += 1
                continue
            }

            if let text = try? String(contentsOf: url, encoding: .utf8) {
                lines.append("")
                lines.append("```")
                lines.append(text)
                lines.append("```")
                inlined += 1
            } else {
                skipped += 1
            }
        }

        let title: String
        if urls.count == 1 {
            title = urls[0].lastPathComponent
        } else {
            title = "\(urls.count) items"
        }

        var partial: String?
        if includeFileContents && inlined == 0 && skipped > 0 {
            partial = "Paths only — nothing here is readable as text."
        } else if skipped > 0 {
            partial = "\(inlined) file\(inlined == 1 ? "" : "s") included, \(skipped) listed by path."
        }

        return CapturedContext(
            source: .finder,
            title: title,
            detail: urls.first?.deletingLastPathComponent().lastPathComponent,
            url: urls.count == 1 ? urls[0] : nil,
            body: lines.joined(separator: "\n"),
            partial: partial
        )
    }
}
