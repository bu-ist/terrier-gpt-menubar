import AppKit
import Foundation
import OSLog
import SafariServices

/// The native side of TerrierGPT Companion in Safari.
///
/// Chrome starts `terriergpt-host.py` as a native-messaging host. Safari does not start
/// processes: `browser.runtime.sendNativeMessage` arrives here, in this app extension, one
/// request and one reply. This speaks the same two operations as the Python host and writes
/// the same files, so TerrierGPT Menu and CTS Recipes cannot tell which browser sent them:
///
/// - `handoff` writes the envelope to `handoffs/`, updates `latest.json`, drops a copy in
///   `handoffs/inbox/` when CTS Recipes should run it, then announces it with
///   `terriergpt://companion?…` (and `ctsrecipes://inbox`).
/// - `catalog` returns `browser-actions.json`, the Tickets shelf CTS Recipes writes.
///
/// The extension is sandboxed. Its entitlements allow exactly one folder outside the
/// container: `~/Library/Application Support/TerrierGPTMenu/`.
final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {

    private static let log = Logger(subsystem: "com.brianmatute.TerrierGPTMenu.Companion", category: "safari")

    private static let maxText = 180_000
    private static let answerContract = "terriergpt-answer"
    private static let safeContract = try! NSRegularExpression(pattern: "^[a-z0-9][a-z0-9-]{0,63}$")
    private static let fence = try! NSRegularExpression(pattern: "```(?:json)?\\s*([\\s\\S]*?)```", options: [.caseInsensitive])

    func beginRequest(with context: NSExtensionContext) {
        let item = context.inputItems.first as? NSExtensionItem
        let message = item?.userInfo?[SFExtensionMessageKey] as? [String: Any] ?? [:]
        let reply = Self.handle(message)

        let response = NSExtensionItem()
        response.userInfo = [SFExtensionMessageKey: reply]
        context.completeRequest(returningItems: [response], completionHandler: nil)
    }

    // MARK: - Operations

    static func handle(_ message: [String: Any]) -> [String: Any] {
        let id = message["id"] as? String
        switch message["op"] as? String {
        case "handoff":
            return handoff(message, id: id)
        case "catalog":
            return catalog(id: id)
        case "hello":
            return ["ok": true, "op": "hello", "host": 1, "browser": "Safari"]
        default:
            return ["ok": false, "id": json(id), "reason": "unknown-op"]
        }
    }

    private static func handoff(_ message: [String: Any], id: String?) -> [String: Any] {
        var text = (message["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return ["ok": false, "op": "handoff", "id": json(id), "reason": "empty"] }
        let truncated = text.count > maxText
        if truncated { text = String(text.prefix(maxText)) }
        let title = String((message["title"] as? String ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(300))
        let url = String((message["url"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(2000))
        let wake = message["wake"] as? Bool == true

        let now = Date()
        let (body, contract) = envelope(text: text, title: title, url: url, now: now)
        let handoffs = supportDirectory.appendingPathComponent("handoffs", isDirectory: true)
        let filename = "\(fileStamp(now))-\(contract).json"
        let path = handoffs.appendingPathComponent(filename)

        var inboxPath: String?
        do {
            try writeJSON(body, to: path)
            try writeJSON(body, to: handoffs.appendingPathComponent("latest.json"))
            if wake {
                var dropped = body
                dropped["hops"] = 0
                let inbox = handoffs.appendingPathComponent("inbox", isDirectory: true)
                let file = inbox.appendingPathComponent(filename)
                try writeJSON(dropped, to: file)
                inboxPath = file.path
            }
        } catch {
            log.error("Handoff was not written: \(error.localizedDescription, privacy: .public)")
            return ["ok": false, "op": "handoff", "id": json(id), "reason": "bridge-failed"]
        }

        if wake { announce("ctsrecipes://inbox") }
        var components = URLComponents()
        components.scheme = "terriergpt"
        components.host = "companion"
        components.queryItems = [
            URLQueryItem(name: "recipes", value: wake ? "1" : "0"),
            URLQueryItem(name: "title", value: String(title.prefix(120))),
        ]
        if let announcement = components.url?.absoluteString { announce(announcement) }

        return [
            "ok": true,
            "op": "handoff",
            "id": json(id),
            "contract": contract,
            "path": path.path,
            "inbox": json(inboxPath),
            "truncated": truncated,
        ]
    }

    private static func catalog(id: String?) -> [String: Any] {
        let url = supportDirectory.appendingPathComponent("browser-actions.json")
        guard
            let data = try? Data(contentsOf: url),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            object["actions"] is [Any]
        else {
            return ["ok": false, "op": "catalog", "id": json(id), "reason": "no-catalog"]
        }
        return ["ok": true, "op": "catalog", "id": json(id), "catalog": object]
    }

    /// A reply goes back to JavaScript, so a missing value is `null`, never a boxed Optional.
    private static func json(_ value: String?) -> Any { value ?? NSNull() }

    // MARK: - Envelope (mirrors terriergpt-host.py)

    private static func envelope(text: String, title: String, url: String, now: Date) -> ([String: Any], String) {
        var payload = fencedPayload(text) ?? fallbackPayload(text: text, title: title)
        var contract = payload["contract"] as? String ?? ""
        if !isSafe(contract) {
            payload = fallbackPayload(text: text, title: title)
            contract = answerContract
        }
        var source: [String: Any] = ["agent": "terriergpt", "extracted_from": "safari-companion"]
        if !url.isEmpty { source["url"] = url }
        if !title.isEmpty { source["title"] = title }
        let body: [String: Any] = [
            "contract": contract,
            "created_at": iso(now),
            "handoff": 1,
            "id": UUID().uuidString.lowercased(),
            "payload": payload,
            "source": source,
            "text": text,
            "validation": [
                "issues": ["Written by the Safari companion extension."],
                "schema": NSNull(),
                "status": "unchecked",
            ] as [String: Any],
        ]
        return (body, contract)
    }

    /// The last fenced JSON object in the answer that names a usable contract.
    private static func fencedPayload(_ text: String) -> [String: Any]? {
        let range = NSRange(text.startIndex..., in: text)
        var found: [String: Any]?
        for match in fence.matches(in: text, range: range) {
            guard let inner = Range(match.range(at: 1), in: text),
                  let data = String(text[inner]).trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let contract = object["contract"] as? String, isSafe(contract)
            else { continue }
            found = object
        }
        return found
    }

    private static func fallbackPayload(text: String, title: String) -> [String: Any] {
        var payload: [String: Any] = [
            "answer": text,
            "contract": answerContract,
            "generated_by": "app-fallback",
            "version": 1,
        ]
        if !title.isEmpty { payload["title"] = title }
        return payload
    }

    private static func isSafe(_ contract: String) -> Bool {
        safeContract.firstMatch(in: contract, range: NSRange(contract.startIndex..., in: contract)) != nil
    }

    // MARK: - Files and URLs

    /// `~/Library/Application Support/TerrierGPTMenu`, in the user's real home rather than
    /// this extension's container. The sandbox exception covers exactly this folder.
    static var supportDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["TERRIERGPT_SUPPORT"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let home = getpwuid(getuid()).flatMap { String(validatingCString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
        return URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent("Library/Application Support/TerrierGPTMenu", isDirectory: true)
    }

    private static func writeJSON(_ object: [String: Any], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let options: JSONSerialization.WritingOptions = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try JSONSerialization.data(withJSONObject: object, options: options)
        try data.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Only the two announcements the Python host may open. The body never rides in a URL.
    private static func announce(_ string: String) {
        guard string.hasPrefix("terriergpt://companion?") || string == "ctsrecipes://inbox",
              let url = URL(string: string) else { return }
        // Tests record the URL instead of opening it.
        if let log = ProcessInfo.processInfo.environment["TERRIERGPT_ANNOUNCE_LOG"], !log.isEmpty {
            let line = Data((string + "\n").utf8)
            if let handle = FileHandle(forWritingAtPath: log) {
                handle.seekToEndOfFile()
                handle.write(line)
                try? handle.close()
            } else {
                FileManager.default.createFile(atPath: log, contents: line)
            }
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.open(url, configuration: configuration) { _, error in
            if let error { log.error("Could not open \(string, privacy: .public): \(error.localizedDescription, privacy: .public)") }
        }
    }

    private static func fileStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss'Z'"
        return formatter.string(from: date)
    }

    private static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}
