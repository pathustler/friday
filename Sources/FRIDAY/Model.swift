import AppKit
import SwiftUI

enum Mode { case search, ai }

struct ChatMessage: Identifiable, Codable {
    var id = UUID()
    let role: String   // "user" | "assistant"
    var text: String
    var streaming = false   // reply still arriving: drives the typing animation
    var notes: [ChatNote] = []   // e.g. "Saved to Me/about.md", "Opened Xcode"
}

@MainActor
final class SearchModel: ObservableObject {
    @Published var query = "" {
        didSet {
            guard query != oldValue else { return }
            UserDefaults.standard.set(query, forKey: "lastQuery")
            queryChanged()
        }
    }
    @Published private(set) var results: [SearchResult] = [] { didSet { updateHeight() } }
    @Published var selected = 0 { didSet { updateHeight() } }
    @Published var focusTick = 0
    /// Dimmed inline answer shown after the query, e.g. " = 4".
    @Published private(set) var ghost = ""
    /// Translucent flag of the target currency, shown at the right of the field.
    @Published private(set) var flag: String?
    /// Color preview for hex / rgb / hsl queries.
    @Published private(set) var swatch: Color?
    /// Weather / clock / definition card previewed under the results in normal search.
    @Published private(set) var livePreview: Widget? { didSet { updateHeight() } }
    private var widgetTask: Task<Void, Never>?
    private var knowledgeTask: Task<Void, Never>?
    /// Briefly true after ↵ copies an answer.
    @Published private(set) var copied = false
    private var copiedTask: Task<Void, Never>?
    /// Grok's answer, shown below the results when it chooses to reply.
    @Published private(set) var reply = "" { didSet { updateHeight() } }

    // F.R.I.D.A.Y AI (chat mode)
    @Published private(set) var mode = Mode.search { didSet { updateHeight() } }
    @Published var aiInput = ""
    @Published private(set) var chat: [ChatMessage] = [] { didSet { updateHeight() } }
    @Published private(set) var panelHeight = Metrics.height(rows: 0)
    private var aiTask: Task<Void, Never>?
    private var lastRaw = ""

    // voice ("Friday" wake word)
    @Published var voiceState: VoiceState = .off
    @Published var voiceLevel: Float = 0
    @Published var voiceError: String?
    @Published var voiceEngine = ""
    var onVoiceStop: () -> Void = {}
    private var voiceTurn = false
    private var grokTask: Task<Void, Never>?
    private var copyValue: String?

    init() {
        currency.refreshIfNeeded {}
        query = UserDefaults.standard.string(forKey: "lastQuery") ?? ""
        if let d = UserDefaults.standard.data(forKey: Self.chatKey), var saved = try? JSONDecoder().decode([ChatMessage].self, from: d) {
            for i in saved.indices { saved[i].streaming = false }
            chat = saved
        }
    }

    var dismiss: () -> Void = {}
    let index = AppIndex.shared
    private let currency = CurrencyRates()

    private var local: [SearchResult] = []
    private var files: [SearchResult] = []
    private var fileTask: Task<Void, Never>?
    private var filesPending = false
    private let usageKey = "usage"

