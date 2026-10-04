import Foundation

/// The built-in recipe catalog: the working group's documented skill chains
/// (`cts-ai-working-group/docs/orchestration`, `skills/cts-orchestrate`) as runnable recipes.
///
/// Mac recipes call the personal overlay's `run-*.sh` wrappers (BU-CTS-RKC), which load
/// `config.env` and then the WG starter — so analyst names and mailboxes stay out of the app,
/// exactly as the WG asks. Running them *from the app* also fixes what launchd couldn't: a
/// bare `/bin/bash` started by launchd isn't allowed into ~/Documents, the app is.
///
/// Advice follows the WG's surface table: route each step to the surface that can see the
/// data. TerrierGPT model names come from `terriergpt/README.md`.
nonisolated enum RecipeCatalog {

    static let version = 3

    static let examples: [RecipeStore.Example] = [
        // MARK: Daily
        .init(name: "morning-desk", since: version, json: """
        {
          "title": "Morning desk",
          "description": "Pulls overnight ServiceNow mail into your ticket store, then one brief: today's calendar, tickets that need your move, and who you'll see.",
          "category": "Daily",
          "icon": "sunrise.fill",
          "skills": ["ticket-digest", "ticket-hygiene", "who", "cts-daily-brief"],
          "advice": {
            "place": "mac",
            "model": "Claude Sonnet 5.5",
            "effort": "medium",
            "why": "Your Mac is the only place that can read Mail.app's ServiceNow notifications. Headless runs can't approve calendar access, so finish in Claude, where the M365 connector can ask.",
            "then": "claude"
          },
          "prompt": "Finish my morning desk with cts-daily-brief: add today's calendar and who I'll see, using the Microsoft 365 connector. The ticket part from my ticket-digest store is in the result below. Read-only: don't send, draft, or update anything.",
          "schedule": { "weekdays": [1, 2, 3, 4, 5], "time": "08:00" },
          "shortcut": "CTS Morning Desk",
          "stopsBefore": "replying to anyone",
          "input": { "from": "none" },
          "steps": [
            { "id": "brief", "agent": "command", "command": ["/bin/bash", "~/Documents/GitHub/BU-CTS-RKC/scripts/run-morning-desk.sh"], "timeout": 1800 }
          ]
        }
        """),
        .init(name: "eod-desk", since: version, json: """
        {
          "title": "End of day",
          "description": "What got done, what's waiting on a reply, what carries into tomorrow — from today's mail, Teams, and calendar.",
          "category": "Daily",
          "icon": "sunset.fill",
          "skills": ["end-of-day-wrap-up"],
          "advice": {
            "place": "mac",
            "model": "Claude Sonnet 5.5",
            "effort": "low",
            "why": "A read-only recap of mail, Teams, and calendar. Headless runs can't approve M365 access, so continue in Claude, where the connector can ask.",
            "then": "claude"
          },
          "prompt": "Run end-of-day-wrap-up for today using the Microsoft 365 connector (mail, Sent Items, Teams, calendar). Read-only: don't send, draft, or mark anything done.",
          "schedule": { "weekdays": [1, 2, 3, 4, 5], "time": "16:30" },
          "shortcut": "CTS End of Day",
          "stopsBefore": "marking anything done",
          "input": { "from": "none" },
          "steps": [
            { "id": "wrap-up", "agent": "command", "cwd": "~/Claude/ticket-digest", "command": ["/bin/bash", "~/Documents/GitHub/BU-CTS-RKC/scripts/run-eod-desk.sh"], "timeout": 1200 }
          ]
        }
        """),

        // MARK: Weekly
        .init(name: "tuesday-redalert", since: version, json: """
        {
          "title": "Tuesday RedAlert",
          "description": "Ingests the TECTools export, builds the update / upgrade / missing / refresh cohorts, checks for open INCs, and refreshes your career snapshot.",
          "category": "Weekly",
          "icon": "exclamationmark.shield.fill",
          "skills": ["red-alert-weekly", "fleet-chase", "ticket-hygiene", "career-snapshot"],
          "advice": {
            "place": "mac",
            "model": "Claude Opus 5.5",
            "effort": "high",
            "why": "The engine is local Python on the cssr@bu.edu export. Use high effort for the cohort drafts: they go to real clients.",
            "then": "claude"
          },
          "schedule": { "weekdays": [2], "time": "09:00" },
          "shortcut": "CTS Tuesday Desk",
          "stopsBefore": "any client email or ticket — you approve each cohort",
          "input": { "from": "none" },
          "steps": [
            { "id": "ingest", "agent": "command", "command": ["/bin/bash", "~/Documents/GitHub/BU-CTS-RKC/scripts/run-tuesday-desk.sh"], "timeout": 2400 }
          ]
        }
        """),
        .init(name: "pattern-to-kb", since: version, json: """
        {
          "title": "Patterns → KB gaps",
          "description": "Finds repeat issues in your ticket store, checks the KB for each one, and drafts articles only for real gaps.",
          "category": "Knowledge",
          "icon": "chart.bar.doc.horizontal.fill",
          "skills": ["ticket-pattern-analyzer", "kb-gap-check", "draft-kb"],
          "advice": {
            "place": "mac",
            "model": "Claude Sonnet 5.5",
            "effort": "medium",
            "why": "The analyzer is offline Python on your ticket store; gap-check needs ServiceNow. A monthly pass is enough."
          },
          "schedule": { "weekdays": [1], "time": "09:15" },
          "shortcut": "CTS Pattern to KB",
          "stopsBefore": "publishing",
          "input": { "from": "none" },
          "steps": [
            { "id": "patterns", "agent": "command", "command": ["/bin/bash", "~/Documents/GitHub/BU-CTS-RKC/scripts/run-pattern-to-kb.sh"], "timeout": 1800 }
          ]
        }
        """),

        // MARK: Knowledge
        .init(name: "resolved-to-kb", since: version, json: """
        {
          "title": "Resolved ticket → KB",
          "description": "Documents your newest fix, flags KB candidates, checks for an existing article, and drafts KB-ready HTML for the gaps.",
          "category": "Knowledge",
          "icon": "book.pages.fill",
          "skills": ["log-triage", "kb-gap-check", "draft-kb"],
          "advice": {
            "place": "mac",
            "model": "Claude Sonnet 5.5",
            "effort": "medium",
            "why": "log-triage writes to your local ticket store. Run it right after you resolve, while the work notes are fresh."
          },
          "shortcut": "CTS Resolved to KB",
          "stopsBefore": "publishing",
          "input": { "from": "none" },
          "steps": [
            { "id": "resolved", "agent": "command", "command": ["/bin/bash", "~/Documents/GitHub/BU-CTS-RKC/scripts/run-resolved-to-kb.sh"], "timeout": 1800 }
          ]
        }
        """),
        .init(name: "kb-desk-handoff", since: version, replaces: RecipeStore.legacyKBDesk, json: """
        {
          "title": "KB Desk → draft → review",
          "description": "Ask TerrierGPT's KB Desk whether an article exists, then Claude drafts the gaps and Grok gives a second opinion.",
          "category": "Knowledge",
          "icon": "text.book.closed.fill",
          "skills": ["kb-retrieve", "kb-gap-check", "draft-kb", "review"],
          "advice": {
            "place": "terriergpt",
            "agent": "KB Desk (Test)",
            "model": "tool-calling model",
            "why": "Only the KB Desk can search kb_knowledge from TerrierGPT. Ask there first, then run the chain on its answer.",
            "then": "claude"
          },
          "instance": "nonprod",
          "prompt": "Check whether the CTS knowledge base already covers these topics. For each one, retrieve matching kb_knowledge articles and classify it as current, outdated, or a gap. End with the kb-gap-verdict JSON block.\\n\\nTopics:\\n- ",
          "shortcut": "CTS KB Desk Handoff",
          "stopsBefore": "publishing",
          "input": { "from": "page", "contract": "kb-gap-verdict" },
          "steps": [
            {
              "id": "draft",
              "agent": "claude",
              "cwd": "~/Documents/GitHub/cts-ai-working-group",
              "prompt": "/cts-orchestrate kb-desk-handoff\\n\\nThe kb-gap-verdict handoff envelope is on stdin (also saved at {{input_path}}). Search KB Draft/ first, then draft-kb only for Gap rows. Return the drafts. Do not publish anything.",
              "allow": ["Read", "Grep", "Glob", "Skill"],
              "timeout": 900
            },
            {
              "id": "review",
              "agent": "grok",
              "confirm": "Send Claude's drafts to Grok for a second-opinion review?",
              "prompt": "You are reviewing BU IT knowledge-base drafts produced by another agent. Check accuracy, missing steps, and tone for end users. Reply with a short list of concrete fixes per draft."
            }
          ]
        }
        """),

        // MARK: Tickets
        .init(name: "ticket-search-html", since: version, replaces: RecipeStore.legacyTicketSearch, json: """
        {
          "title": "Ticket search → HTML report",
          "description": "TerrierGPT's Ticket Search Desk finds the tickets; the app turns its report into the Keep / Check / Remove HTML in Downloads.",
          "category": "Tickets",
          "icon": "magnifyingglass.circle.fill",
          "skills": ["ticket-search-retrieve", "ticket-search-report", "servicenow-search-report"],
          "advice": {
            "place": "terriergpt",
            "agent": "Ticket Search Desk (Test)",
            "model": "tool-calling model",
            "why": "BU-Nexus search only exists on the Test instance. The HTML step is a local script and needs no AI."
          },
          "instance": "nonprod",
          "prompt": "Search ServiceNow for tickets matching the terms below and classify each hit as Keep, Check, or Remove. End with the ticket-search-report JSON block.\\n\\nTerms:\\n- ",
          "shortcut": "CTS Ticket Search Claude",
          "stopsBefore": "writing anything to ServiceNow",
          "input": { "from": "page", "contract": "ticket-search-report" },
          "steps": [
            {
              "id": "fill-html",
              "agent": "command",
              "command": ["/usr/bin/python3", "~/Documents/GitHub/cts-ai-working-group/docs/orchestration/examples/handoff-ticket-search.py", "--file", "{{input_path}}"],
              "timeout": 120
            }
          ]
        }
        """),
        .init(name: "triage-and-reply", since: version, json: """
        {
          "title": "Triage → reply or escalate",
          "description": "Capture the ticket page, get a triage, then a plain-language reply for the client and, if it belongs elsewhere, an escalation note for the right group.",
          "category": "Tickets",
          "icon": "arrow.triangle.branch",
          "skills": ["triage", "escalate"],
          "advice": {
            "place": "terriergpt",
            "agent": "IT Support Email Drafter",
            "model": "Sonnet 4.6",
            "why": "Pure reasoning on what you paste — TerrierGPT handles it well and keeps ticket data on BU's platform. Hand off to Claude only if you want it to update ServiceNow for you.",
            "then": "claude"
          },
          "prompt": "Triage the ServiceNow ticket in the context below: what's wrong, what's missing, and whether it stays with CTS. Then draft (1) a plain-language reply to the client and (2) if it should move, a tech-to-tech escalation note naming the assignment group and what they need. Drafts only.",
          "stopsBefore": "sending or assigning"
        }
        """),
        .init(name: "isar-review", since: version, json: """
        {
          "title": "HIPAA ISAR review",
          "description": "Sweeps the HIPAA asset group in InsightVM for vulnerabilities past 60 days and builds the per-device ticket worklist.",
          "category": "Tickets",
          "icon": "cross.case.fill",
          "skills": ["isar-device-review", "servicenow-file"],
          "advice": {
            "place": "mac",
            "model": "Claude Opus 5.5",
            "effort": "high",
            "why": "Long, exacting compliance work over InsightVM and ServiceNow. Worth the strongest model, and never on a timer."
          },
          "shortcut": "CTS HIPAA",
          "stopsBefore": "Submit in ServiceNow",
          "input": { "from": "none" },
          "steps": [
            {
              "id": "worklist",
              "agent": "command",
              "confirm": "Start the ISAR sweep? It reads InsightVM and prepares ServiceNow fields, but never submits.",
              "command": ["/bin/bash", "~/Documents/GitHub/BU-CTS-RKC/scripts/run-isar-dry-run.sh"],
              "timeout": 3600
            }
          ]
        }
        """),
        .init(name: "incident-recap", since: version, json: """
        {
          "title": "Post-incident recap",
          "description": "A P1/P2 postmortem from the bridge mail: timeline, impact, root cause, follow-ups.",
          "category": "Tickets",
          "icon": "flame.fill",
          "skills": ["post-incident-recap", "kb-article-drafter"],
          "advice": {
            "place": "terriergpt",
            "agent": "Post-Incident Recap",
            "model": "Sonnet 4.6",
            "why": "Paste or capture the thread; TerrierGPT's recap agent has the template. If the thread lives in Outlook, Copilot can pull it for you first.",
            "then": "claude"
          },
          "prompt": "Write a post-incident recap from the thread in the context below. Sections: Summary, Timeline (with times), Impact, Root cause, Follow-ups (owner, due). Flag anything the thread doesn't actually say instead of guessing.",
          "stopsBefore": "sending or closing the incident"
        }
        """),

        // MARK: Career
        .init(name: "career-g2", since: version, json: """
        {
          "title": "Career snapshot → self-review",
          "description": "Rolls your RedAlert history into this review year's numbers, then drafts the self-assessment around your goals.",
          "category": "Career",
          "icon": "star.circle.fill",
          "skills": ["career-snapshot", "annual-review-prep"],
          "advice": {
            "place": "mac",
            "why": "The numbers come from a local script. The writing needs your goals and judgement: take it to Claude, Opus with high effort.",
            "then": "claude"
          },
          "prompt": "Using the RedAlert career snapshot below as evidence, draft my self-assessment under BU's Chart Your Career framework. Ask me for my goals for this review period before you write anything.",
          "stopsBefore": "submitting anything",
          "input": { "from": "none" },
          "steps": [
            {
              "id": "snapshot",
              "agent": "command",
              "command": ["/bin/bash", "-c", "set -a; source ~/Documents/GitHub/BU-CTS-RKC/config.env; set +a; exec /bin/bash ~/Documents/GitHub/cts-ai-working-group/docs/orchestration/examples/career-g2.sh"],
              "timeout": 600
            }
          ]
        }
        """),

        // MARK: Hosts
        .init(name: "ubuntu-host", since: version, json: """
        {
          "title": "Ubuntu lab host build",
          "description": "Joins a BU Ubuntu machine to AD, installs CrowdStrike, then Rapid7 — stopping at the first failure.",
          "category": "Hosts",
          "icon": "server.rack",
          "skills": ["ubuntu-ad-join", "crowdstrike-ubuntu-install", "rapid7-linux-install"],
          "advice": {
            "place": "claude",
            "model": "Claude Sonnet 5.5",
            "effort": "medium",
            "why": "Runs on the Ubuntu host with sudo, not on this Mac. Open Claude Code on that machine and paste the handoff."
          },
          "prompt": "/cts-orchestrate ubuntu-host — on this Ubuntu machine run ubuntu-ad-join, then crowdstrike-ubuntu-install, then rapid7-linux-install. Stop at the first failure and tell me what to fix. Ask before each sudo step.",
          "stopsBefore": "each sudo step"
        }
        """),
    ]
}
