import AppKit
import Foundation
import SwiftUI

// MARK: - Review-first self-evolution
//
// F.R.I.D.A.Y can draft new abilities for itself, but a human stays in the loop at every step that matters:
//   1. you agree (in chat, then a native dialog) -> Claude Code drafts the change on a NEW GIT BRANCH in a separate worktree
//   2. the draft is built and regression-tested there; the live app and your source tree are never touched
//   3. you REVIEW what changed and click Install (or Discard) -> only then is the running app replaced (with a backup + auto rollback)
//   4. after you have used it regularly it ASKS whether to make it permanent; only a yes merges the branch into main

// MARK: - Data

struct EvolutionRequest: Codable {
    var id: String
    var capability: String
    var details: String
    var estimateMinutes: Int
}

struct EvolutionResult: Codable {
    var title: String
    var summary: String
    var tools: [String]
    var examples: [String]
    var needs_secrets: [String]?
    var notes: String?
}

struct EvolutionRecord: Codable, Identifiable {
    enum Status: String, Codable { case drafting, ready, installing, trial, merged, undone, discarded, failed }

    struct FileChange: Codable, Hashable { var path: String; var added: Int; var removed: Int }

    var id: String
    var capability: String
    var title: String
    var summary = ""
    var branch = ""
    var base = "main"
    var worktree = ""
    var tools: [String] = []
    var examples: [String] = []
    var files: [FileChange] = []
    var status = Status.drafting
    var error: String?
    var backup: String?
    var created = Date()
    var installed: Date?
    var uses = 0
    var useDays: [String] = []
    var askedToMerge = false

    var added: Int { files.reduce(0) { $0 + $1.added } }
    var removed: Int { files.reduce(0) { $0 + $1.removed } }
}

enum EvolvePaths {
    static let support = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/FRIDAY")
    static var root: URL { support.appendingPathComponent("evolve") }
    static var inbox: URL { root.appendingPathComponent("inbox") }
    static var backups: URL { support.appendingPathComponent("backups") }
    static var records: URL { support.appendingPathComponent("evolutions.json") }
    static var pending: URL { root.appendingPathComponent("pending.json") }
    static var status: URL { root.appendingPathComponent("status.json") }
    static var usage: URL { root.appendingPathComponent("usage.log") }
    static var rolledBack: URL { root.appendingPathComponent("rolled-back.json") }

