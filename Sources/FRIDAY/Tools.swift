import AppKit
import CryptoKit
import Foundation

struct ToolResult {
    let text: String          // what the model (or MCP client) sees
    var note: String? = nil   // short line shown under the reply in F.R.I.D.A.Y AI
    var icons: [String] = []  // paths of the apps the note is about, shown as their icons
    var contacts: [ContactCard] = []   // shown as contact cards in the chat
    var map: MapPreview? = nil         // shown as an interactive dark map in the chat
    var widget: Widget? = nil          // weather / clock / dictionary card
}

/// A status line under a chat reply, e.g. "Opened Xcode" with Xcode's icon.
struct ChatNote: Hashable, Codable {
    let text: String
    var icons: [String] = []
    var contacts: [ContactCard] = []
    var map: MapPreview?
    var widget: Widget?

    init(text: String, icons: [String] = [], contacts: [ContactCard] = [], map: MapPreview? = nil, widget: Widget? = nil) {
        self.text = text; self.icons = icons; self.contacts = contacts; self.map = map; self.widget = widget
    }

    init(from d: Decoder) throws {   // tolerant: older saved chats lack newer keys
        let c = try d.container(keyedBy: CodingKeys.self)
        text = try c.decode(String.self, forKey: .text)
        icons = try c.decodeIfPresent([String].self, forKey: .icons) ?? []
        contacts = try c.decodeIfPresent([ContactCard].self, forKey: .contacts) ?? []
        map = try c.decodeIfPresent(MapPreview.self, forKey: .map)
        widget = try c.decodeIfPresent(Widget.self, forKey: .widget)
    }
}

/// One tool, defined once and exposed two ways: OpenAI-style function calling (F.R.I.D.A.Y AI)
/// and the Model Context Protocol (`FRIDAY --mcp`).
struct Tool {
    let name: String
    let description: String
    let properties: [String: Any]
    let required: [String]
    let run: @MainActor ([String: Any]) async -> ToolResult

    var schema: [String: Any] { ["type": "object", "properties": properties, "required": required] }
    var openAI: [String: Any] { ["type": "function", "function": ["name": name, "description": description, "parameters": schema]] }
    var mcp: [String: Any] { ["name": name, "description": description, "inputSchema": schema] }
}

// MARK: - Modes: a named recipe for a work setup, stored in ~/Documents/Me/modes.json
//
// A mode can be as simple as a few apps, or a detailed recipe made of named parts, each with steps:
//   terminal step: a Terminal window that cd's into `path` and runs `command`
//   open step:     open `app` (optionally on a `path`, e.g. VS Code on a project folder)
// `rules` is free text describing which parts to use when ("web -> next + django, otherwise flutter + django").

struct Step: Codable {
    var type: String?       // "terminal" | "open"
    var app: String?
    var path: String?
    var command: String?
    var isTerminal: Bool { type == "terminal" || (type == nil && app == nil) }
}

struct Part: Codable {
    var name: String
    var steps: [Step] = []
}

struct AppMode: Codable {
    var name: String
    var apps: [String] = []
    var parts: [Part] = []
    var rules: String = ""

    init(name: String, apps: [String] = [], parts: [Part] = [], rules: String = "") {
        self.name = name; self.apps = apps; self.parts = parts; self.rules = rules
    }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        apps = try c.decodeIfPresent([String].self, forKey: .apps) ?? []
        parts = try c.decodeIfPresent([Part].self, forKey: .parts) ?? []
        rules = try c.decodeIfPresent(String.self, forKey: .rules) ?? ""
    }
}

enum Modes {
    private static var file: URL { Memory.folder.appendingPathComponent("modes.json") }

    static func load() -> [AppMode] {
        guard let d = try? Data(contentsOf: file), let m = try? JSONDecoder().decode([AppMode].self, from: d) else { return [] }
        return m
    }

