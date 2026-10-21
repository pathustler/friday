import Foundation

/// Minimal Model Context Protocol server over stdio (newline-delimited JSON-RPC 2.0).
/// Run as: /Applications/FRIDAY.app/Contents/MacOS/FRIDAY --mcp
enum MCPServer {
    static func run() {
        while let line = readLine(strippingNewline: true) {
            guard !line.isEmpty, let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let method = obj["method"] as? String else { continue }
            guard let id = obj["id"] else { continue }          // notifications need no reply
            let params = obj["params"] as? [String: Any] ?? [:]

            switch method {
            case "initialize":
                reply(id, ["protocolVersion": params["protocolVersion"] as? String ?? "2024-11-05",
                           "capabilities": ["tools": [String: Any]()],
                           "serverInfo": ["name": "friday", "version": "1.0"]])
            case "ping":
                reply(id, [String: Any]())
            case "tools/list":
                reply(id, ["tools": Tools.all.map(\.mcp)])
            case "tools/call":
                let name = params["name"] as? String ?? ""
                let known = Tools.all.contains { $0.name == name }
                let r = callSync(name, params["arguments"] as? [String: Any] ?? [:])
                // side channel so the F.R.I.D.A.Y panel can show "Opened Xcode" with icons when Claude Code drives this server
                if let path = ProcessInfo.processInfo.environment["FRIDAY_NOTES_FILE"], let note = r.note,
                   let d = try? JSONEncoder().encode(ChatNote(text: note, icons: r.icons, contacts: r.contacts, map: r.map, widget: r.widget)) {
                    if let h = FileHandle(forWritingAtPath: path) ?? (FileManager.default.createFile(atPath: path, contents: nil) ? FileHandle(forWritingAtPath: path) : nil) {
                        h.seekToEndOfFile()
                        h.write(d + Data("\n".utf8))
                        try? h.close()
                    }
                }
                reply(id, ["content": [["type": "text", "text": r.text]], "isError": !known])
            default:
                send(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found: \(method)"]])
            }
        }
    }

    /// Tools are async and main-actor; keep the main run loop turning while one runs (MapKit needs it).
    private static func callSync(_ name: String, _ args: [String: Any]) -> ToolResult {
        var result: ToolResult?
        Task { @MainActor in result = await Tools.call(name, args) }
        while result == nil { RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02)) }
        return result!
    }

    private static func reply(_ id: Any, _ result: [String: Any]) {
        send(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private static func send(_ obj: [String: Any]) {
        guard let d = try? JSONSerialization.data(withJSONObject: obj) else { return }
        FileHandle.standardOutput.write(d + Data("\n".utf8))
    }
}
