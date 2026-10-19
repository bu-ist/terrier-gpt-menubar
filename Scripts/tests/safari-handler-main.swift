// Drives SafariWebExtensionHandler.handle(_:) outside Safari.
// Built and run by Scripts/tests/test-safari-handler.sh.
import Foundation

func reply(_ message: [String: Any]) -> [String: Any] {
    SafariWebExtensionHandler.handle(message)
}

var failures = 0
func check(_ name: String, _ ok: Bool) {
    print("\(ok ? "ok  " : "FAIL")  \(name)")
    if !ok { failures += 1 }
}

let root = SafariWebExtensionHandler.supportDirectory
let handoffs = root.appendingPathComponent("handoffs")

let missing = reply(["op": "catalog", "id": "c1"])
check("no catalog file is no-catalog", missing["ok"] as? Bool == false && missing["reason"] as? String == "no-catalog")

let catalog = ["actions": [["id": "triage", "label": "Triage", "prompt": "SECRET-PROMPT", "page_match": "ticket"]]]
try! JSONSerialization.data(withJSONObject: catalog).write(to: root.appendingPathComponent("browser-actions.json"))
let served = reply(["op": "catalog", "id": "c2"])
let actions = (served["catalog"] as? [String: Any])?["actions"] as? [[String: Any]]
check("the catalog CTS Recipes wrote is served", served["ok"] as? Bool == true && actions?.first?["id"] as? String == "triage")

let empty = reply(["op": "handoff", "id": "h0", "text": "   "])
check("an empty handoff is refused", empty["ok"] as? Bool == false && empty["reason"] as? String == "empty")

let plain = reply(["op": "handoff", "id": "h1", "text": "The printer needs firmware.", "title": "INC0012345  Printer", "url": "https://bu.service-now.com/x"])
check("a plain answer is saved", plain["ok"] as? Bool == true && plain["contract"] as? String == "terriergpt-answer")
let saved = try! JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: plain["path"] as! String))) as! [String: Any]
let latest = try! JSONSerialization.jsonObject(with: Data(contentsOf: handoffs.appendingPathComponent("latest.json"))) as! [String: Any]
check("latest.json is the same envelope", latest["id"] as? String == saved["id"] as? String)
check("the envelope says Safari wrote it", (saved["source"] as? [String: Any])?["extracted_from"] as? String == "safari-companion")
check("the title is collapsed", (saved["source"] as? [String: Any])?["title"] as? String == "INC0012345 Printer")
check("the filename is stamped and typed", (plain["path"] as! String).hasSuffix("Z-terriergpt-answer.json"))
check("no inbox copy without wake", plain["inbox"] is NSNull || plain["inbox"] == nil)

let fenced = "Here it is.\n```json\n{\"contract\": \"kb-gap-verdict\", \"version\": 1, \"verdict\": \"gap\"}\n```"
let woke = reply(["op": "handoff", "id": "h2", "text": fenced, "wake": true])
check("a fenced contract is passed through", woke["contract"] as? String == "kb-gap-verdict")
let inboxPath = woke["inbox"] as? String ?? ""
let dropped = (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: inboxPath)))) as? [String: Any]
check("wake drops a copy in the inbox with hops 0", dropped?["hops"] as? Int == 0)

let unsafe = "```json\n{\"contract\": \"../../etc\", \"x\": 1}\n```"
let refused = reply(["op": "handoff", "id": "h3", "text": unsafe])
check("an unsafe contract name falls back", refused["contract"] as? String == "terriergpt-answer")

let announced = (try? String(contentsOfFile: ProcessInfo.processInfo.environment["TERRIERGPT_ANNOUNCE_LOG"]!, encoding: .utf8)) ?? ""
check("the menu is told about each handoff", announced.components(separatedBy: "terriergpt://companion?").count - 1 == 3)
check("CTS Recipes is woken once", announced.components(separatedBy: "ctsrecipes://inbox").count - 1 == 1)
check("no answer text rides in a URL", !announced.contains("firmware") && !announced.contains("verdict"))
check("no catalog prompt rides in a URL", !announced.contains("SECRET-PROMPT"))

let unknown = reply(["op": "launch-missiles"])
check("an unknown op is refused", unknown["ok"] as? Bool == false)

print(failures == 0 ? "\nAll Safari handler tests passed." : "\n\(failures) failing.")
exit(failures == 0 ? 0 : 1)