    /// Where the source (a git repository) lives; recorded in the app bundle by build.sh.
    static var project: URL {
        if let r = Bundle.main.resourcePath, let s = try? String(contentsOfFile: r + "/source-path", encoding: .utf8) {
            return URL(fileURLWithPath: s.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Coding/spotai")
    }

    static func ensure() {
        for d in [root, inbox, backups] { try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
    }
}

/// Requests can come from the app itself or from the `--mcp` helper (when Claude Code is the engine), so they travel as a
/// small file plus a distributed notification that the running F.R.I.D.A.Y app listens for.
enum EvolutionInbox {
    static let name = Notification.Name("com.friday.evolve.request")

    static func submit(capability: String, details: String, minutes: Int) -> String {
        EvolvePaths.ensure()
        let id = String(UUID().uuidString.prefix(8)).lowercased()
        let req = EvolutionRequest(id: id, capability: capability, details: details, estimateMinutes: min(max(minutes, 3), 45))
        if let d = try? JSONEncoder().encode(req) { try? d.write(to: EvolvePaths.inbox.appendingPathComponent("\(id).json")) }
        DistributedNotificationCenter.default().postNotificationName(name, object: nil, userInfo: ["id": id], deliverImmediately: true)
        return id
    }

    /// Any process (app or --mcp helper) logs successful use of a tool; the app reads this to judge "regular use".
    static func noteToolUse(_ tool: String, ok: Bool) {
        guard ok else { return }
        EvolvePaths.ensure()
        let line = "\(Int(Date().timeIntervalSince1970))\t\(tool)\n"
        if let h = FileHandle(forWritingAtPath: EvolvePaths.usage.path) ?? (FileManager.default.createFile(atPath: EvolvePaths.usage.path, contents: nil) ? FileHandle(forWritingAtPath: EvolvePaths.usage.path) : nil) {
            h.seekToEndOfFile()
            h.write(Data(line.utf8))
            try? h.close()
        }
    }
}

// MARK: - Orchestrator

@MainActor
final class Evolution: ObservableObject {
    static let shared = Evolution()

    @Published private(set) var records: [EvolutionRecord] = []
    @Published private(set) var phase = "idle"            // live drafting step: understand | write | build | verify | idle
    @Published private(set) var log: [String] = []
    @Published private(set) var currentID = ""
    @Published private(set) var startedAt = Date()
    @Published private(set) var estimateMinutes = 10
    @Published private(set) var asking = false
    @Published var notice: String?

    /// Set by the app: show a message (with the upgrade card) in AI mode, and say it out loud if voice is on.
    var announce: (String, String?) -> Void = { _, _ in }

    private var drafting = false

    init() { records = Self.loadRecords() }

    var busy: Bool { drafting || asking }
    func record(_ id: String) -> EvolutionRecord? { records.first { $0.id == id } }

    // MARK: 1. a request arrives -> consent -> draft on a branch

    func handleRequest(id: String) {
        let file = EvolvePaths.inbox.appendingPathComponent("\(id).json")
        guard let data = try? Data(contentsOf: file), let req = try? JSONDecoder().decode(EvolutionRequest.self, from: data) else { return }
        try? FileManager.default.removeItem(at: file)
        guard !busy else { return }
        currentID = id
        estimateMinutes = req.estimateMinutes
        startedAt = Date()
        log = []
        var rec = EvolutionRecord(id: id, capability: req.capability, title: req.capability)
        asking = true
        upsert(rec)
        Task {
            let ok = await Task.detached { Self.confirmDraft(req) }.value
            asking = false
            guard ok else { rec.status = .discarded; rec.error = "Cancelled"; upsert(rec); return }
            await draft(req)
        }
    }

    /// Native, fail-closed consent. This only starts a DRAFT on a branch; nothing goes live without a second, explicit Install.
    nonisolated private static func confirmDraft(_ req: EvolutionRequest) -> Bool {
        let msg = "F.R.I.D.A.Y wants to draft a new ability:\n\n\(req.capability)\n\nClaude Code will write it on a NEW git branch in a separate copy of the source (about \(req.estimateMinutes) minutes, uses your Claude usage). Your running app and your files are not changed. You review the result and decide whether to install it."
        return runDialog(msg, title: "F.R.I.D.A.Y wants to evolve", ok: "Start drafting")
    }

    nonisolated private static func runDialog(_ message: String, title: String, ok: String, cancelDefault: Bool = false) -> Bool {
        func lit(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        let script = "tell current application\nactivate\ndisplay dialog \(lit(message)) with title \(lit(title)) buttons {\"Cancel\", \(lit(ok))} default button \(lit(cancelDefault ? "Cancel" : ok)) cancel button \"Cancel\" with icon caution giving up after 300\nend tell"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        return p.terminationStatus == 0 && !text.contains("gave up:true") && text.contains("button returned:\(ok)")
    }

    private func note(_ line: String) {
        log.append(line)
        if log.count > 60 { log.removeFirst(log.count - 60) }
        writeStatus()
    }

    private func setPhase(_ p: String) {
        phase = p
        writeStatus()
    }

    private func fail(_ rec: EvolutionRecord, _ message: String) {
        var r = rec
        r.status = .failed
        r.error = message
        upsert(r)
        drafting = false
        setPhase("idle")
        NSSound(named: "Basso")?.play()
        announce("I couldn't finish that upgrade. \(message) Nothing on your Mac was changed.", r.id)
    }

    func draft(_ req: EvolutionRequest) async {          // internal so tests can drive it; handleRequest still asks for consent first
        EvolvePaths.ensure()
        drafting = true
        var rec = record(req.id) ?? EvolutionRecord(id: req.id, capability: req.capability, title: req.capability)
        rec.status = .drafting
        upsert(rec)

        guard let claude = ClaudeCode.find() else {
            fail(rec, "Claude Code isn't installed. Install it from claude.com/claude-code and ask again."); return
        }
        let project = EvolvePaths.project
        guard Self.git(["rev-parse", "--is-inside-work-tree"], cwd: project).ok else { fail(rec, "My source folder (\(project.path)) isn't a git repository."); return }
        // a draft branches from a commit, so uncommitted edits would silently be missing from it
        guard Self.git(["status", "--porcelain"], cwd: project).output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            fail(rec, "Your source folder has uncommitted changes. Commit them first so my draft starts from exactly what's installed."); return
        }

        // 2. a branch + separate worktree (stacked on the newest installed-but-unmerged branch, so earlier upgrades are kept)
        setPhase("understand")
        let slug = req.capability.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).prefix(3).joined(separator: "-")
        let branch = "evolve/\(slug.isEmpty ? "ability" : slug)-\(req.id)"
        let base = records.filter { $0.status == .trial }.sorted { ($0.installed ?? .distantPast) > ($1.installed ?? .distantPast) }.first?.branch ?? "main"
        let jobDir = EvolvePaths.root.appendingPathComponent(req.id)
        let src = jobDir.appendingPathComponent("src")
        try? FileManager.default.removeItem(at: jobDir)
        try? FileManager.default.createDirectory(at: jobDir, withIntermediateDirectories: true)
        note("Creating branch \(branch)")
        let wt = Self.git(["worktree", "add", "-b", branch, src.path, base], cwd: project)
        guard wt.ok else { fail(rec, "Couldn't create a branch: \(wt.output.suffix(160))"); return }
        let vendor = project.appendingPathComponent("vendor")
        if FileManager.default.fileExists(atPath: vendor.path) { try? FileManager.default.createSymbolicLink(at: src.appendingPathComponent("vendor"), withDestinationURL: vendor) }
        rec.branch = branch
        rec.base = base
        rec.worktree = src.path
        upsert(rec)

        // 3. Claude Code drafts the change, confined to the worktree, with a short allow-list of tools
        note("Asking Claude Code to write the ability")
        let prompt = """
        Read EVOLVE.md in the project root first and follow it exactly.

        Capability to add: \(req.capability)
        Details from the user: \(req.details.isEmpty ? "(none)" : req.details)

        Work only inside this directory. When the build passes and you have tested the new tools, write evolution-result.json as described in EVOLVE.md and stop.
        """
        let code = await Self.stream(claude, ["-p", "--output-format", "stream-json", "--verbose", "--permission-mode", "acceptEdits",
                                              "--allowedTools", "Read Write Edit MultiEdit Glob Grep WebFetch Bash(swift build:*) Bash(curl:*) Bash(ls:*) Bash(cat:*) Bash(printf:*) Bash(head:*) Bash(tail:*) Bash(grep:*) Bash(.build/release/FRIDAY:*)",
                                              "--max-turns", "80", "--model", UserDefaults.standard.string(forKey: "evolveModel") ?? "sonnet",
                                              "--no-session-persistence", "--setting-sources", "project", "--disable-slash-commands"],
                                     cwd: src, stdin: prompt, timeout: 45 * 60) { [weak self] line in
            Task { @MainActor in self?.consume(claudeLine: line) }
        }
        if code != 0 { note("Claude Code exited with status \(code)") }

        guard let data = try? Data(contentsOf: src.appendingPathComponent("evolution-result.json")),
              let result = try? JSONDecoder().decode(EvolutionResult.self, from: data), !result.tools.isEmpty else {
            fail(rec, "The draft wasn't finished (no result was produced)."); return
        }

        // 4. build it ourselves and regression-test: every existing tool must still exist, the new ones must exist too
        setPhase("build")
        note("Building the draft")
        var tail: [String] = []
        let build = await Self.stream("/bin/bash", ["./build.sh"], cwd: src, timeout: 20 * 60) { line in tail.append(line); if tail.count > 40 { tail.removeFirst() } }
        let app = src.appendingPathComponent("FRIDAY.app")
        guard build == 0, FileManager.default.fileExists(atPath: app.path) else {
            fail(rec, "The draft didn't build. " + (tail.last(where: { $0.contains("error:") }) ?? "")); return
        }
        setPhase("verify")
        note("Checking nothing broke")
        let before = Set(Tools.all.map(\.name))
        guard let after = await Self.toolNames(binary: app.appendingPathComponent("Contents/MacOS/FRIDAY").path) else {
            fail(rec, "The draft didn't pass its start-up check."); return
        }
        let missing = before.subtracting(after).union(Set(result.tools).subtracting(after))
        guard missing.isEmpty else { fail(rec, "The draft broke or lost tools: \(missing.sorted().joined(separator: ", "))."); return }

        // 5. commit on the branch and prepare the review (the live app is still untouched)
        _ = Self.git(["add", "-A"], cwd: src)
        let msg = "\(result.title): \(result.summary)\n\nDrafted by F.R.I.D.A.Y with Claude Code (request: \(req.capability))"
        let commit = Self.git(["-c", "user.name=F.R.I.D.A.Y", "-c", "user.email=friday@localhost", "commit", "-q", "-m", msg], cwd: src)
        guard commit.ok else { fail(rec, "Nothing was changed by the draft."); return }
        let numstat = Self.git(["diff", "--numstat", "\(base)...HEAD"], cwd: src).output
        rec.files = numstat.split(separator: "\n").compactMap { l -> EvolutionRecord.FileChange? in
            let f = l.split(separator: "\t")
            guard f.count == 3 else { return nil }
            return .init(path: String(f[2]), added: Int(f[0]) ?? 0, removed: Int(f[1]) ?? 0)
        }
        _ = Self.git(["diff", "\(base)...HEAD"], cwd: src).output.data(using: .utf8).map { try? $0.write(to: jobDir.appendingPathComponent("changes.patch")) }
        rec.title = result.title
        rec.summary = result.summary
        rec.tools = result.tools
        rec.examples = result.examples
        rec.status = .ready
        upsert(rec)
        drafting = false
        setPhase("idle")
        NSSound(named: "Glass")?.play()
        announce("I've drafted **\(result.title)** on its own branch and checked that nothing broke. It isn't installed yet. Have a look at what changed, then install it or discard it.", rec.id)
    }

    private func consume(claudeLine line: String) {
        guard let o = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any], o["type"] as? String == "assistant",
              let content = (o["message"] as? [String: Any])?["content"] as? [[String: Any]] else { return }
        for c in content where c["type"] as? String == "tool_use" {
            let name = c["name"] as? String ?? "", input = c["input"] as? [String: Any] ?? [:]
            let file = ((input["file_path"] as? String) ?? (input["path"] as? String)).map { ($0 as NSString).lastPathComponent }
            switch name {
            case "Edit", "Write", "MultiEdit": setPhase("write"); note("Writing \(file ?? "code")")
            case "Read": note("Reading \(file ?? "code")")
            case "Grep", "Glob": note("Searching my code")
            case "WebFetch", "WebSearch": note("Reading the API docs")
            case "Bash":
                let cmd = input["command"] as? String ?? ""
                if cmd.contains("swift build") { setPhase("build"); note("Building to check the work") }
                else if cmd.contains("curl") { note("Trying the real API") }
                else if cmd.contains("--mcp") || cmd.contains(".build/release/FRIDAY") { note("Testing the new tools") }
            default: break
            }
        }
    }

    // MARK: 2. you review, then install or discard

    func discard(_ id: String) {
        guard var r = record(id), r.status == .ready || r.status == .failed else { return }
        let project = EvolvePaths.project
        if !r.worktree.isEmpty { _ = Self.git(["worktree", "remove", "--force", r.worktree], cwd: project) }
        if !r.branch.isEmpty { _ = Self.git(["branch", "-D", r.branch], cwd: project) }
        r.status = .discarded
        upsert(r)
    }

    func openChanges(_ id: String) {
        let patch = EvolvePaths.root.appendingPathComponent(id).appendingPathComponent("changes.patch")
        if FileManager.default.fileExists(atPath: patch.path) { NSWorkspace.shared.open(patch) }
    }

    /// Install = the one point where the running app is replaced. Back up, swap after quitting, and roll back if it won't start.
    func install(_ id: String) {
        guard var r = record(id), r.status == .ready else { return }
        let app = URL(fileURLWithPath: r.worktree).appendingPathComponent("FRIDAY.app")
        guard FileManager.default.fileExists(atPath: app.path) else { notice = "The built app is missing; discard this draft and ask again."; return }
        let target = URL(fileURLWithPath: Bundle.main.bundlePath)
        let backup = EvolvePaths.backups.appendingPathComponent("FRIDAY-\(id).app")
        let stage = EvolvePaths.root.appendingPathComponent(id).appendingPathComponent("staged.app")
        r.status = .installing
        r.backup = backup.path
        upsert(r)
        Task {
            let jobDir = EvolvePaths.root.appendingPathComponent(id)
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.removeItem(at: stage)
            let ok1 = await Self.stream("/usr/bin/ditto", [target.path, backup.path], cwd: jobDir, timeout: 120) { _ in } == 0
            let ok2 = await Self.stream("/usr/bin/ditto", [app.path, stage.path], cwd: jobDir, timeout: 120) { _ in } == 0
            guard ok1, ok2 else {
                r.status = .ready
                upsert(r)
                notice = "Couldn't prepare the install (backup or copy failed). Nothing was changed."
                return
            }
            try? EvolvePaths.project.path.write(toFile: stage.path + "/Contents/Resources/source-path", atomically: true, encoding: .utf8)
            Self.pruneBackups(keep: 3)
            try? JSONEncoder().encode(["id": id]).write(to: EvolvePaths.pending)
            let script = Self.writeLauncher()
            Self.spawn(script, ["update", "\(ProcessInfo.processInfo.processIdentifier)", EvolvePaths.root.appendingPathComponent("healthy-\(id)").path,
                                backup.path, target.path, stage.path, "30", "FRIDAY"])
            WhisperServer.shared.stop()
            try? await Task.sleep(nanoseconds: 700_000_000)
            NSApp.terminate(nil)
        }
    }

    /// Runs after every launch: confirms a fresh install is healthy, starts its trial, and greets you.
    func afterLaunch() {
        if let d = try? Data(contentsOf: EvolvePaths.rolledBack) {
            try? FileManager.default.removeItem(at: EvolvePaths.rolledBack)
            let why = (try? JSONSerialization.jsonObject(with: d) as? [String: Any])?["reason"] as? String ?? "it didn't start cleanly"
            if let id = (try? Data(contentsOf: EvolvePaths.pending)).flatMap({ try? JSONDecoder().decode([String: String].self, from: $0) })?["id"], var r = record(id) {
                r.status = .failed
                r.error = "The new version \(why)."
                upsert(r)
                try? FileManager.default.removeItem(at: EvolvePaths.pending)
            }
            announce("I tried to install the upgrade, but \(why), so I put the previous version back. Nothing is lost.", nil)
            return
        }
        if let d = try? Data(contentsOf: EvolvePaths.pending), let id = (try? JSONDecoder().decode([String: String].self, from: d))?["id"], var r = record(id) {
            Task {
                try? await Task.sleep(nanoseconds: 6_000_000_000)                  // stayed up for a few seconds: healthy
                try? "ok".write(to: EvolvePaths.root.appendingPathComponent("healthy-\(id)"), atomically: true, encoding: .utf8)
                try? FileManager.default.removeItem(at: EvolvePaths.pending)
                r.status = .trial
                r.installed = Date()
                upsert(r)
                var text = "I'm ready. **\(r.title)** is now part of me. \(r.summary)"
                if !r.examples.isEmpty { text += "\n\nTry asking:\n" + r.examples.prefix(4).map { "- “\($0)”" }.joined(separator: "\n") }
                text += "\n\nWhat do you want to know?"
                announce(text, id)
            }
        }
        checkTrials()
    }

    // MARK: 3. regular use -> ask to make it permanent -> merge

    /// "Regular use" = the new tools were used successfully at least 5 times on at least 3 different days.
    func checkTrials() {
        guard let log = try? String(contentsOf: EvolvePaths.usage, encoding: .utf8) else { return }
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        var changed = false
        for i in records.indices where records[i].status == .trial {
            let since = Int(records[i].installed?.timeIntervalSince1970 ?? 0)
            var uses = 0
            var days = Set<String>()
            for line in log.split(separator: "\n") {
                let f = line.split(separator: "\t")
                guard f.count == 2, let t = Int(f[0]), t >= since, records[i].tools.contains(String(f[1])) else { continue }
                uses += 1
                days.insert(df.string(from: Date(timeIntervalSince1970: TimeInterval(t))))
            }
            if uses != records[i].uses || days.count != records[i].useDays.count { records[i].uses = uses; records[i].useDays = days.sorted(); changed = true }
            if uses >= 5, days.count >= 3, !records[i].askedToMerge {
                records[i].askedToMerge = true
                changed = true
                announce("You've been using **\(records[i].title)** regularly (\(uses) times over \(days.count) days). Want me to make it permanent by merging it into main?", records[i].id)
            }
        }
        if changed { save() }
    }

    /// Merge the branch into main in your real repository. Only if the repo is on main with a clean tree; aborts on any conflict.
    func merge(_ id: String) {
        guard var r = record(id), r.status == .trial else { return }
        let project = EvolvePaths.project
        let branch = Self.git(["rev-parse", "--abbrev-ref", "HEAD"], cwd: project).output.trimmingCharacters(in: .whitespacesAndNewlines)
        let dirty = !Self.git(["status", "--porcelain"], cwd: project).output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard branch == "main" else { notice = "Your source folder is on '\(branch)', not main. Switch to main and try again."; return }
        guard !dirty else { notice = "Your source folder has uncommitted changes. Commit or stash them, then try again."; return }
        let m = Self.git(["merge", "--no-ff", "-m", "Merge \(r.branch): \(r.title)", r.branch], cwd: project)
        guard m.ok else {
            _ = Self.git(["merge", "--abort"], cwd: project)
            notice = "The merge has conflicts, so I aborted it. Your main branch is unchanged. The branch \(r.branch) is still there."
            return
        }
        r.status = .merged
        upsert(r)
        if !r.worktree.isEmpty { _ = Self.git(["worktree", "remove", "--force", r.worktree], cwd: project) }
        _ = Self.git(["branch", "-d", r.branch], cwd: project)
        // earlier upgrades this branch was stacked on are now part of main too
        for i in records.indices where records[i].status == .trial && Self.git(["merge-base", "--is-ancestor", records[i].branch, "main"], cwd: project).ok {
            records[i].status = .merged
        }
        save()
        notice = "\(r.title) is now permanent: merged into main."
    }

    func notNow(_ id: String) {
        guard var r = record(id) else { return }
        r.askedToMerge = true
        upsert(r)
    }

    /// Undo the newest installed upgrade: put the pre-install backup back and restart.
    func undo(_ id: String) {
        guard var r = record(id), r.status == .trial, let backup = r.backup, FileManager.default.fileExists(atPath: backup) else {
            notice = "I don't have a backup to go back to."; return
        }
        let newest = records.filter { $0.status == .trial }.max { ($0.installed ?? .distantPast) < ($1.installed ?? .distantPast) }
        guard newest?.id == id else { notice = "Undo the newer upgrade first."; return }
        Task {
            let title = r.title
            let confirmed = await Task.detached { Self.runDialog("Go back to F.R.I.D.A.Y as it was before “\(title)”? It will restart. The branch is kept.", title: "Undo upgrade", ok: "Undo it", cancelDefault: true) }.value
            guard confirmed else { return }
            r.status = .undone
            upsert(r)
            let script = Self.writeLauncher()
            Self.spawn(script, ["restore", "\(ProcessInfo.processInfo.processIdentifier)", "", backup, Bundle.main.bundlePath, "", "0", "FRIDAY"])
            WhisperServer.shared.stop()
            try? await Task.sleep(nanoseconds: 500_000_000)
            NSApp.terminate(nil)
        }
    }

    // MARK: records

    private func upsert(_ r: EvolutionRecord) {
        if let i = records.firstIndex(where: { $0.id == r.id }) { records[i] = r } else { records.append(r) }
        save()
    }

    private func save() {
        EvolvePaths.ensure()
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(records) { try? d.write(to: EvolvePaths.records) }
    }

    nonisolated private static func loadRecords() -> [EvolutionRecord] {
        guard let d = try? Data(contentsOf: EvolvePaths.records) else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode([EvolutionRecord].self, from: d)) ?? []
    }

