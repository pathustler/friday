import AppKit
import Foundation
import ServiceManagement

/// Keeps F.R.I.D.A.Y running: starts at login and is restarted by launchd if it ever crashes.
/// Quitting from the menu (a clean exit) stays quit until the next login.
enum Autostart {
    static let label = "com.friday.app.agent"
    private static let disabledKey = "autostartDisabled"

    static var plistURL: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }
    static var enabled: Bool { FileManager.default.fileExists(atPath: plistURL.path) }
    private static var uid: String { "\(getuid())" }
    private static var startedByLaunchd: Bool { ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == label }

    /// Writes the launch agent (on by default, unless the user turned it off).
    static func ensureInstalled() {
        guard !UserDefaults.standard.bool(forKey: disabledKey), let exe = Bundle.main.executablePath else { return }
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [exe],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],          // restart after a crash, not after a normal quit
            "ThrottleInterval": 10,
            "ProcessType": "Interactive",
            "LimitLoadToSessionType": "Aqua",
        ]
        if let old = NSDictionary(contentsOf: plistURL) as? [String: Any], (old["ProgramArguments"] as? [String])?.first == exe { return }
        try? FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) { try? data.write(to: plistURL) }
        if SMAppService.mainApp.status == .enabled { try? SMAppService.mainApp.unregister() }     // one mechanism, not two
    }

    /// Only one F.R.I.D.A.Y may own the hotkey and the microphone. A newer instance waits briefly for an older one to leave.
    static func claimSingleInstance() -> Bool {
        let me = ProcessInfo.processInfo.processIdentifier
        func others() -> [NSRunningApplication] {
            NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "com.friday.app").filter { $0.processIdentifier != me }
        }
        for _ in 0..<60 where !others().isEmpty { Thread.sleep(forTimeInterval: 0.1) }
        return others().isEmpty
    }

    /// If the launch agent exists but launchd didn't start us (double-click, `open`, an upgrade), let launchd start the
    /// supervised copy and exit. Returns true when handed over; on any failure we simply keep running.
    static func handOverIfNeeded() -> Bool {
        guard enabled, !startedByLaunchd else { return false }
        _ = launchctl(["bootstrap", "gui/\(uid)", plistURL.path])                  // fails harmlessly if already loaded
        return launchctl(["kickstart", "-k", "gui/\(uid)/\(label)"]) == 0
    }

    static func enable() {
        UserDefaults.standard.set(false, forKey: disabledKey)
        _ = launchctl(["enable", "gui/\(uid)/\(label)"])
        ensureInstalled()
    }

    static func disable() {
        UserDefaults.standard.set(true, forKey: disabledKey)
        try? FileManager.default.removeItem(at: plistURL)
        _ = launchctl(["disable", "gui/\(uid)/\(label)"])           // not `bootout`: that would kill this very process
    }

    @discardableResult
    private static func launchctl(_ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }
}
