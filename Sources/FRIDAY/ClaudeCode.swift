import Foundation

enum Engine {
    /// "openrouter" (default, free models) or "claude" (Claude Code CLI, uses your Claude login).
    static var useClaude: Bool { (UserDefaults.standard.string(forKey: "engine") ?? "openrouter") == "claude" }
}

/// Runs the user's own Claude Code (`claude -p`) as the chat engine instead of OpenRouter.
/// Built-in Claude Code tools are off; only F.R.I.D.A.Y's tools are exposed, through `FRIDAY --mcp`.
enum ClaudeCode {
    static var model: String { UserDefaults.standard.string(forKey: "claudeModel") ?? "haiku" }

    static func find() -> String? {
        let home = NSHomeDirectory()
        for p in ["/usr/local/bin/claude", "/opt/homebrew/bin/claude", "\(home)/.claude/local/claude",
                  "\(home)/.local/bin/claude", "\(home)/.npm-global/bin/claude"]
        where FileManager.default.isExecutableFile(atPath: p) { return p }
        // fall back to the login shell's PATH
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", "command -v claude"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let path = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        p.waitUntilExit()
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    private static func transcript(_ history: [[String: Any]]) -> String {
        guard history.count > 1, let last = history.last?["content"] as? String else {
            return history.last?["content"] as? String ?? ""
        }
        let earlier = history.dropLast().map { m -> String in
            "\(m["role"] as? String == "user" ? "User" : "F.R.I.D.A.Y"): \(m["content"] as? String ?? "")"
        }.joined(separator: "\n\n")
        return "Conversation so far:\n\n\(earlier)\n\n---\nThe user's new message (answer this one):\n\(last)"
    }

    static func chat(_ history: [[String: Any]], system: String, onNote: @MainActor (ChatNote) -> Void,
                     onText: @MainActor (String) -> Void) async throws {
        guard let exe = find() else {
            throw Grok.Failure(message: "Claude Code not found. Install it, or switch the AI engine to OpenRouter in the menu-bar menu.")
        }
        let dir = NSTemporaryDirectory() + "friday-cc"       // neutral folder: no project CLAUDE.md gets picked up
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let notesFile = dir + "/notes-\(UUID().uuidString).jsonl"
        defer { try? FileManager.default.removeItem(atPath: notesFile) }

        let mcp = try JSONSerialization.data(withJSONObject: [
            "mcpServers": ["friday": [
                "command": Bundle.main.executablePath ?? "/Applications/FRIDAY.app/Contents/MacOS/FRIDAY",
                "args": ["--mcp"],
                "env": ["FRIDAY_NOTES_FILE": notesFile],
            ]],
        ])

        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.currentDirectoryURL = URL(fileURLWithPath: dir)
        p.arguments = ["-p", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
                       "--tools", "", "--system-prompt", system, "--no-session-persistence", "--model", model,
                       "--setting-sources", "project", "--disable-slash-commands",
                       "--strict-mcp-config", "--mcp-config", String(decoding: mcp, as: UTF8.self),
                       "--allowedTools", "mcp__friday"]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
        p.environment = env
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        p.standardInput = stdin
        p.standardOutput = stdout
        p.standardError = stderr
        try p.run()
        stdin.fileHandleForWriting.write(Data(transcript(history).utf8))
        try? stdin.fileHandleForWriting.close()

        var notesOffset = 0
        func drainNotes() -> [ChatNote] {
            guard let d = FileManager.default.contents(atPath: notesFile), d.count > notesOffset else { return [] }
            let fresh = d.subdata(in: notesOffset..<d.count)
            notesOffset = d.count
            return String(decoding: fresh, as: UTF8.self).split(separator: "\n").compactMap { line in
                try? JSONDecoder().decode(ChatNote.self, from: Data(line.utf8))
            }
        }

        var failure: String?
        var text = "", shownBefore = ""
        try await withTaskCancellationHandler {
            for try await line in stdout.fileHandleForReading.bytes.lines {
                if Task.isCancelled { break }
                guard let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      let type = o["type"] as? String else { continue }
                switch type {
                case "stream_event":
                    let e = o["event"] as? [String: Any] ?? [:]
                    if e["type"] as? String == "message_start", !text.isEmpty {       // a new turn after a tool call
                        shownBefore += text + "\n\n"
                        text = ""
                    }
                    if e["type"] as? String == "content_block_delta",
                       let d = e["delta"] as? [String: Any], d["type"] as? String == "text_delta", let piece = d["text"] as? String {
                        text += piece
                        let t = (shownBefore + text).trimmingCharacters(in: .whitespacesAndNewlines)
                        if !t.isEmpty { await onText(t) }
                    }
                case "user":                                                          // a tool finished: show its note
                    for n in drainNotes() { await onNote(n) }
                case "result":
                    if o["is_error"] as? Bool == true { failure = o["result"] as? String ?? "unknown error" }
                    else if text.isEmpty, shownBefore.isEmpty, let r = o["result"] as? String, !r.isEmpty { await onText(r) }
                default: break
                }
            }
        } onCancel: {
            if p.isRunning { p.terminate() }
        }
        for n in drainNotes() { await onNote(n) }
        if p.isRunning { p.terminate() }
        if let f = failure { throw Grok.Failure(message: "Claude Code: \(f)") }
    }
}

/// Picks the engine for F.R.I.D.A.Y AI chat.
enum AI {
    static func chat(_ history: [[String: Any]], voice: Bool = false, onNote: @MainActor (ChatNote) -> Void,
                     onText: @MainActor (String) -> Void) async throws {
        if Engine.useClaude {
            try await ClaudeCode.chat(history, system: Grok.chatSystem(voice: voice), onNote: onNote, onText: onText)
        } else {
            try await Grok.chat(history, voice: voice, onNote: onNote, onText: onText)
        }
    }
}
