import Foundation
import Security

enum Keychain {
    private static let service = "com.friday.app.grok"

    static func get() -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var r: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &r) == errSecSuccess, let d = r as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func set(_ value: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}

/// Streams a Grok (via OpenRouter) reply. Grok itself decides whether a reply is warranted: it answers
/// "NOREPLY" for plain app/file/command lookups, and the UI then shows nothing.
enum Grok {
    /// Free OpenRouter models with tool calling, fastest first. OpenRouter tries them in order if one is busy or rate-limited.
    /// Override with: defaults write com.friday.app grokModel "<any openrouter model id>"
    static let freeModels = ["google/gemma-4-26b-a4b-it:free", "minimax/minimax-m3.1-flash:free", "openrouter/free"]   // OpenRouter allows at most 3
    static var modelOverride: String? { UserDefaults.standard.string(forKey: "grokModel") }
    static var hasKey: Bool { Keychain.get() != nil }

    /// Whether a query is worth sending at all (keeps API use low); Grok still makes the final call.
    static func looksLikeAsk(_ raw: String) -> (Bool, String) {
        let lower = raw.lowercased()
        for p in ["ask ", "grok ", "? "] where lower.hasPrefix(p) { return (true, String(raw.dropFirst(p.count))) }
        let words = raw.split(separator: " ").count
        return (raw.count >= 4 && (raw.hasSuffix("?") || words >= 3), raw)
    }

    struct Failure: Error { let message: String }

    static func ask(_ query: String, onText: @MainActor (String) -> Void) async throws {
        let date = Date().formatted(date: .complete, time: .omitted)
        let known = Memory.load(maxChars: 12_000)
        let context = known.isEmpty ? "" : "\n\nWhat you know about the user (their own notes; use it to personalise answers):\n\(known)"
        let system = """
        You are F.R.I.D.A.Y, a terse assistant living inside a Mac launcher's search box. Today is \(date). \
        The user's text is what they typed into the launcher. If it is merely a search for an app, file, folder, \
        shortcut, setting or command, a half-typed word, or otherwise not a question or request for information, \
        reply with exactly NOREPLY. Otherwise answer directly in plain text, no preamble, at most about 80 words, \
        light markdown only.\(context)
        """
        try await stream(system: system, messages: [["role": "user", "content": query]], silent: true, onText: onText)
    }

    /// Conversation mode ("F.R.I.D.A.Y AI"): always replies, keeps the whole chat as context, can use tools.
    static func chat(_ history: [[String: Any]], voice: Bool = false, onNote: @MainActor (ChatNote) -> Void,
                     onText: @MainActor (String) -> Void) async throws {
        try await stream(system: chatSystem(voice: voice), messages: history, silent: false, tools: Tools.all, onNote: onNote, onText: onText)
    }