    static func save(_ modes: [AppMode]) {
        try? FileManager.default.createDirectory(at: Memory.folder, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(modes) { try? d.write(to: file, options: .atomic) }
    }

    static func find(_ name: String) -> AppMode? {
        let q = name.lowercased().trimmingCharacters(in: .whitespaces)
        let all = load()
        return all.first { $0.name.lowercased() == q }
            ?? all.first { $0.name.lowercased().contains(q) || q.contains($0.name.lowercased()) }
    }

    /// Full recipes as compact JSON, for the system prompt (so the model can edit them faithfully).
    static func summary() -> String {
        let m = load()
        guard !m.isEmpty else { return "(none saved yet)" }
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        return m.compactMap { (try? enc.encode($0)).flatMap { String(data: $0, encoding: .utf8) } }.joined(separator: "\n")
    }
}

// MARK: - Tool implementations

enum Tools {
    static func strings(_ v: Any?) -> [String] {
        if let a = v as? [String] { return a }
        if let s = v as? String { return s.split(whereSeparator: { $0 == "," || $0 == "\n" }).map { $0.trimmingCharacters(in: .whitespaces) } }
        return []
    }

    private static func resolve(_ name: String) -> AppEntry? {
        let index = AppIndex.shared
        index.loadIfNeeded()
        let q = name.lowercased().replacingOccurrences(of: ".app", with: "").trimmingCharacters(in: .whitespaces)
        return index.apps.compactMap { a in AppIndex.score(q, a).map { ($0, a) } }
            .filter { $0.0 >= 55 }
            .max { ($0.0, -$0.1.name.count) < ($1.0, -$1.1.name.count) }?.1
    }

    private static func launch(_ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = args
        return (try? p.run()) != nil
    }

    /// Opens apps; returns (opened canonical names, names that couldn't be found, their paths).
    private static func open(_ names: [String]) -> (opened: [String], missing: [String], paths: [String]) {
        var opened: [String] = [], missing: [String] = [], paths: [String] = []
        for n in names {
            if let app = resolve(n), launch([app.url.path]) { opened.append(app.name); paths.append(app.url.path) } else { missing.append(n) }
        }
        return (opened, missing, paths)
    }

    private static func report(_ r: (opened: [String], missing: [String], paths: [String])) -> ToolResult {
        var text = r.opened.isEmpty ? "Opened nothing." : "Opened: \(r.opened.joined(separator: ", "))."
        if !r.missing.isEmpty { text += " Not found: \(r.missing.joined(separator: ", "))." }
        return ToolResult(text: text, note: r.opened.isEmpty ? nil : "Opened \(r.opened.joined(separator: ", "))", icons: r.paths)
    }

    // MARK: steps

    private static func expand(_ p: String) -> String {
        let s = p.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("~") { return (s as NSString).expandingTildeInPath }
        return s.hasPrefix("/") ? s : NSHomeDirectory() + "/" + s    // relative paths live under the home folder
    }

    private static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    private static func runAppleScript(_ src: String) -> String? {
        var err: NSDictionary?
        NSAppleScript(source: src)?.executeAndReturnError(&err)
        return err?[NSAppleScript.errorMessage] as? String
    }

    /// Runs one step; returns a human-readable line and the app icon path involved.
    private static func run(_ step: Step) -> (line: String, icon: String?) {
        if step.isTerminal {
            var cmd = ""
            var warn = ""
            if let p = step.path, !p.isEmpty {
                let full = expand(p)
                if FileManager.default.fileExists(atPath: full) { cmd = "cd \(shellQuote(full))" } else { warn = " (folder \(p) not found, ran without it)" }
            }
            if let c = step.command, !c.isEmpty { cmd += cmd.isEmpty ? c : " && \(c)" }
            let escaped = cmd.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            let script = "tell application \"Terminal\"\nactivate\ndo script \"\(escaped)\"\nend tell"
            let label = "Terminal" + (step.path.map { " in \($0)" } ?? "") + (step.command.map { ": \($0)" } ?? "")
            if let e = runAppleScript(script) { return ("Failed \(label) — \(e)", nil) }
            return ("Opened \(label)\(warn)", "/System/Applications/Utilities/Terminal.app")
        }

        let appName = step.app ?? ""
        guard let app = resolve(appName) else { return ("Couldn't find app '\(appName)'", nil) }
        var args = ["-a", app.url.path]
        var suffix = ""
        if let p = step.path, !p.isEmpty {
            let full = expand(p)
            if FileManager.default.fileExists(atPath: full) { args.append(full); suffix = " on \(p)" } else { suffix = " (path \(p) not found, opened without it)" }
        }
        return launch(args) ? ("Opened \(app.name)\(suffix)", app.url.path) : ("Failed to open \(app.name)", nil)
    }