    private func writeStatus() {
        EvolvePaths.ensure()
        let o: [String: Any] = ["id": currentID, "phase": phase, "drafting": drafting, "started": startedAt.timeIntervalSince1970, "log": Array(log.suffix(8))]
        if let d = try? JSONSerialization.data(withJSONObject: o) { try? d.write(to: EvolvePaths.status) }
    }

    /// For the AI's instructions: what has been learned (installed upgrades).
    nonisolated static func abilitiesSummary() -> String {
        let live = loadRecords().filter { $0.status == .trial || $0.status == .merged }
        return live.isEmpty ? "(none yet)" : live.map { "- \($0.title): \($0.summary) Tools: \($0.tools.joined(separator: ", "))." }.joined(separator: "\n")
    }

    /// Plain-text status for the AI / for `evolution_status`.
    nonisolated static func statusText() -> String {
        let recs = loadRecords()
        guard !recs.isEmpty else { return "No upgrades yet." }
        return recs.suffix(8).map { r in
            var s = "- \(r.title) [\(r.status.rawValue)]"
            if r.status == .ready { s += " — drafted on branch \(r.branch): \(r.files.count) files, +\(r.added) −\(r.removed). Waiting for the user to review and install." }
            if r.status == .trial { s += " — installed, used \(r.uses) times over \(r.useDays.count) days (asks to merge after 5 uses on 3 days)." }
            if let e = r.error, r.status == .failed { s += " — \(e)" }
            return s
        }.joined(separator: "\n")
    }

