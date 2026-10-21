import AppKit
import Foundation
import PDFKit

struct SearchResult: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let kind: String
    let icon: NSImage
    let run: () -> Void
    var reveal: (() -> Void)? = nil
    var contact: ContactCard? = nil   // set for people: the full card is previewed below the list
    var isPreview = false             // icon is a page preview (PDF), drawn as a small paper thumbnail
}

struct AppEntry {
    let name: String
    let url: URL
    let lower: String
    let initials: String
}

/// Indexes installed applications.
final class AppIndex {
    static let shared = AppIndex()
    private(set) var apps: [AppEntry] = []
    private(set) var shortcuts: [AppEntry] = []   // macOS Shortcuts app; url is unused

    func refresh() async {
        async let found = Task.detached(priority: .utility) { Self.scan() }.value
        async let names = Task.detached(priority: .utility) { Self.listShortcuts() }.value
        apps = await found
        shortcuts = await names
    }

    private static func listShortcuts() -> [AppEntry] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        p.arguments = ["list"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map { line in
            let name = String(line)
            let words = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            return AppEntry(name: name, url: URL(fileURLWithPath: "/"), lower: name.lowercased(),
                            initials: String(words.compactMap(\.first)).lowercased())
        }
    }

    /// Synchronous load for tools / MCP mode (no run loop needed).
    func loadIfNeeded() { if apps.isEmpty { apps = Self.scan() } }

    private static func scan() -> [AppEntry] {
        let fm = FileManager.default
        let roots = ["/Applications", "/System/Applications", "/System/Applications/Utilities",
                     "/System/Library/CoreServices", "/System/Library/CoreServices/Applications",
                     "/System/Cryptexes/App/System/Applications",     // Safari lives here on macOS 13+ (/Applications/Safari.app is a link)
                     "\(NSHomeDirectory())/Applications"]
        var seen = Set<String>()
        var out: [AppEntry] = []
        for root in roots {
            guard let e = fm.enumerator(at: URL(fileURLWithPath: root),
                                        includingPropertiesForKeys: nil,
                                        options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in e {
                if e.level > 2 { e.skipDescendants(); continue }
                guard url.pathExtension == "app" else { continue }
                // CoreServices: only include user-facing apps
                if root.hasSuffix("CoreServices"), !["Finder.app", "Siri.app"].contains(url.lastPathComponent) { continue }
                let name = fm.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
                guard seen.insert(name.lowercased()).inserted else { continue }
                let words = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                out.append(AppEntry(name: name, url: url, lower: name.lowercased(),
                                    initials: String(words.compactMap(\.first)).lowercased()))
            }
        }
        return out
    }

    static func score(_ q: String, _ a: AppEntry) -> Int? {
        let n = a.lower
        if n == q { return 100 }
        if n.hasPrefix(q) { return 90 }
        let words = n.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        if words.contains(where: { $0.hasPrefix(q) }) { return 75 }
        if q.count >= 2, a.initials.hasPrefix(q) { return 70 }
        if n.contains(q) { return 55 }
        if q.count >= 3 {
            var it = n.makeIterator()
            if q.allSatisfy({ c in while let x = it.next() { if x == c { return true } }; return false }) { return 30 }
        }
        return nil
    }
}

struct SystemCommand {
    let title: String
    let keywords: [String]
    let symbol: String
    let action: () -> Void
}

enum Commands {
    static func script(_ src: String) {
        var err: NSDictionary?
        NSAppleScript(source: src)?.executeAndReturnError(&err)
    }

    static func shell(_ path: String, _ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        try? p.run()
    }

