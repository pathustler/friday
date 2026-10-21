import Foundation

/// The bot's memory of the user: markdown files in ~/Documents/Me.
/// Read: every .md file is added to the system prompt. Write: the model emits
/// <remember file="x.md">…</remember> (append) or <rewrite file="x.md">…</rewrite> (replace, old copy kept in .history/).
enum Memory {
    static let folder = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents/Me")

    struct Action {
        enum Kind { case append, rewrite }
        let kind: Kind
        let file: String
        let body: String
    }

    // MARK: Read

    static func load(maxChars: Int = 30_000) -> String {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: folder, includingPropertiesForKeys: [.contentModificationDateKey],
                                    options: [.skipsHiddenFiles]) else { return "" }
        var files: [(URL, Date)] = []
        for case let url as URL in e where url.pathExtension.lowercased() == "md" {
            if e.level > 3 { continue }
            let d = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            files.append((url, d))
        }
        var out = ""
        for (url, _) in files.sorted(by: { $0.1 > $1.1 }) {   // most recently edited first
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let rel = url.path.replacingOccurrences(of: folder.path + "/", with: "")
            let chunk = "=== \(rel) ===\n\(text.trimmingCharacters(in: .whitespacesAndNewlines))\n\n"
            if out.count + chunk.count > maxChars { out += String(chunk.prefix(max(0, maxChars - out.count))); break }
            out += chunk
        }
        return out
    }

    // MARK: Parse the model's output

    private static let tag = try! NSRegularExpression(pattern: #"<(remember|rewrite)\s+file="([^"]+)"\s*>([\s\S]*?)</\1>"#)

    /// Splits a (possibly still streaming) reply into text to show and complete save actions.
    static func parse(_ raw: String) -> (display: String, actions: [Action]) {
        let ns = raw as NSString
        var actions: [Action] = []
        for m in tag.matches(in: raw, range: NSRange(location: 0, length: ns.length)) {
            actions.append(Action(kind: ns.substring(with: m.range(at: 1)) == "rewrite" ? .rewrite : .append,
                                  file: ns.substring(with: m.range(at: 2)),
                                  body: ns.substring(with: m.range(at: 3))))
        }
        var display = tag.stringByReplacingMatches(in: raw, range: NSRange(location: 0, length: ns.length), withTemplate: "")
        // hide an unfinished tag that is still streaming in
        if let lt = display.lastIndex(of: "<") {
            let tail = String(display[lt...])
            if "<remember".hasPrefix(tail) || "<rewrite".hasPrefix(tail) || tail.hasPrefix("<remember") || tail.hasPrefix("<rewrite") {
                display = String(display[..<lt])
            }
        }
        return (display.trimmingCharacters(in: .whitespacesAndNewlines), actions)
    }

    // MARK: Write

    private static func safeName(_ name: String) -> String? {
        var base = (name as NSString).lastPathComponent
        if base.lowercased().hasSuffix(".md") { base = String(base.dropLast(3)) }
        guard !base.isEmpty, base.count <= 60,
              base.allSatisfy({ $0.isLetter || $0.isNumber || $0 == " " || $0 == "-" || $0 == "_" }) else { return nil }
        return base + ".md"
    }

    /// Applies a save; returns a short note for the UI, or nil if rejected.
    static func apply(_ a: Action) -> String? {
        let fm = FileManager.default
        guard let name = safeName(a.file) else { return nil }
        let body = String(a.body.trimmingCharacters(in: .whitespacesAndNewlines).prefix(20_000))
        guard !body.isEmpty else { return nil }
        let url = folder.appendingPathComponent(name)
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            switch a.kind {
            case .append:
                if let old = try? String(contentsOf: url, encoding: .utf8), !old.isEmpty {
                    let sep = old.hasSuffix("\n") ? "\n" : "\n\n"
                    try (old + sep + body + "\n").write(to: url, atomically: true, encoding: .utf8)
                } else {
                    try (body + "\n").write(to: url, atomically: true, encoding: .utf8)
                }
            case .rewrite:
                if fm.fileExists(atPath: url.path) {
                    let hist = folder.appendingPathComponent(".history")
                    try fm.createDirectory(at: hist, withIntermediateDirectories: true)
                    let stamp = Int(Date().timeIntervalSince1970)
                    try? fm.copyItem(at: url, to: hist.appendingPathComponent("\(name.dropLast(3))-\(stamp).md"))
                }
                try (body + "\n").write(to: url, atomically: true, encoding: .utf8)
            }
            return "Saved to Me/\(name)"
        } catch {
            return nil
        }
    }
}
