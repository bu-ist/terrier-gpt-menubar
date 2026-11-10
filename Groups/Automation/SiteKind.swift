import Foundation

/// What kind of campus tool a captured URL points at.
///
/// Used only to label chips and suggest an instruction — never to write to the site.
/// ServiceNow writes stay in the Companion; TecTools actions stay in CTS Recipes / skills.
nonisolated enum SiteKind: String, Equatable, Hashable {
    case serviceNow
    case tecTools
    case generic

    var chipDetailPrefix: String? {
        switch self {
        case .serviceNow: return "ServiceNow"
        case .tecTools: return "TECTools"
        case .generic: return nil
        }
    }

    /// A ready-made instruction the Capture flow can offer when this site is detected.
    var suggestedInstruction: String? {
        switch self {
        case .serviceNow:
            return "Triage this ServiceNow ticket. Lead with what it is and whose move it is, then the next action."
        case .tecTools:
            return "Summarize this TECTools / RedAlert view for a CTS follow-up. Call out risk, owner, and the next chase step."
        case .generic:
            return nil
        }
    }

    static func detect(url: URL?) -> SiteKind {
        guard let host = url?.host?.lowercased() else { return .generic }
        if host.contains("service-now.com") || host.contains("servicenow") {
            return .serviceNow
        }
        // TECTools hosts vary; match common naming and the RedAlert / CSSReport lineage.
        if host.contains("tectools")
            || host.contains("tec-tools")
            || host.contains("cssreport")
            || host.contains("kace-lite")
            || host.contains("teccat") {
            return .tecTools
        }
        return .generic
    }

    /// Pulls an INC / RITM / SCTASK / CHG / KB / PRB number out of free text.
    static func ticketNumber(in text: String) -> TicketRef? {
        TicketRef.parse(text)
    }
}

/// A ServiceNow-style record number the app can open in the browser.
nonisolated struct TicketRef: Equatable, Hashable {
    enum Kind: String {
        case incident = "INC"
        case requestedItem = "RITM"
        case catalogTask = "SCTASK"
        case change = "CHG"
        case problem = "PRB"
        case knowledge = "KB"

        var tablePath: String {
            switch self {
            case .incident: return "incident.do"
            case .requestedItem: return "sc_req_item.do"
            case .catalogTask: return "sc_task.do"
            case .change: return "change_request.do"
            case .problem: return "problem.do"
            case .knowledge: return "kb_view.do"
            }
        }
    }

    let kind: Kind
    let number: String

    var display: String { number }

    /// Production BU ServiceNow — the default for day-to-day CTS work.
    static let productionHost = "bu.service-now.com"

    /// Opens the record in the default browser. Knowledge uses `sysparm_article`; the rest use a number query.
    func openURL(host: String = productionHost) -> URL {
        if kind == .knowledge {
            var components = URLComponents()
            components.scheme = "https"
            components.host = host
            components.path = "/kb_view.do"
            components.queryItems = [URLQueryItem(name: "sysparm_article", value: number)]
            return components.url!
        }
        let uri = "/\(kind.tablePath)?sysparm_query=number=\(number)"
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/nav_to.do"
        components.queryItems = [URLQueryItem(name: "uri", value: uri)]
        return components.url!
    }

    static func parse(_ text: String) -> TicketRef? {
        let pattern = #"\b((?:INC|RITM|SCTASK|CHG|PRB|KB)\d{4,})\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              let numberRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        let raw = String(text[numberRange]).uppercased()
        let kind: Kind
        if raw.hasPrefix("SCTASK") { kind = .catalogTask }
        else if raw.hasPrefix("RITM") { kind = .requestedItem }
        else if raw.hasPrefix("INC") { kind = .incident }
        else if raw.hasPrefix("CHG") { kind = .change }
        else if raw.hasPrefix("PRB") { kind = .problem }
        else if raw.hasPrefix("KB") { kind = .knowledge }
        else { return nil }
        return TicketRef(kind: kind, number: raw)
    }
}