    static let all: [SystemCommand] = [
        .init(title: "Lock Screen", keywords: ["lock", "sleep display"], symbol: "lock.fill") {
            shell("/usr/bin/pmset", ["displaysleepnow"])
        },
        .init(title: "Sleep", keywords: ["sleep", "suspend"], symbol: "moon.fill") {
            shell("/usr/bin/pmset", ["sleepnow"])
        },
        .init(title: "Toggle Dark Mode", keywords: ["dark", "light", "appearance", "theme"], symbol: "circle.lefthalf.filled") {
            script("tell application \"System Events\" to tell appearance preferences to set dark mode to not dark mode")
        },
        .init(title: "Empty Trash", keywords: ["trash", "bin", "delete"], symbol: "trash.fill") {
            script("tell application \"Finder\" to empty the trash")
        },
        .init(title: "Quit F.R.I.D.A.Y", keywords: ["exit", "quit"], symbol: "power") {
            NSApp.terminate(nil)
        },
    ]
}

enum FileSearch {
    /// Folder names that are never useful search results (dependencies, build output, caches).
    static let junk: Set<String> = [
        "node_modules", "venv", "env", "virtualenv", "site-packages", "__pycache__", "bower_components",
        "build", "dist", "out", "target", "DerivedData", "Pods", "Carthage", "vendor", "coverage",
        "tmp", "temp", "cache", "Caches", "logs", "bin", "obj", "deps", "_build", "storybook-static",
        "Applications", "Trash", "go", "cargo", "rustup", "gradle", "m2", "npm", "nvm", "pyenv", "conda",
        "anaconda3", "miniconda3", "opt", "usr", "lib", "include", "share", "eggs",
    ]

    /// Streams `mdfind -name` results and ranks them. Cancels the child process with the task.
    static func find(_ q: String) async -> [String] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        p.arguments = ["-onlyin", NSHomeDirectory(), "-name", q]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return [] }

        let lines: [String] = await withTaskCancellationHandler {
            var out: [String] = []
            do {
                for try await line in pipe.fileHandleForReading.bytes.lines {
                    if Task.isCancelled { break }
                    if line.contains("/Library/") || line.contains("/.") || line.contains(".app") { continue }
                    if line.hasSuffix(".egg-info") || line.split(separator: "/").contains(where: { junk.contains(String($0)) }) { continue }
                    var isDir: ObjCBool = false
                    guard FileManager.default.fileExists(atPath: line, isDirectory: &isDir), isDir.boolValue,
                          (try? URL(fileURLWithPath: line).resourceValues(forKeys: [.isPackageKey]))?.isPackage != true
                    else { continue }
                    out.append(line)
                    if out.count >= 300 { break }
                }
            } catch {}
            if p.isRunning { p.terminate() }
            return out
        } onCancel: {
            if p.isRunning { p.terminate() }
        }

        let ql = q.lowercased()
        func rank(_ path: String) -> Int {
            let name = (path as NSString).lastPathComponent.lowercased()
            var r = name.hasPrefix(ql) ? 0 : (name.contains(" \(ql)") ? 1 : 2)
            let home = NSHomeDirectory()
            if ["Documents", "Desktop", "Downloads"].contains(where: { path.hasPrefix("\(home)/\($0)/") }) { r -= 1 }
            return r
        }
        return lines.sorted { (rank($0), $0.count) < (rank($1), $1.count) }
    }
}

extension FileSearch {
    /// PDFs matched by file name or by the text inside them (Spotlight indexes PDF contents).
    /// Returns (path, matchedByName), name matches first.
    static func findPDFs(_ q: String) async -> [(path: String, byName: Bool)] {
        let clean = q.replacingOccurrences(of: "\\", with: " ").replacingOccurrences(of: "\"", with: " ")
            .replacingOccurrences(of: "*", with: " ").trimmingCharacters(in: .whitespaces)
        guard clean.count >= 2 else { return [] }
        var clauses = ["kMDItemFSName == \"*\(clean)*\"cd"]
        if clean.count >= 3 {   // full-text search inside PDFs, every word must appear
            let words = clean.split(separator: " ").map { "kMDItemTextContent == \"\($0)*\"cd" }
            clauses.append("(" + words.joined(separator: " && ") + ")")
        }
        let query = "kMDItemContentType == \"com.adobe.pdf\" && (" + clauses.joined(separator: " || ") + ")"

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        p.arguments = ["-onlyin", NSHomeDirectory(), query]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return [] }

        let lines: [String] = await withTaskCancellationHandler {
            var out: [String] = []
            do {
                for try await line in pipe.fileHandleForReading.bytes.lines {
                    if Task.isCancelled { break }
                    guard line.lowercased().hasSuffix(".pdf"),
                          !line.contains("/Library/") || line.contains("/Library/Mobile Documents/com~apple~CloudDocs/"),   // keep iCloud Drive
                          !line.contains("/."),
                          !line.split(separator: "/").contains(where: { junk.contains(String($0)) }) else { continue }
                    out.append(line)
                    if out.count >= 200 { break }
                }
            } catch {}
            if p.isRunning { p.terminate() }
            return out
        } onCancel: {
            if p.isRunning { p.terminate() }
        }

