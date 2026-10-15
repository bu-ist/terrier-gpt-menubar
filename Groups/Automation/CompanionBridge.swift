import Foundation
import OSLog

/// The local bridge to the TerrierGPT Companion Chrome extension.
///
/// Launch installs a native-messaging host for the Chromium browsers that are
/// already on this Mac. The host writes handoff files itself. This type is the
/// other direction: when the user captures the front browser tab, ask the
/// companion for the page text, and fall through to AppleScript when the
/// companion is not connected.
///
/// The extension id is pinned by the `key` in the companion manifest. Chrome
/// refuses to start the host for any other id.
nonisolated enum CompanionBridge {

    static let extensionID = "bdppgjcngcpkplhgoaokgbjmifpilaek"
    static let hostName = "com.brianmatute.terriergpt.companion"

    private static let log = Logger(subsystem: "com.brianmatute.TerrierGPTMenu", category: "companion")

    private struct HostTarget {
        let name: String
        /// Folder under ~/Library/Application Support where this browser keeps its profile.
        let supportFolder: String
    }

    /// Names match `BrowserTarget.name`. A browser whose support folder is absent is skipped.
    private static let hostTargets: [HostTarget] = [
        HostTarget(name: "Google Chrome", supportFolder: "Google/Chrome"),
        HostTarget(name: "Google Chrome Beta", supportFolder: "Google/Chrome Beta"),
        HostTarget(name: "Google Chrome Canary", supportFolder: "Google/Chrome Canary"),
        HostTarget(name: "Microsoft Edge", supportFolder: "Microsoft Edge"),
        HostTarget(name: "Microsoft Edge Beta", supportFolder: "Microsoft Edge Beta"),
        HostTarget(name: "Brave Browser", supportFolder: "BraveSoftware/Brave-Browser"),
        HostTarget(name: "Brave Browser Beta", supportFolder: "BraveSoftware/Brave-Browser-Beta"),
        HostTarget(name: "Vivaldi", supportFolder: "Vivaldi"),
        HostTarget(name: "Arc", supportFolder: "Arc/User Data"),
    ]

    private static var supportRoot: URL {
        HandoffStore.directory.deletingLastPathComponent()
    }

    // MARK: - Install

    /// Copies the host into Application Support and registers it with each installed browser.
    static func install() {
        guard let source = scriptSource() else {
            log.error("Companion host script is not in the app")
            return
        }
        let root = supportRoot.appendingPathComponent("native-host", isDirectory: true)
        let script = root.appendingPathComponent("terriergpt-host.py")
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try replace(script, with: Data(source.utf8), mode: 0o644)
            for target in hostTargets {
                let wrapper = root.appendingPathComponent(slug(target.name))
                let text = """
                #!/bin/sh
                export TERRIERGPT_BROWSER='\(target.name)'
                exec /usr/bin/python3 '\(script.path)'
                """
                try replace(wrapper, with: Data(text.utf8), mode: 0o755)
                try installManifest(for: target, executable: wrapper)
            }
        } catch {
            log.error("Companion host install failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Capture

    /// The companion's reading of `target`'s front tab, or nil when the bridge is down.
    static func capture(from target: BrowserTarget) async -> CapturedContext? {
        guard hostTargets.contains(where: { $0.name == target.name }) else { return nil }
        guard hostIsAlive(target.name) else { return nil }

        let id = UUID().uuidString.lowercased()
        let directory = supportRoot.appendingPathComponent("browser-requests", isDirectory: true)
        let requestURL = directory.appendingPathComponent("request.json")
        let responseURL = directory.appendingPathComponent("response-\(id).json")
        defer {
            try? FileManager.default.removeItem(at: requestURL)
            try? FileManager.default.removeItem(at: responseURL)
        }

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: responseURL)
            let request: [String: Any] = [
                "id": id,
                "op": "read-page",
                "browser": target.name,
                "at": Int(Date().timeIntervalSince1970 * 1000),
            ]
            let data = try JSONSerialization.data(withJSONObject: request)
            let temporary = directory.appendingPathComponent(".request-\(id).json")
            try data.write(to: temporary, options: .atomic)
            if FileManager.default.fileExists(atPath: requestURL.path) {
                try FileManager.default.removeItem(at: requestURL)
            }
            try FileManager.default.moveItem(at: temporary, to: requestURL)
        } catch {
            log.error("Companion request was not written: \(error.localizedDescription, privacy: .public)")
            return nil
        }

        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline {
            if let object = readObject(responseURL), object["id"] as? String == id {
                guard object["ok"] as? Bool == true else { return nil }
                return context(from: object, browserName: target.name)
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }

    // MARK: - Files

    private static func hostIsAlive(_ name: String) -> Bool {
        let url = supportRoot
            .appendingPathComponent("native-host/alive", isDirectory: true)
            .appendingPathComponent(slug(name))
        guard let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else {
            return false
        }
        return Date().timeIntervalSince(modified) < 3
    }

    private static func installManifest(for target: HostTarget, executable: URL) throws {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let browserRoot = appSupport.appendingPathComponent(target.supportFolder, isDirectory: true)
        guard FileManager.default.fileExists(atPath: browserRoot.path) else { return }
        let directory = browserRoot.appendingPathComponent("NativeMessagingHosts", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let manifest: [String: Any] = [
            "name": hostName,
            "description": "TerrierGPT Companion bridge",
            "path": executable.path,
            "type": "stdio",
            "allowed_origins": ["chrome-extension://\(extensionID)/"],
        ]
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        let url = directory.appendingPathComponent("\(hostName).json")
        try replace(url, with: data, mode: 0o644)
    }

    private static func replace(_ url: URL, with data: Data, mode: Int) throws {
        if let existing = try? Data(contentsOf: url), existing == data {
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
            return
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).tmp")
        try data.write(to: temporary, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: temporary.path)
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: url)
        }
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }

    private static func scriptSource() -> String? {
        let bundled = [
            Bundle.main.url(forResource: "terriergpt-host", withExtension: "py", subdirectory: "NativeHost"),
            Bundle.main.url(forResource: "terriergpt-host", withExtension: "py"),
        ]
        for url in bundled.compactMap({ $0 }) {
            if let text = try? String(contentsOf: url, encoding: .utf8), text.contains("def main(") {
                return text
            }
        }
        let compiled = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("MyApp/NativeHost/terriergpt-host.py")
        if let text = try? String(contentsOf: compiled, encoding: .utf8), text.contains("def main(") {
            return text
        }
        return nil
    }

    private static func readObject(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func context(from object: [String: Any], browserName: String) -> CapturedContext? {
        let selection = (object["selection"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let body = (object["body"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let text = selection.isEmpty ? body : selection
        guard !text.isEmpty else { return nil }

        let url = URL(string: (object["url"] as? String) ?? "")
        let rawTitle = (object["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let title = rawTitle.isEmpty ? (url?.host ?? "Untitled page") : rawTitle
        let detailField = (object["detail"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let host = (object["host"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let detail = !detailField.isEmpty ? detailField : (!host.isEmpty ? host : url?.host)

        return CapturedContext(
            source: .browser(app: browserName),
            title: title,
            detail: detail,
            url: url,
            body: text
        )
    }

    private static func slug(_ name: String) -> String {
        name.lowercased().replacingOccurrences(of: " ", with: "-")
    }
}