    // MARK: process helpers

    @discardableResult
    nonisolated static func git(_ args: [String], cwd: URL) -> (ok: Bool, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["git"] + args
        p.currentDirectoryURL = cwd
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        guard (try? p.run()) != nil else { return (false, "") }
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        return (p.terminationStatus == 0, text)
    }

    nonisolated private static func pruneBackups(keep: Int) {
        let urls = ((try? FileManager.default.contentsOfDirectory(at: EvolvePaths.backups, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.pathExtension == "app" }
            .sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) >
                      ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        for u in urls.dropFirst(keep) { try? FileManager.default.removeItem(at: u) }
    }

    /// Runs `binary --mcp` and lists its tools (also proves the build starts).
    nonisolated static func toolNames(binary: String) async -> Set<String>? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: binary)
        p.arguments = ["--mcp"]
        let inp = Pipe(), out = Pipe()
        p.standardInput = inp
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        DispatchQueue.global().asyncAfter(deadline: .now() + 30) { if p.isRunning { p.terminate() } }
        inp.fileHandleForWriting.write(Data("""
        {"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}
        {"jsonrpc":"2.0","id":2,"method":"tools/list"}

        """.utf8))
        try? inp.fileHandleForWriting.close()
        let data = await Task.detached { out.fileHandleForReading.readDataToEndOfFile() }.value
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            if let o = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any], o["id"] as? Int == 2,
               let tools = (o["result"] as? [String: Any])?["tools"] as? [[String: Any]] {
                return Set(tools.compactMap { $0["name"] as? String })
            }
        }
        return nil
    }

    /// Streams a process' combined output line by line. Returns its exit status (or -1 on timeout / launch failure).
    nonisolated static func stream(_ exe: String, _ args: [String], cwd: URL, stdin: String? = nil, timeout: TimeInterval,
                                   onLine: @escaping (String) -> Void) async -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.currentDirectoryURL = cwd
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + (env["PATH"] ?? "")
        p.environment = env
        let pipe = Pipe(), input = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = input
        guard (try? p.run()) != nil else { return -1 }
        if let s = stdin { input.fileHandleForWriting.write(Data(s.utf8)) }
        try? input.fileHandleForWriting.close()
        var timedOut = false
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if p.isRunning { timedOut = true; p.terminate() } }
        do { for try await line in pipe.fileHandleForReading.bytes.lines { onLine(line) } } catch {}
        p.waitUntilExit()
        return timedOut ? -1 : p.terminationStatus
    }

    nonisolated static func spawn(_ script: String, _ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [script] + args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        try? p.run()
    }

    /// The detached helper that outlives this process: waits for the app to quit, swaps the bundle, starts it, and if the
    /// new version never reports healthy within the time limit, puts the backup back.
    nonisolated static func writeLauncher() -> String {
        let path = EvolvePaths.root.appendingPathComponent("launcher.sh").path
        let sh = #"""
        #!/bin/sh
        # launcher.sh MODE OLDPID HEALTHFILE BACKUP TARGET STAGED SECONDS PROCNAME
        MODE="$1"; OLD="$2"; HEALTH="$3"; BACKUP="$4"; TARGET="$5"; STAGED="$6"; SECS="$7"; NAME="$8"
        OPEN="${OPENCMD:-/usr/bin/open}"
        i=0; while kill -0 "$OLD" 2>/dev/null && [ $i -lt 40 ]; do sleep 0.5; i=$((i+1)); done
        sleep 1
        if [ "$MODE" = "restore" ]; then
          rm -rf "$TARGET"; /usr/bin/ditto "$BACKUP" "$TARGET"; "$OPEN" "$TARGET"; exit 0
        fi
        rm -rf "$TARGET"; /usr/bin/ditto "$STAGED" "$TARGET"
        "$OPEN" "$TARGET"
        i=0; while [ $i -lt "$SECS" ]; do [ -f "$HEALTH" ] && exit 0; sleep 1; i=$((i+1)); done
        pkill -x "$NAME" 2>/dev/null; sleep 1
        rm -rf "$TARGET"; /usr/bin/ditto "$BACKUP" "$TARGET"
        printf '{"reason":"the new version did not start cleanly"}' > "$(dirname "$HEALTH")/rolled-back.json"
        "$OPEN" "$TARGET"
        """#
        try? sh.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }
}

// MARK: - The upgrade card (lives in chat; always shows the current state)

struct EvolutionCardView: View {
    let id: String
    @ObservedObject private var job = Evolution.shared

    private static let steps: [(String, String, String)] = [("Understand", "magnifyingglass", "understand"), ("Write", "chevron.left.forwardslash.chevron.right", "write"),
                                                            ("Build", "hammer", "build"), ("Verify", "checkmark.shield", "verify")]

    var body: some View {
        let r = job.record(id)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles").font(.system(size: 17)).foregroundStyle(.secondary).frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(r?.title ?? "Upgrade").font(.system(size: 16, weight: .semibold)).lineLimit(2)
                    Text(subtitle(r)).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if let r, r.status == .ready || r.status == .trial || r.status == .merged {
                    Text(r.branch.isEmpty ? "" : r.branch).font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary).lineLimit(1)
                }
            }

            if let r {
                switch r.status {
                case .drafting: drafting
                case .ready: review(r)
                case .trial: trial(r)
                case .failed: callout(r.error ?? "Something went wrong.", Color(nsColor: .systemRed))
                default: EmptyView()
                }
            } else {
                Text("This upgrade is no longer tracked.").font(.system(size: 13)).foregroundStyle(.secondary)
            }

            if let n = job.notice { callout(n, Color.accentColor) }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground())
    }

    private func subtitle(_ r: EvolutionRecord?) -> String {
        guard let r else { return "" }
        switch r.status {
        case .drafting:
            if job.asking { return "Waiting for your approval…" }
            let s = Int(Date().timeIntervalSince(job.startedAt))
            return "Drafting on a branch · \(s / 60):\(String(format: "%02d", s % 60)) of about \(job.estimateMinutes) min"
        case .ready: return "Ready for your review · not installed"
        case .installing: return "Installing and restarting…"
        case .trial: return r.uses == 0 ? "Installed · on trial" : "Installed · used \(r.uses)× over \(r.useDays.count) day\(r.useDays.count == 1 ? "" : "s")"
        case .merged: return "Permanent · merged into main"
        case .undone: return "Undone · branch kept"
        case .discarded: return r.error ?? "Discarded"
        case .failed: return "Didn't work · nothing was changed"
        }
    }

    private var drafting: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !job.asking {
                HStack(spacing: 0) {
                    ForEach(Array(Self.steps.enumerated()), id: \.offset) { i, s in
                        let cur = Self.steps.firstIndex { $0.2 == job.phase } ?? 0
                        VStack(spacing: 6) {
                            ZStack {
                                Circle().fill(i < cur ? Color(nsColor: .systemGreen) : (i == cur ? Color.accentColor : Color.primary.opacity(0.1))).frame(width: 30, height: 30)
                                Image(systemName: i < cur ? "checkmark" : s.1).font(.system(size: 12, weight: .semibold)).foregroundStyle(i <= cur ? Color.white : Color.secondary)
                            }
                            Text(s.0).font(.system(size: 11)).foregroundStyle(i == cur ? Color.primary : Color.secondary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(job.log.suffix(4).enumerated()), id: \.offset) { _, l in
                        Text(l).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
            }
        }
    }

    private func review(_ r: EvolutionRecord) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(r.summary).font(.system(size: 14)).foregroundStyle(.primary.opacity(0.9))
            HStack(spacing: 8) {
                pill("\(r.files.count) file\(r.files.count == 1 ? "" : "s")")
                pill("+\(r.added)", Color(nsColor: .systemGreen))
                pill("−\(r.removed)", Color(nsColor: .systemRed))
                pill("\(r.tools.count) tool\(r.tools.count == 1 ? "" : "s")")
            }
            VStack(spacing: 0) {
                ForEach(Array(r.files.prefix(6).enumerated()), id: \.offset) { i, f in
                    if i > 0 { Divider().opacity(0.4) }
                    HStack {
                        Text(f.path).font(.system(size: 12, design: .monospaced)).foregroundStyle(.primary.opacity(0.85)).lineLimit(1)
                        Spacer()
                        Text("+\(f.added)").font(.system(size: 12).monospacedDigit()).foregroundStyle(Color(nsColor: .systemGreen))
                        Text("−\(f.removed)").font(.system(size: 12).monospacedDigit()).foregroundStyle(Color(nsColor: .systemRed))
                    }
                    .padding(.vertical, 5)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
            HStack(spacing: 8) {
                Button("Install") { job.install(r.id) }.buttonStyle(.borderedProminent).controlSize(.regular)
                Button("View changes") { job.openChanges(r.id) }.buttonStyle(.bordered).controlSize(.regular)
                Button("Discard") { job.discard(r.id) }.buttonStyle(.bordered).controlSize(.regular)
                Spacer()
            }
        }
    }

    private func trial(_ r: EvolutionRecord) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if r.askedToMerge {
                Text("Happy with it? Making it permanent merges the branch into main.").font(.system(size: 13)).foregroundStyle(.secondary)
            } else {
                Text("It's on trial. After a few days of regular use I'll ask whether to make it permanent.").font(.system(size: 13)).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Button("Make permanent") { job.merge(r.id) }.buttonStyle(.borderedProminent).controlSize(.regular)
                Button("Undo") { job.undo(r.id) }.buttonStyle(.bordered).controlSize(.regular)
                if r.askedToMerge { Button("Not yet") { job.notNow(r.id) }.buttonStyle(.bordered).controlSize(.regular) }
                Spacer()
            }
        }
    }

    private func pill(_ t: String, _ c: Color = .primary) -> some View {
        Text(t).font(.system(size: 12, weight: .medium)).foregroundStyle(c == .primary ? Color.primary.opacity(0.8) : c)
            .padding(.horizontal, 10).frame(height: 24).background(Capsule().fill(Color.primary.opacity(0.08)))
    }

    private func callout(_ text: String, _ tint: Color) -> some View {
        Text(text).font(.system(size: 13)).foregroundStyle(.primary.opacity(0.88))
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(tint.opacity(0.12)))
    }
}