    private var usage: [String: Int] {
        get { UserDefaults.standard.dictionary(forKey: usageKey) as? [String: Int] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: usageKey) }
    }

    func prepareForShow() {
        mode = .search   // always open in plain F.R.I.D.A.Y
        queryChanged()   // keep the last query; it is re-evaluated (fresh rates, new apps)
        focusTick += 1
        Task { await index.refresh(); if query.isEmpty { queryChanged() } }
        Task { await ContactsIndex.shared.refresh() }
        currency.refreshIfNeeded {}
    }

    /// The contact under the selection, if the highlighted row is a person.
    var selectedContact: ContactCard? {
        mode == .search && results.indices.contains(selected) ? results[selected].contact : nil
    }

    private func updateHeight() {
        panelHeight = mode == .ai ? Metrics.aiHeight(hasChat: !chat.isEmpty)
                                  : Metrics.height(rows: results.count, reply: reply, contact: selectedContact, widget: livePreview)
    }

    // MARK: - F.R.I.D.A.Y AI

    /// The last few messages are kept (and shown) between sessions; older ones drop off.
    private static let chatKey = "chatHistory"
    private static let keepMessages = 8

    private func persistChat() {
        var keep = Array(chat.filter { !$0.text.isEmpty || $0.streaming }.suffix(Self.keepMessages))
        while keep.first?.role == "assistant" { keep.removeFirst() }   // always start on a user message
        if keep.count != chat.count { chat = keep }
        // contact details are never written to disk with the chat
        let saved = keep.filter { !$0.streaming }.map { m -> ChatMessage in
            var m = m
            m.notes = m.notes.map { ChatNote(text: $0.text, icons: $0.icons) }   // no contacts, no maps
            return m
        }
        if let d = try? JSONEncoder().encode(saved) { UserDefaults.standard.set(d, forKey: Self.chatKey) }
    }

    /// ⌘K: start a fresh conversation.
    func clearChat() {
        aiTask?.cancel()
        chat = []
        aiInput = ""
        UserDefaults.standard.removeObject(forKey: Self.chatKey)
    }

    func enterAI() {
        mode = .ai
        focusTick += 1
    }

    /// Esc: leave chat mode first, then close.
    func escape() {
        if mode == .ai {
            onVoiceStop()
            mode = .search
            focusTick += 1
        } else {
            dismiss()
        }
    }

    /// A message that was spoken: the reply is then generated for (and read out in) a conversational style.
    /// A message from F.R.I.D.A.Y itself (not a reply to the user), optionally with an upgrade card.
    func appendAssistant(_ text: String, upgradeCard id: String?) {
        var m = ChatMessage(role: "assistant", text: text)
        if let id { m.notes = [ChatNote(text: "Upgrade", widget: .evolution(id))] }
        chat.append(m)
        persistChat()
    }

    func submitVoice(_ text: String) {
        aiInput = text
        voiceTurn = true
        sendAI()
    }

    private func sendAI() {
        let t = aiInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard mode == .ai, !t.isEmpty else { return }
        aiTask?.cancel()
        aiInput = ""   // the text moves down into the chat; the field is free for the next message
        chat.append(ChatMessage(role: "user", text: t))
        let history = chat.filter { !$0.text.isEmpty }.map { ["role": $0.role, "content": $0.text] }
        let voice = voiceTurn
        voiceTurn = false
        let answer = ChatMessage(role: "assistant", text: "", streaming: true)
        chat.append(answer)
        persistChat()
        aiTask = Task { [weak self] in
            do {
                try await AI.chat(history, voice: voice, onNote: { note in self?.addNote(answer.id, note) }) { raw in
                    self?.lastRaw = raw
                    self?.update2(answer.id, Memory.parse(raw).display)
                }
            } catch let f as Grok.Failure {
                self?.lastRaw = ""
                self?.update2(answer.id, f.message)
            } catch {}
            self?.finish(answer.id, cancelled: Task.isCancelled)
        }
    }

    /// Reply complete: run any memory saves the model asked for.
    private func finish(_ id: UUID, cancelled: Bool) {
        guard let i = chat.firstIndex(where: { $0.id == id }) else { return }
        chat[i].streaming = false
        guard !cancelled else { return }
        let notes = Memory.parse(lastRaw).actions.compactMap(Memory.apply)
        for n in Set(notes).sorted() where !chat[i].notes.contains(ChatNote(text: n)) { chat[i].notes.append(ChatNote(text: n)) }
        lastRaw = ""
        persistChat()
    }

    private func addNote(_ id: UUID, _ note: ChatNote) {
        guard let i = chat.firstIndex(where: { $0.id == id }), !chat[i].notes.contains(note) else { return }
        if let new = note.map {
            // at most one map card per reply: a route wins over plain places, otherwise the latest wins
            let existingRoute = chat[i].notes.contains { $0.map?.route != nil }
            if existingRoute && new.route == nil { return }
            chat[i].notes.removeAll { $0.map != nil }
        }
        chat[i].notes.append(note)
    }

    private func update2(_ id: UUID, _ text: String) {
        if let i = chat.firstIndex(where: { $0.id == id }) { chat[i].text = text }
    }

    func move(_ delta: Int) {
        guard !results.isEmpty else { return }
        selected = (selected + delta + results.count) % results.count
    }

    func activate(_ idx: Int? = nil, reveal: Bool = false) {
        if mode == .ai { sendAI(); return }
        if query.trimmingCharacters(in: .whitespaces).isEmpty { enterAI(); return }   // ↵ on an empty field -> F.R.I.D.A.Y AI
        let i = idx ?? selected
        if results.isEmpty, let v = copyValue {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(v, forType: .string)
            copied = true
            copiedTask?.cancel()
            copiedTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                if !Task.isCancelled { self?.copied = false }
            }
            return   // stay open: ↵ on an answer only copies it
        }
        guard results.indices.contains(i) else { return }
        let r = results[i]
        if r.id.hasPrefix("app:") || r.id.hasPrefix("sc:") || r.id.hasPrefix("cmd:") || r.id.hasPrefix("file:") {
            usage[r.id, default: 0] += 1
        }
        dismiss()
        if reveal, let rev = r.reveal { rev() } else { r.run() }
    }

    // MARK: - Searching

    private func queryChanged() {
        fileTask?.cancel()
        grokTask?.cancel()
        widgetTask?.cancel()
        knowledgeTask?.cancel()
        livePreview = nil
        reply = ""
        files = []
        ghost = ""
        copied = false
        flag = nil
        swatch = nil
        copyValue = nil
        filesPending = false
        let raw = query.trimmingCharacters(in: .whitespaces)
        let q = raw.lowercased()
        var out: [SearchResult] = []

        if q.isEmpty {
            let u = usage
            out = index.apps.filter { u["app:\($0.url.path)"] != nil }
                .sorted { u["app:\($0.url.path)"]! > u["app:\($1.url.path)"]! }
                .prefix(6).map(appResult)
            local = out
            rebuild(web: nil)
            return
        }

        if let c = ColorParser.parse(raw) {
            let converted = c.fromHex ? ColorParser.rgb(c) : ColorParser.hex(c)
            ghost = " = \(converted)"
            copyValue = converted
            swatch = Color(.sRGB, red: c.r / 255, green: c.g / 255, blue: c.b / 255, opacity: c.a)
        }

        if ghost.isEmpty, let value = Calculator.evaluate(raw) {
            ghost = " = \(value)"
            copyValue = value
        }

        if ghost.isEmpty, let c = Units.convert(raw) {
            ghost = " = \(c.value) \(c.unit)"
            copyValue = c.value
        }

        if ghost.isEmpty, let (amount, from, to) = CurrencyRates.parse(raw) {
            if currency.isReady, let v = currency.convert(amount, from: from, to: to) {
                let text = v < 1 ? String(format: "%.4f", v) : String(format: "%.2f", v)
                ghost = " = \(text) \(to.uppercased())"
                copyValue = text
                flag = CurrencyRates.flag(for: to)
            } else {
                // No rates yet (first launch, offline): show nothing extra and update once they arrive.
                currency.refreshIfNeeded { [weak self] in
                    guard let self, self.query.trimmingCharacters(in: .whitespaces) == raw else { return }
                    self.queryChanged()
                }
            }
        }

        if !ghost.isEmpty {
            local = []
            rebuild(web: nil)
            return
        }

        if ghost.isEmpty, handleWidgetQuery(raw) {
            local = []
            rebuild(web: nil)
            return
        }

        startKnowledgeLookup(raw)

        let u = usage
        let scored: [(Int, AppEntry)] = index.apps.compactMap { a in
            AppIndex.score(q, a).map { ($0 + min((u["app:\(a.url.path)"] ?? 0) * 3, 25), a) }
        }.sorted { ($0.0, -$0.1.name.count) > ($1.0, -$1.1.name.count) }
        let people = ContactsIndex.shared.search(raw, limit: 3)
        out += scored.prefix(people.isEmpty ? 6 : 4).map { appResult($0.1) }
        out += people.map(contactResult)

        let shortcutHits = index.shortcuts.compactMap { sc in
            AppIndex.score(q, sc).map { ($0 + min((u["sc:\(sc.name)"] ?? 0) * 3, 25), sc) }
        }.sorted { $0.0 > $1.0 }
        out += shortcutHits.prefix(3).map { shortcutResult($0.1.name) }

        for c in Commands.all where c.title.lowercased().contains(q) || c.keywords.contains(where: { $0.hasPrefix(q) }) {
            out.append(SearchResult(id: "cmd:\(c.title)", title: c.title, subtitle: "System command", kind: "Command",
                                    icon: symbol(c.symbol), run: c.action))
        }
        if let url = urlFrom(raw) {
            out.append(SearchResult(id: "url", title: "Open \(raw)", subtitle: url.absoluteString, kind: "Website",
                                    icon: symbol("safari")) { NSWorkspace.shared.open(url) })
        }

        local = out
        rebuild(web: raw)

        scheduleGrok(raw)

        guard q.count >= 2 else { return }
        filesPending = true
        fileTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            if Task.isCancelled { return }
            async let folderHits = FileSearch.find(raw)
            async let pdfHits = FileSearch.findPDFs(raw)
            let (paths, pdfs) = await (folderHits, pdfHits)
            if Task.isCancelled { return }
            await MainActor.run {
                guard let self, self.query.trimmingCharacters(in: .whitespaces) == raw else { return }
                self.filesPending = false
                self.files = paths.prefix(3).map(self.fileResult) + pdfs.prefix(4).map { self.pdfResult($0.path, byName: $0.byName) }
                self.rebuild(web: raw, keepSelection: true)
            }

            // second pass: swap the generic icons for first-page previews as they become ready
            let top = Array(pdfs.prefix(4))
            guard !top.isEmpty else { return }
            let thumbs: [String: NSImage] = await withTaskGroup(of: (String, NSImage?).self) { group in
                for p in top { group.addTask { (p.path, PDFThumb.image(p.path)) } }
                var d: [String: NSImage] = [:]
                for await (k, v) in group { if let v { d[k] = v } }
                return d
            }
            if Task.isCancelled || thumbs.isEmpty { return }
            await MainActor.run {
                guard let self, self.query.trimmingCharacters(in: .whitespaces) == raw else { return }
                self.files = paths.prefix(3).map(self.fileResult) + top.map { self.pdfResult($0.path, byName: $0.byName, thumb: thumbs[$0.path]) }
                self.rebuild(web: raw, keepSelection: true)
            }
        }
    }

    // MARK: live previews: "weather sydney", "time in tokyo, london", "define serendipity"

    private func matches(_ pattern: String, _ s: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)), m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: s) else { return nil }
        return String(s[r]).trimmingCharacters(in: .whitespaces)
    }

    private func splitPlaces(_ s: String) -> [String] {
        s.replacingOccurrences(of: " and ", with: ",").replacingOccurrences(of: " vs ", with: ",")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Returns true if the query is a weather / time / definition lookup (the preview is then filled in).
    private func handleWidgetQuery(_ raw: String) -> Bool {
        // definitions: offline and instant
        if let w = matches(#"^(?:define|definition of|meaning of)\s+(.{2,40})$"#, raw), let d = Dictionary_.define(w) {
            livePreview = .definition(DefinitionCard(word: w, text: d.text, pron: d.pron))
            copyValue = d.text
            return true
        }

        // time: offline table first; "time in X" may also fall back to a network lookup
        let explicitTime = matches(#"^(?:what(?:'s| is)\s+)?(?:the\s+)?(?:current\s+)?time\s+(?:in|at|for)\s+(.{2,})$"#, raw)
        let suffixTime = matches(#"^(.{2,}?)\s+(?:local\s+)?time$"#, raw)
        if let spec = explicitTime ?? suffixTime {
            let names = splitPlaces(spec).prefix(4)
            let offline = names.compactMap(TimeLookup.resolve)
            if !names.isEmpty, offline.count == names.count {
                livePreview = .clock(ClockCard(zones: offline))
                copyValue = offline.map { "\($0.name) \(TimeLookup.timeString($0))" }.joined(separator: ", ")
                return true
            }
            if explicitTime != nil, !names.isEmpty {
                widgetTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    var zones: [ClockZone] = []
                    for n in names { if let z = await TimeLookup.resolveOnline(n) { zones.append(z) } }
                    if Task.isCancelled || zones.isEmpty { return }
                    await MainActor.run {
                        guard let self, self.query.trimmingCharacters(in: .whitespaces) == raw else { return }
                        self.livePreview = .clock(ClockCard(zones: zones))
                        self.copyValue = zones.map { "\($0.name) \(TimeLookup.timeString($0))" }.joined(separator: ", ")
                    }
                }
                return true
            }
        }

        // computer status: "cpu", "ram usage", "system status" ... (~1 s to sample)
        if matches(#"^((?:cpu|ram|memory|system|performance|computer|mac)(?:\s+(?:usage|status|stats|monitor|health))?|system status|how(?:'s| is) my (?:mac|computer))$"#, raw) != nil {
            widgetTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 250_000_000)
                if Task.isCancelled { return }
                let snap = await SystemInfo.snapshot()
                if Task.isCancelled { return }
                await MainActor.run {
                    guard let self, self.query.trimmingCharacters(in: .whitespaces) == raw else { return }
                    self.livePreview = .system(snap)
                    self.copyValue = SystemInfo.summary(snap)
                }
            }
            return true
        }

        // weather: needs the network, so it is debounced while you type
        if let place = matches(#"^(?:weather|forecast)(?:\s+(?:in|for|at))?\s+(.{2,})$"#, raw)
            ?? matches(#"^(.{2,}?)\s+(?:weather|forecast)$"#, raw) {
            widgetTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 450_000_000)
                if Task.isCancelled { return }
                guard let w = await WeatherService.fetch(place), !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self, self.query.trimmingCharacters(in: .whitespaces) == raw else { return }
                    self.livePreview = .weather(w)
                    self.copyValue = WeatherService.summary(w)
                }
            }
            return true
        }
        return false
    }

    /// "what is interstellar", "who is ada lovelace": add an image gallery + links card (results and replies still show).
    private func startKnowledgeLookup(_ raw: String) {
        guard let topic = matches(#"^(?:what(?:'s| is| are| was| were)|who(?:'s| is| was)|tell me about|about)\s+(?:a |an |the )?(.{2,60}?)\??$"#, raw) else { return }
        knowledgeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            if Task.isCancelled { return }
            guard let r = await Knowledge.lookup(topic, strict: true), !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.query.trimmingCharacters(in: .whitespaces) == raw, self.livePreview == nil else { return }
                self.livePreview = .knowledge(r.card)
            }
        }
    }

    private func scheduleGrok(_ raw: String) {
        let (ask, text) = Grok.looksLikeAsk(raw)
        guard ask, Grok.hasKey else { return }
        grokTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)   // debounce while typing
            if Task.isCancelled { return }
            do {
                try await Grok.ask(text) { t in
                    guard let self, self.query.trimmingCharacters(in: .whitespaces) == raw else { return }
                    self.reply = t
                    self.copyValue = t
                }
            } catch let f as Grok.Failure {
                self?.reply = f.message
            } catch {}
        }
    }

    private func rebuild(web: String?, keepSelection: Bool = false) {
        var all = Array((local + files).prefix(8))
        if all.isEmpty, !filesPending, let web, !web.isEmpty, let enc = web.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
           let url = URL(string: "https://www.google.com/search?q=\(enc)") {
            all.append(SearchResult(id: "web", title: "Search the web for “\(web)”", subtitle: "Google", kind: "Web",
                                    icon: symbol("globe")) { NSWorkspace.shared.open(url) })
        }
        results = all
        selected = keepSelection ? min(selected, max(all.count - 1, 0)) : 0
    }

    private func appResult(_ a: AppEntry) -> SearchResult {
        let url = a.url
        return SearchResult(id: "app:\(url.path)", title: a.name, subtitle: "",
                            kind: "Application", icon: NSWorkspace.shared.icon(forFile: url.path),
                            run: { NSWorkspace.shared.openApplication(at: url, configuration: .init()) },
                            reveal: { NSWorkspace.shared.activateFileViewerSelecting([url]) })
    }

    private func contactResult(_ e: ContactsIndex.Entry) -> SearchResult {
        let c = e.card
        let detail = [c.phones.first?.value, c.emails.first?.value].compactMap { $0 }.joined(separator: "  ·  ")
        return SearchResult(id: "contact:\(c.id)", title: c.name, subtitle: detail.isEmpty ? c.subtitle : detail,
                            kind: "Contact", icon: Avatar.image(name: c.name, id: c.id),
                            run: { ContactsIndex.open(c.id) }, contact: c)
    }

    private func shortcutResult(_ name: String) -> SearchResult {
        SearchResult(id: "sc:\(name)", title: name, subtitle: "", kind: "Shortcut",
                     icon: NSWorkspace.shared.icon(forFile: "/System/Applications/Shortcuts.app")) {
            Commands.shell("/usr/bin/shortcuts", ["run", name])
        }
    }

    private func pdfResult(_ path: String, byName: Bool, thumb: NSImage? = nil) -> SearchResult {
        let url = URL(fileURLWithPath: path)
        let shown = (path as NSString).abbreviatingWithTildeInPath
        return SearchResult(id: "file:\(path)", title: url.lastPathComponent,
                            subtitle: byName ? shown : "Text match · \(shown)",
                            kind: "PDF", icon: thumb ?? NSWorkspace.shared.icon(forFile: path),
                            run: { NSWorkspace.shared.open(url) },
                            reveal: { NSWorkspace.shared.activateFileViewerSelecting([url]) },
                            isPreview: thumb != nil)
    }

    private func fileResult(_ path: String) -> SearchResult {
        let url = URL(fileURLWithPath: path)
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        return SearchResult(id: "file:\(path)", title: url.lastPathComponent,
                            subtitle: (path as NSString).abbreviatingWithTildeInPath,
                            kind: isDir.boolValue ? "Folder" : "File", icon: NSWorkspace.shared.icon(forFile: path),
                            run: { NSWorkspace.shared.open(url) },
                            reveal: { NSWorkspace.shared.activateFileViewerSelecting([url]) })
    }

    private func symbol(_ name: String) -> NSImage {
        let img = NSImage(systemSymbolName: name, accessibilityDescription: nil) ?? NSImage()
        img.isTemplate = true
        return img
    }

    private func urlFrom(_ s: String) -> URL? {
        guard !s.contains(" ") else { return nil }
        if s.hasPrefix("http://") || s.hasPrefix("https://") { return URL(string: s) }
        let parts = s.split(separator: ".")
        guard parts.count >= 2, let tld = parts.last, tld.count >= 2, tld.allSatisfy(\.isLetter),
              !s.hasSuffix(".app") else { return nil }
        return URL(string: "https://\(s)")
    }
}