    /// F.R.I.D.A.Y AI's instructions (shared by both engines).
    static func chatSystem(voice: Bool = false) -> String {
        let date = Date().formatted(date: .complete, time: .omitted)
        let known = Memory.load()
        let system = """
        You are F.R.I.D.A.Y, a sharp, concise AI assistant on the user's Mac. Today is \(date). \
        Be direct and brief (usually under 120 words), plain text with light markdown only.

        MEMORY: you keep notes about the user as markdown files in a folder called Me. Their current contents are below. \
        Use them to personalise your answers, naturally and without announcing that you read them. \
        When you learn something durable about the user (preferences, projects, people, goals, routines) or they ask you \
        to remember something, save it by ending your reply with a block like \
        <remember file="about.md">- Prefers metric units</remember> which appends to that file. \
        Use topical file names (about.md, projects.md, people.md, preferences.md). \
        To correct or restructure a file, use <rewrite file="about.md">complete new content</rewrite> (the old version is backed up). \
        Never mention these tags, never save secrets such as passwords or API keys, and skip trivia. \
        Save only when it is worth keeping.

        TOOLS & MODES: you can control the Mac with tools. A "mode" is a reusable work setup. It can be as simple as a few apps, \
        or a detailed recipe: named PARTS (e.g. "flutter", "next", "django"), each a list of STEPS, where a step is either a \
        Terminal window (folder to cd into + command to run, e.g. cd ~/Coding/app && yarn dev) or an app opened on a folder \
        (e.g. Visual Studio Code on ~/Coding/app). A mode's `rules` hold the user's own words on which parts to open for which \
        kind of work. Saved modes right now (full JSON):
        \(Modes.summary())

        Defining a mode: when the user describes how a setup should look (terminals, folders, commands, editors, conditions), \
        capture ALL of it with save_mode: one step per terminal window or editor, exact folders and commands exactly as said, \
        parts for anything they might want separately, and their conditional wording in `rules`. Never reduce it to just app \
        names. If they only name apps, you may call list_running_apps and ask which belong. If a detail is truly missing \
        (like a folder path), ask one short question first. After saving, briefly list what you saved (parts and steps). \
        Don't launch it unless they said they are about to work on it.

        Using a mode: when the user says they are about to do or work on something ("I'm gonna work on xyz", "let's code", \
        "time to study"), find the matching mode and call activate_mode right away, choosing `parts` according to its rules \
        and what they said, then confirm in a few words. If no mode matches, offer to set one up.
        Only open apps when a mode matches or the user explicitly asks to open something (use open_apps). \
        Only close apps (close_apps) when the user explicitly asks to close or quit something. \
        The user is asked to approve terminal commands before they run; if they decline, accept that and do not retry. \
        CONTACTS: when the user asks about a person (a number, an email, "show me Sam", "who is ..."), call find_contacts. \
        The app displays the matches as rich contact cards automatically, so reply with one short line and don't list every \
        detail again. Never invent contact details.
        MAPS: when the user asks where something is, for places near somewhere, or how to get from A to B, call show_map or \
        show_route. The app shows an interactive dark map with pins or the route, so reply with one short line (e.g. the \
        distance and time) and don't list every detail again.
        MAP RULE: use exactly ONE map tool per answer. For directions or "how do I get from A to B" call only show_route \
        (it already shows both places on the map); for finding places call only show_map. Never call both.
        CARDS: for weather call get_weather, for the time somewhere call world_time, for word meanings call define_word. \
        The app shows a rich card for each, so answer in one short line.
        TOPICS: for "what is X", "who is X", "tell me about X" (films, people, places, concepts) call lookup_topic; the app shows \
        an image gallery and links, so answer in 2-3 short lines from the returned summary.
        YOUR COMPUTER: for questions about the Mac's CPU, RAM, battery, slowness or "how is my computer doing" call system_status; \
        for "what's taking space", "which folders are big", "how much does X take" call disk_usage (pass a path to drill into a \
        folder, e.g. ~/Library). The app draws visual dashboards, so reply with a short diagnosis (what is likely the problem) and \
        one concrete suggestion. Never run anything destructive; only suggest.
        GENERATIVE UI: when an answer has structure (comparisons, rankings, numbers or KPIs, schedules, plans, steps, breakdowns, \
        pros and cons, summaries of data) call render_ui to draw it as a native glass card, then add at most one short sentence. \
        Plain chat, opinions and quick facts stay as text. Use a dedicated card tool when one fits (weather, maps, contacts, \
        clocks, topics, system, disk). Design like Apple would: one card, a clear hierarchy (hero stat or callout first), \
        generous but tight spacing, short labels, real numbers with units, tone only to carry meaning (good / warn / bad). \
        Example: render_ui({"ui":{"type":"card","title":"iPhone 16 vs Pixel 9","icon":"iphone","children":[ \
        {"type":"grid","columns":2,"children":[{"type":"stat","label":"Battery","value":"3561","unit":"mAh"}, \
        {"type":"stat","label":"Price","value":"$799","delta":"$100 less","tone":"good"}]}, \
        {"type":"table","columns":["","iPhone 16","Pixel 9"],"rows":[["Screen","6.1 in","6.3 in"],["Camera","48 MP","50 MP"]]}, \
        {"type":"callout","tone":"accent","text":"Pixel wins on price, iPhone on video."}]}})
        SELF-EVOLUTION: you can extend yourself. If the user asks for something none of your tools can do, usually an integration \
        with a service or API (GitHub, Linear, Spotify, a bank...) or a new kind of visual, never pretend or guess. Say plainly \
        what you can't do yet, what you would add (name the tools and visuals), roughly how long it takes (usually 5-15 minutes, \
        in the background, you can keep chatting) and that nothing is installed until they review it, then ask if they want you to \
        do it. Only after they say yes call evolve. They approve a dialog, the draft is written on a separate git branch, and they \
        click Install on the card. Use evolution_status if asked how it's going. After an upgrade is installed you will see its \
        tools: use them, and after a few days of regular use the app itself asks whether to make it permanent.
        EVOLVED ABILITIES (installed): \(Evolution.abilitiesSummary())
        \(AbilityRegistry.promptNotes)
        Never claim you opened or saved anything unless the tool result confirms it.

        \(known.isEmpty ? "(The memory folder is empty so far.)" : known)
        """
        return voice ? system + """


        VOICE MODE: the user is talking to you out loud and your reply will be read aloud by a text-to-speech voice. \
        Talk like a warm, quick-witted human assistant: one to three short sentences, natural contractions, plain words. \
        No markdown, no bullet lists, no emoji, no URLs, no code, and never read out long numbers or IDs. \
        When a card is shown (weather, map, contacts, clocks, topic, system, disk), just add one natural sentence about it. \
        Ask at most one short follow-up question, and only if you truly need it.
        """ : system
    }