    // MARK: confirmation before running terminal commands

    private static let trustedKey = "trustedCommandSets"

    private static func fingerprint(_ commands: [String]) -> String {
        SHA256.hash(data: Data(commands.joined(separator: "\n").utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func asString(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Asks the user before any terminal command runs, using a real macOS dialog (a separate osascript process,
    /// so it also works headless in --mcp mode). Fails closed: anything except an explicit click on a Run button,
    /// including errors, Cancel and the 2-minute timeout, means "no". "Always allow these" trusts only this exact
    /// set of commands, so any change (or a different mode) asks again.
    private static func confirmRun(_ commands: [String], mode: String) -> Bool {
        let fp = fingerprint(commands)
        if (UserDefaults.standard.stringArray(forKey: trustedKey) ?? []).contains(fp) { return true }

        let shown = commands.prefix(12).map { "• \($0)" } + (commands.count > 12 ? ["…and \(commands.count - 12) more"] : [])
        let body = shown.map(asString).joined(separator: " & return & ")
        let title = "Run \(commands.count) terminal command\(commands.count == 1 ? "" : "s") for “\(mode)”?"
        let script = """
        tell current application
            activate
            display dialog (\(asString(title)) & return & return & \(body)) with title "F.R.I.D.A.Y" \
        buttons {"Cancel", "Always allow these", "Run"} default button "Run" cancel button "Cancel" with icon caution giving up after 120
        end tell
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        guard p.terminationStatus == 0, !text.contains("gave up:true") else { return false }
        if text.contains("button returned:Always allow these") {
            var t = UserDefaults.standard.stringArray(forKey: trustedKey) ?? []
            t.append(fp)
            UserDefaults.standard.set(t, forKey: trustedKey)
            return true
        }
        return text.contains("button returned:Run")
    }

    private static func activate(_ mode: AppMode, parts wanted: [String]) -> ToolResult {
        var lines: [String] = []
        var icons: [String] = []

        let base = open(mode.apps)
        if !base.opened.isEmpty { lines.append("Opened: \(base.opened.joined(separator: ", "))") }
        if !base.missing.isEmpty { lines.append("Not found: \(base.missing.joined(separator: ", "))") }
        icons += base.paths

        var selected = mode.parts
        if !wanted.isEmpty {
            selected = mode.parts.filter { part in
                wanted.contains { w in
                    let a = w.lowercased(), b = part.name.lowercased()
                    return a == b || a.contains(b) || b.contains(a)
                }
            }
            if selected.isEmpty { lines.append("No part matched \(wanted). Parts: \(mode.parts.map(\.name).joined(separator: ", "))") }
        }
        // every terminal step that runs a command needs the user's OK first
        let commands = selected.flatMap { part in
            part.steps.filter { $0.isTerminal && !($0.command ?? "").isEmpty }
                .map { step in (step.path.map { "cd \($0) && " } ?? "") + (step.command ?? "") }
        }
        let approved = commands.isEmpty || confirmRun(commands, mode: mode.name)
        if !approved { lines.append("User declined: \(commands.count) terminal command(s) were NOT run.") }

        for part in selected {
            for step in part.steps {
                if !approved, step.isTerminal, !(step.command ?? "").isEmpty { continue }
                let r = run(step)
                lines.append("[\(part.name)] \(r.line)")
                if let i = r.icon, !icons.contains(i) { icons.append(i) }
            }
        }
        let ran = selected.map(\.name)
        let note = "\(mode.name)" + (ran.isEmpty ? "" : " → " + ran.joined(separator: " + "))
        return ToolResult(text: "Mode '\(mode.name)':\n" + lines.joined(separator: "\n"), note: icons.isEmpty ? nil : note, icons: icons)
    }

    static let appList: [String: Any] = ["type": "array", "items": ["type": "string"],
                                          "description": "App names as the user would say them, e.g. [\"Xcode\", \"Safari\"]"]

    private static let stepSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "type": ["type": "string", "enum": ["terminal", "open"],
                     "description": "terminal = a Terminal window that cd's to path and runs command; open = open an app (optionally on a path)"],
            "app": ["type": "string", "description": "For 'open' steps: app name, e.g. 'Visual Studio Code'"],
            "path": ["type": "string", "description": "Folder to cd into (terminal) or open the app on (open). ~ and paths relative to the home folder are fine."],
            "command": ["type": "string", "description": "For terminal steps: shell command(s) to run after cd, e.g. 'yarn dev'"],
        ],
        "required": ["type"],
    ]

    private static let partsSchema: [String: Any] = [
        "type": "array",
        "description": "Named groups of steps that can be launched independently, e.g. 'flutter', 'next', 'django'.",
        "items": ["type": "object",
                  "properties": ["name": ["type": "string"], "steps": ["type": "array", "items": stepSchema]],
                  "required": ["name", "steps"]],
    ]

    /// Built-in tools; evolved abilities add theirs through `AbilityRegistry.tools`.
    static var all: [Tool] { base + AbilityRegistry.tools }

    static let base: [Tool] = [
        Tool(name: "open_apps",
             description: "Open (launch or bring to front) one or more macOS applications by name.",
             properties: ["apps": appList], required: ["apps"]) { args in
            report(open(strings(args["apps"])))
        },
        Tool(name: "close_apps",
             description: "Quit one or more running applications by name. This is a normal, graceful quit (apps may still ask to save unsaved work). Only use when the user explicitly asks to close or quit something.",
             properties: ["apps": appList], required: ["apps"]) { args in
            let running = NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != "com.friday.app" && $0.bundleIdentifier != "com.apple.finder" }
            var closed: [String] = [], missing: [String] = [], icons: [String] = []
            for n in strings(args["apps"]) {
                let q = n.lowercased().replacingOccurrences(of: ".app", with: "").trimmingCharacters(in: .whitespaces)
                let name: (NSRunningApplication) -> String = { $0.localizedName?.lowercased() ?? "" }
                let match = running.first { name($0) == q } ?? running.first { name($0).hasPrefix(q) } ?? running.first { name($0).contains(q) }
                if let app = match, app.terminate() {
                    closed.append(app.localizedName ?? n)
                    if let path = app.bundleURL?.path { icons.append(path) }
                } else { missing.append(n) }
            }
            var text = closed.isEmpty ? "Closed nothing." : "Asked to quit: \(closed.joined(separator: ", "))."
            if !missing.isEmpty { text += " Not running (or protected): \(missing.joined(separator: ", "))." }
            return ToolResult(text: text, note: closed.isEmpty ? nil : "Closed \(closed.joined(separator: ", "))", icons: icons)
        },
        Tool(name: "find_contacts",
             description: "Look up people in the user's Contacts by name, nickname, company, email or part of a phone number. The app shows the matches to the user as rich contact cards, so keep your own reply short and don't repeat every detail.",
             properties: ["query": ["type": "string", "description": "Name, company, email or phone digits"],
                          "limit": ["type": "integer", "description": "Max results (default 5, max 8)"]],
             required: ["query"]) { args in
            guard ContactsIndex.shared.loadIfNeeded() else {
                return ToolResult(text: "Contacts access hasn't been granted. Ask the user to allow F.R.I.D.A.Y in System Settings → Privacy & Security → Contacts.")
            }
            let q = args["query"] as? String ?? ""
            let limit = min(max((args["limit"] as? Int) ?? 5, 1), 8)
            let hits = ContactsIndex.shared.search(q, limit: limit).map(\.card)
            guard !hits.isEmpty else { return ToolResult(text: "No contacts match '\(q)'.") }
            let text = hits.map { c in
                var parts = [c.name]
                if !c.subtitle.isEmpty { parts.append(c.subtitle) }
                parts += c.phones.map { "\($0.label.isEmpty ? "phone" : $0.label): \($0.value)" }
                parts += c.emails.map { "\($0.label.isEmpty ? "email" : $0.label): \($0.value)" }
                if let b = c.birthday { parts.append("birthday: \(b)") }
                return "- " + parts.joined(separator: "; ")
            }.joined(separator: "\n")
            return ToolResult(text: text, note: "Found \(hits.count) contact\(hits.count == 1 ? "" : "s")", contacts: hits)
        },
        Tool(name: "show_map",
             description: "Find places on the map (an address, a landmark, 'coffee near Alexanderplatz', 'pizza in Rome') and show the user an interactive dark map with pins. Keep your own reply to one short line.",
             properties: ["query": ["type": "string", "description": "What to look for, e.g. 'Brandenburg Gate' or 'ramen near Shibuya'"],
                          "limit": ["type": "integer", "description": "Max places (default 5)"]],
             required: ["query"]) { args in
            let q = args["query"] as? String ?? ""
            let found = await MapsService.search(q, limit: min(max((args["limit"] as? Int) ?? 5, 1), 8)).map(\.0)
            guard !found.isEmpty else { return ToolResult(text: "No places found for '\(q)'.") }
            let text = found.map { "- \($0.name)" + ($0.address.isEmpty ? "" : " — \($0.address)") }.joined(separator: "\n")
            return ToolResult(text: text, note: "Map: \(q)", map: MapPreview(places: found))
        },
        Tool(name: "show_route",
             description: "Show directions between two places as an interactive dark map with the route, distance and travel time. 'from' must be a place or address (there is no current-location access).",
             properties: ["from": ["type": "string"], "to": ["type": "string"],
                          "mode": ["type": "string", "enum": ["driving", "walking", "transit"], "description": "Default driving"]],
             required: ["from", "to"]) { args in
            let from = args["from"] as? String ?? "", to = args["to"] as? String ?? ""
            let mode = args["mode"] as? String ?? "driving"
            guard let (route, ends) = await MapsService.route(from: from, to: to, mode: mode) else {
                return ToolResult(text: "Couldn't find a \(mode) route from '\(from)' to '\(to)'.")
            }
            return ToolResult(text: "\(ends[0].name) → \(ends[1].name): \(MapsService.distance(route.meters)), about \(MapsService.duration(route.seconds)) by \(mode).",
                              note: "Route: \(ends[0].name) → \(ends[1].name)", map: MapPreview(places: ends, route: route))
        },
        Tool(name: "get_weather",
             description: "Current weather and forecast for a city or place. The app shows a weather card, so keep your own reply to one short line.",
             properties: ["location": ["type": "string", "description": "City or place, e.g. 'Sydney' or 'Berlin'"]],
             required: ["location"]) { args in
            let loc = args["location"] as? String ?? ""
            guard let w = await WeatherService.fetch(loc) else { return ToolResult(text: "Couldn't get the weather for '\(loc)' (no match, or offline).") }
            let next = w.days.dropFirst().prefix(3).map { "\($0.label) \($0.lo)–\($0.hi)° \(WeatherService.describe($0.code))" }.joined(separator: "; ")
            return ToolResult(text: WeatherService.summary(w) + " Next days: " + next, note: "Weather: \(w.place)", widget: .weather(w))
        },
        Tool(name: "world_time",
             description: "Current local time in one or more cities / time zones (up to 4). The app shows live analog clocks, so keep your own reply to one short line.",
             properties: ["places": ["type": "array", "items": ["type": "string"], "description": "e.g. [\"Tokyo\", \"London\", \"New York\"]"]],
             required: ["places"]) { args in
            var zones: [ClockZone] = [], missing: [String] = []
            for p in strings(args["places"]).prefix(4) {
                if let z = await TimeLookup.resolveOnline(p) { zones.append(z) } else { missing.append(p) }
            }
            guard !zones.isEmpty else { return ToolResult(text: "Couldn't find those places: \(missing.joined(separator: ", ")).") }
            var text = zones.map { "\($0.name): \(TimeLookup.timeString($0))" }.joined(separator: "\n")
            if !missing.isEmpty { text += "\nNot found: \(missing.joined(separator: ", "))" }
            return ToolResult(text: text, note: "Time: \(zones.map(\.name).joined(separator: ", "))", widget: .clock(ClockCard(zones: zones)))
        },
        Tool(name: "define_word",
             description: "Dictionary definition of a word (built-in macOS dictionary). The app shows a definition card, so keep your own reply to one short line.",
             properties: ["word": ["type": "string"]], required: ["word"]) { args in
            let word = args["word"] as? String ?? ""
            guard let d = Dictionary_.define(word) else { return ToolResult(text: "No dictionary entry for '\(word)'.") }
            return ToolResult(text: d.text, note: "Definition: \(word)", widget: .definition(DefinitionCard(word: word, text: d.text, pron: d.pron)))
        },
        Tool(name: "lookup_topic",
             description: "Look up a topic, person, film, place or concept (what is X / who is X / tell me about X). The app shows a card with an image gallery and links, so answer in 2-3 short lines using the returned summary.",
             properties: ["topic": ["type": "string", "description": "The subject, e.g. 'Interstellar' or 'Ada Lovelace'"]],
             required: ["topic"]) { args in
            let topic = args["topic"] as? String ?? ""
            guard let r = await Knowledge.lookup(topic) else { return ToolResult(text: "Found nothing for '\(topic)' (no match, or offline).") }
            return ToolResult(text: "\(r.card.title)" + (r.card.description.map { " — \($0)" } ?? "") + "\n\(r.summary)",
                              note: "Topic: \(r.card.title)", widget: .knowledge(r.card))
        },
        Tool(name: "system_status",
             description: "Live snapshot of this Mac: CPU load (per core), memory use and pressure, swap, disk space, battery, uptime, and the top apps by CPU and by memory. The app shows a visual dashboard. Use it for 'how is my computer doing', CPU/RAM questions and 'what is slowing my Mac down'; then give a short diagnosis and one concrete suggestion.",
             properties: [:], required: []) { _ in
            let snap = await SystemInfo.snapshot()
            return ToolResult(text: SystemInfo.summary(snap), note: "System status", widget: .system(snap))
        },
        Tool(name: "disk_usage",
             description: "Measure which folders take the most space inside a folder (default: the home folder) and show a treemap. Use for 'what is taking so much space' and 'how big are my folders'. Call again with a subfolder path (e.g. '~/Library') to drill down. Large folders can take up to ~40 seconds.",
             properties: ["path": ["type": "string", "description": "Folder to analyse: '~' (default), '~/Library', '/Applications', ..."]],
             required: []) { args in
            let path = (args["path"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "~"
            guard let d = await DiskUsage.scan(path) else { return ToolResult(text: "Couldn't read the folder '\(path)'.") }
            return ToolResult(text: DiskUsage.summary(d), note: "Disk usage: \((d.path as NSString).abbreviatingWithTildeInPath)", widget: .disk(d))
        },
        Tool(name: "render_ui",
             description: "Show the user a visual, structured answer as a native glass UI instead of (or alongside) plain text. Use it when the answer has structure: comparisons, rankings, stats and numbers, schedules, breakdowns, steps or plans, pros and cons. Skip it for simple conversational replies and when a dedicated card tool fits (weather, maps, contacts, clocks, topics, system, disk). Pass `ui` as ONE component tree: {\"type\":\"card\",\"title\":\"…\",\"icon\":\"sf.symbol\",\"children\":[…]}. Components: card{title,subtitle,icon,children}, stack{children}, row{children}, grid{columns 1-4,children}, text{text,style:title|headline|body|caption|mono,tone}, stat{label,value,unit,delta,tone,icon}, badge{text,tone,icon}, kv{items:[{label,value}]}, list{items:[{title,subtitle,trailing,icon,tone}]}, table{columns:[..],rows:[[..]]}, progress{label,value 0-1,detail,tone}, gauge{label,value 0-1,detail}, chart{kind:bar|line|donut,title,unit,data:[{label,value}]}, steps{items:[{title,detail,done}]}, callout{tone,title,text}, quote{text,source}, code{text}, links{items:[{title,url}]}, divider. Tones: neutral, accent, good, warn, bad. Design rules: one card, at most 6 blocks; lead with the single most important thing (a stat grid or a callout); labels under ~30 characters; numbers formatted with units; tone only for meaning (good/warn/bad), never decoration; charts need 3+ data points; tables at most 5 columns and 8 rows; never invent image URLs; icons are SF Symbol names. Then reply with one short line.",
             properties: ["ui": ["type": "object", "description": "The root component, e.g. {\"type\":\"card\",\"title\":\"Comparison\",\"children\":[…]}"]],
             required: ["ui"]) { args in
            var raw: Any? = args["ui"]
            if let s = raw as? String, let d = s.data(using: .utf8) { raw = try? JSONSerialization.jsonObject(with: d) }   // some models send a JSON string
            var budget = 150
            guard let node = UINode.sanitize(raw, budget: &budget) else {
                return ToolResult(text: "Invalid ui: pass one object like {\"type\":\"card\",\"children\":[...]}.")
            }
            return ToolResult(text: "Rendered the visual to the user (\(150 - budget) components). Add at most one short sentence.", note: "Visual answer", widget: .ui(node))
        },
        Tool(name: "evolve",
             description: "Teach F.R.I.D.A.Y a new ability by drafting a change to its own code on a new git branch (usually 5-15 minutes, in the background). Use it when the user wants something none of your tools can do, typically an integration with a service or API (GitHub, Linear, Spotify...) or a new kind of visual. ALWAYS first tell the user plainly what you can't do yet, what you would add, and the time it takes, and ask permission. Call this only after they say yes; they also get a native confirmation. The draft is NOT installed: they review it on a card and click Install. Never pretend you have a capability you lack.",
             properties: ["capability": ["type": "string", "description": "What to add, specific: the service, the questions it should answer, the visuals it should show"],
                          "details": ["type": "string", "description": "Anything the user said that matters (repo names, preferences)"],
                          "estimate_minutes": ["type": "integer", "description": "Honest estimate, 5-15"]],
             required: ["capability"]) { args in
            let cap = (args["capability"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard cap.count >= 8 else { return ToolResult(text: "Describe the capability in more detail.") }
            let id = EvolutionInbox.submit(capability: cap, details: args["details"] as? String ?? "", minutes: (args["estimate_minutes"] as? Int) ?? 10)
            return ToolResult(text: "Asked the user for approval to draft this on a branch. Tell them it runs in the background, that a progress card is on screen, and that nothing is installed until they review and click Install.",
                              note: "Upgrade: \(cap)", widget: .evolution(id))
        },
        Tool(name: "evolution_status",
             description: "Status of F.R.I.D.A.Y's self-upgrades: what is drafting, ready for review, installed on trial, or permanent.",
             properties: [:], required: []) { _ in
            ToolResult(text: Evolution.statusText())
        },
        Tool(name: "list_running_apps",
             description: "List the user-facing applications currently open on the Mac.",
             properties: [:], required: []) { _ in
            let names = NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != "com.friday.app" }
                .compactMap(\.localizedName).sorted()
            return ToolResult(text: names.isEmpty ? "No apps open." : names.joined(separator: ", "))
        },
        Tool(name: "list_modes",
             description: "List the user's saved modes with their full recipes (apps, parts, steps, rules) as JSON.",
             properties: [:], required: []) { _ in
            ToolResult(text: Modes.summary())
        },
        Tool(name: "save_mode",
             description: "Create or fully replace a mode (a reusable work setup). Capture EVERYTHING the user described: every terminal window with its folder and command, editors opened on folders, and which parts to launch for which kind of work (in `rules`). When editing an existing mode, send the complete updated mode, not just the change.",
             properties: [
                "name": ["type": "string", "description": "Short mode name, e.g. 'gamilife'"],
                "apps": appList,
                "parts": partsSchema,
                "rules": ["type": "string", "description": "The user's own words on which parts to open when, e.g. \"if I say web: next + django; otherwise flutter + django\""],
             ], required: ["name"]) { args in
            let name = (args["name"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            var canonical: [String] = [], missing: [String] = [], icons: [String] = []
            for n in strings(args["apps"]) {
                if let a = resolve(n) { if !canonical.contains(a.name) { canonical.append(a.name); icons.append(a.url.path) } } else { missing.append(n) }
            }
            var parts: [Part] = []
            if let raw = args["parts"], let data = try? JSONSerialization.data(withJSONObject: raw) {
                parts = (try? JSONDecoder().decode([Part].self, from: data)) ?? []
            }
            var warnings: [String] = missing.map { "app not installed: \($0)" }
            for part in parts {
                for step in part.steps {
                    if !step.isTerminal {
                        if let a = resolve(step.app ?? "") { if !icons.contains(a.url.path) { icons.append(a.url.path) } } else { warnings.append("[\(part.name)] app not found: \(step.app ?? "?")") }
                    }
                    if let p = step.path, !p.isEmpty, !FileManager.default.fileExists(atPath: expand(p)) { warnings.append("[\(part.name)] path not found: \(p)") }
                }
            }
            guard !name.isEmpty, !(canonical.isEmpty && parts.isEmpty) else { return ToolResult(text: "Not saved: need a name plus at least one app or part.") }
            var modes = Modes.load()
            modes.removeAll { $0.name.lowercased() == name.lowercased() }
            modes.append(AppMode(name: name, apps: canonical, parts: parts, rules: (args["rules"] as? String) ?? ""))
            Modes.save(modes)
            var text = "Saved mode '\(name)': \(canonical.count) app(s), \(parts.count) part(s) [\(parts.map(\.name).joined(separator: ", "))]."
            if !warnings.isEmpty { text += " Warnings: \(warnings.joined(separator: "; "))." }
            return ToolResult(text: text, note: "Saved mode ‘\(name)’", icons: icons)
        },
        Tool(name: "activate_mode",
             description: "Launch a saved mode: opens its apps and runs the steps of the chosen parts. If the mode has parts, pass the ones that fit what the user said (follow the mode's `rules`); omit `parts` to run them all.",
             properties: ["name": ["type": "string", "description": "Mode name"],
                          "parts": ["type": "array", "items": ["type": "string"], "description": "Part names to run, e.g. [\"next\", \"django\"]"]],
             required: ["name"]) { args in
            guard let mode = Modes.find(args["name"] as? String ?? "") else {
                return ToolResult(text: "No such mode. Saved modes:\n\(Modes.summary())")
            }
            return activate(mode, parts: strings(args["parts"]))
        },
        Tool(name: "delete_mode",
             description: "Delete a saved mode.",
             properties: ["name": ["type": "string"]], required: ["name"]) { args in
            guard let mode = Modes.find(args["name"] as? String ?? "") else { return ToolResult(text: "No such mode.") }
            Modes.save(Modes.load().filter { $0.name != mode.name })
            return ToolResult(text: "Deleted mode '\(mode.name)'.", note: "Deleted mode ‘\(mode.name)’")
        },
    ]

    @MainActor
    static func call(_ name: String, _ args: [String: Any]) async -> ToolResult {
        guard let tool = all.first(where: { $0.name == name }) else { return ToolResult(text: "Unknown tool \(name)") }
        let result = await tool.run(args)
        // successful use of a learned tool counts toward "regular use" (see Evolution.checkTrials)
        if AbilityRegistry.tools.contains(where: { $0.name == name }) {
            let failed = ["Couldn't", "Could not", "Error", "Failed", "Invalid"].contains { result.text.hasPrefix($0) }
            EvolutionInbox.noteToolUse(name, ok: !failed)
        }
        return result
    }
}