        let ql = clean.lowercased()
        let tagged = lines.map { path -> (path: String, byName: Bool) in
            (path, (path as NSString).lastPathComponent.lowercased().contains(ql))
        }
        func rank(_ e: (path: String, byName: Bool)) -> Int {
            let name = (e.path as NSString).lastPathComponent.lowercased()
            return e.byName ? (name.hasPrefix(ql) ? 0 : 1) : 2
        }
        return tagged.sorted { (rank($0), $0.path.count) < (rank($1), $1.path.count) }
    }
}

/// Live currency rates (open.er-api.com, no key needed), cached for an hour.
@MainActor
final class CurrencyRates {
    private(set) var rates: [String: Double] = [:]   // per 1 USD
    private var fetched = Date.distantPast
    private var fetching = false

    init() {
        // Last known rates are used instantly; a background refresh keeps them fresh.
        if let r = UserDefaults.standard.dictionary(forKey: "fxRates") as? [String: Double] { rates = r }
        if let d = UserDefaults.standard.object(forKey: "fxDate") as? Date { fetched = d }
    }

    var isReady: Bool { !rates.isEmpty }

    func refreshIfNeeded(then done: @escaping () -> Void) {
        guard !fetching, Date().timeIntervalSince(fetched) > 3600 || rates.isEmpty else { return }
        fetching = true
        Task {
            defer { fetching = false }
            guard let url = URL(string: "https://open.er-api.com/v6/latest/USD"),
                  let (data, _) = try? await URLSession.shared.data(from: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let r = json["rates"] as? [String: Double] else { return }
            rates = r
            fetched = Date()
            UserDefaults.standard.set(r, forKey: "fxRates")
            UserDefaults.standard.set(fetched, forKey: "fxDate")
            done()
        }
    }

    /// Flag emoji for a currency's country (first two letters of the ISO code), e.g. inr -> 🇮🇳.
    static func flag(for code: String) -> String? {
        let c = code.uppercased()
        let region = c == "EUR" ? "EU" : String(c.prefix(2))
        guard region == "EU" || Locale.Region.isoRegions.contains(where: { $0.identifier == region }) else { return nil }
        let scalars = region.unicodeScalars.compactMap { Unicode.Scalar(0x1F1E6 + $0.value - 65) }
        return String(String.UnicodeScalarView(scalars))
    }

    func convert(_ amount: Double, from: String, to: String) -> Double? {
        guard let f = rates[from.uppercased()], let t = rates[to.uppercased()], f > 0 else { return nil }
        return amount / f * t
    }

    private static let symbols: [Character: String] = ["$": "usd", "€": "eur", "£": "gbp", "¥": "jpy", "₹": "inr"]

    /// Parses "100 usd to eur", "$50 in eur", "(5+5)gbp->jpy" -> (amount, from, to).
    static func parse(_ raw: String) -> (Double, String, String)? {
        var s = raw.lowercased().trimmingCharacters(in: .whitespaces)
        var prefix: String?
        if let c = s.first, let code = symbols[c] { prefix = code; s.removeFirst() }
        let pattern = prefix == nil
            ? #"^(.+?)\s*([a-z]{3})\s*(?:to|in|into|->|=>|=)\s*([a-z]{3})$"#
            : #"^(.+?)\s*(?:to|in|into|->|=>|=)\s*([a-z]{3})$"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        func g(_ i: Int) -> String { String(s[Range(m.range(at: i), in: s)!]) }
        guard let amount = Calculator.value(g(1)) else { return nil }
        return prefix == nil ? (amount, g(2), g(3)) : (amount, prefix!, g(2))
    }
}

/// First-page thumbnails for PDFs (PDFKit), cached.
enum PDFThumb {
    private static let cache = NSCache<NSString, NSImage>()

    static func image(_ path: String) -> NSImage? {
        if let c = cache.object(forKey: path as NSString) { return c }
        guard let doc = PDFDocument(url: URL(fileURLWithPath: path)), !doc.isLocked, let page = doc.page(at: 0) else { return nil }
        let box = page.bounds(for: .cropBox)
        guard box.width > 1, box.height > 1 else { return nil }
        let scale = 160 / max(box.width, box.height)             // ~2x of the on-screen size
        let img = page.thumbnail(of: NSSize(width: box.width * scale, height: box.height * scale), for: .cropBox)
        cache.setObject(img, forKey: path as NSString)
        return img
    }
}