    private static func stream(system: String, messages: [[String: Any]], silent: Bool, tools: [Tool] = [],
                               onNote: @MainActor (ChatNote) -> Void = { _ in },
                               onText: @MainActor (String) -> Void) async throws {
        guard let key = Keychain.get(), let url = URL(string: "https://openrouter.ai/api/v1/chat/completions") else {
            throw Failure(message: "Set your OpenRouter API key from the menu-bar icon.")
        }
        var convo: [[String: Any]] = [["role": "system", "content": system]] + messages
        var shownBefore = ""   // text from earlier rounds (before tool calls)

        for _ in 0..<6 {
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.timeoutInterval = 60
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("F.R.I.D.A.Y", forHTTPHeaderField: "X-Title")
            var body: [String: Any] = ["stream": true, "temperature": 0.3, "max_tokens": 1500, "messages": convo]
            if let m = modelOverride { body["model"] = m } else { body["models"] = freeModels }
            if !tools.isEmpty { body["tools"] = tools.map(\.openAI) }
            req.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (bytes, resp) = try await URLSession.shared.bytes(for: req)
            if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                var errBody = ""
                for try await line in bytes.lines { errBody += line }
                let hint = http.statusCode == 401 || http.statusCode == 403 ? "check your API key" : String(errBody.prefix(120))
                throw Failure(message: "OpenRouter error \(http.statusCode): \(hint)")
            }

            var text = ""
            var calls: [Int: (id: String, name: String, args: String)] = [:]
            for try await line in bytes.lines {
                if Task.isCancelled { return }
                guard line.hasPrefix("data:") else { continue }
                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if payload == "[DONE]" { break }
                guard let obj = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
                      let delta = (obj["choices"] as? [[String: Any]])?.first?["delta"] as? [String: Any] else { continue }

                for tc in delta["tool_calls"] as? [[String: Any]] ?? [] {
                    let i = tc["index"] as? Int ?? 0
                    var c = calls[i] ?? ("", "", "")
                    if let id = tc["id"] as? String { c.id = id }
                    if let f = tc["function"] as? [String: Any] {
                        if let n = f["name"] as? String { c.name += n }
                        if let a = f["arguments"] as? String { c.args += a }
                    }
                    calls[i] = c
                }

                guard let piece = delta["content"] as? String else { continue }
                text += piece
                let t = (shownBefore + text).trimmingCharacters(in: .whitespacesAndNewlines)
                if t.isEmpty { continue }
                if silent {
                    let up = t.uppercased()
                    if "NOREPLY".hasPrefix(up) || up.hasPrefix("NOREPLY") { continue }   // Grok chose silence
                }
                await onText(t)
            }

            if calls.isEmpty { return }   // no tools requested: the reply is complete

            // run the requested tools, feed results back, and let the model continue
            let ordered = calls.sorted { $0.key < $1.key }.map(\.value)
            convo.append(["role": "assistant", "content": text,
                          "tool_calls": ordered.map { ["id": $0.id, "type": "function",
                                                       "function": ["name": $0.name, "arguments": $0.args.isEmpty ? "{}" : $0.args]] }])
            for c in ordered {
                let args = (try? JSONSerialization.jsonObject(with: Data(c.args.utf8)) as? [String: Any]) ?? [:]
                let result = await Tools.call(c.name, args)
                if let n = result.note { await onNote(ChatNote(text: n, icons: result.icons, contacts: result.contacts, map: result.map, widget: result.widget)) }
                convo.append(["role": "tool", "tool_call_id": c.id, "content": result.text])
            }
            if !text.isEmpty { shownBefore += text + "\n\n" }
        }
    }
}
