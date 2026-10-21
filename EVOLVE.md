# EVOLVE.md — how F.R.I.D.A.Y teaches itself new abilities

You are Claude Code, running inside a **copy** of the F.R.I.D.A.Y source tree. F.R.I.D.A.Y is a macOS launcher / voice assistant
(Swift 5.9, SwiftUI + AppKit, SwiftPM, one executable target `FRIDAY` in `Sources/FRIDAY`, macOS 14+). The user asked it for something
it cannot do yet, and approved you extending it. Your job: **add that ability, additively, and leave everything else working.**

## Hard rules

1. **New code goes in NEW files under `Sources/FRIDAY/Abilities/`** (one file per ability, e.g. `GitHubAbility.swift`).
2. The only existing file you may edit is `Sources/FRIDAY/Abilities/Registry.swift`: add **one line** to each property you use.
   Do not edit, rename or delete any other existing file unless it is truly impossible otherwise, and then keep the change minimal and
   explain it in `notes`. Never touch `Package.swift`, `build.sh`, `main.swift`, `Evolution.swift`, `Voice.swift`, `Whisper.swift`.
3. **No new dependencies.** No SwiftPM packages. Use `URLSession` + `JSONSerialization` / `Codable`.
4. macOS 14 APIs only. Swift 5 language mode. Match the surrounding style (comment density, naming).
5. You are in a **git worktree on a feature branch**. Do not run git yourself (the orchestrator commits your work). Stay inside this working directory. No `sudo`, no installing software, no editing dotfiles, no git, no deleting user data.
   Do not launch the GUI app. Do not run `build.sh install`.
6. **Never hard-code secrets.** Prefer public, unauthenticated endpoints. If a token is required (or lifts a rate limit for private data),
   call `Secrets.ask("GITHUB_TOKEN", why: "…")` at the moment it is needed (it shows a native hidden-input dialog and stores the answer
   in the Keychain). If the user cancels, return a helpful `ToolResult`, do not crash.
7. Every network call: set a `User-Agent`, a 15 s timeout, and return a readable error `ToolResult` on failure.
8. Anything destructive or that changes state on a remote service (push, delete, merge, post) is **out of scope** unless the request
   explicitly asks for it; read-only abilities are the default.

## Architecture in 60 seconds

- `Tools.swift` — `Tool(name:description:properties:required:run:)`; `run` is `@MainActor ([String: Any]) async -> ToolResult`.
  `ToolResult(text:note:icons:contacts:map:widget:)`: `text` is what the AI reads, `note` is a short status line, `widget` is a visual card.
- `Widgets.swift` — `Widget` enum of cards. **Use `.ui(UINode)` for visuals** (see below); don't add enum cases.
- `GenUI.swift` — `UINode` + `GenUIView`: a JSON component tree rendered with the app's glass design system. Built-in types:
  `card{title,subtitle,icon}`, `stack`, `row`, `grid{columns}`, `text{text,style,tone}`, `stat{label,value,unit,delta,tone,icon}`,
  `badge`, `kv{items:[{label,value}]}`, `list{items:[{title,subtitle,trailing,icon,tone,url}]}`, `table{columns,rows}`,
  `progress{label,value,detail,tone}`, `gauge`, `chart{kind:bar|line|donut,data:[{label,value}],unit}`, `steps{items:[{title,detail,done}]}`,
  `callout{tone,title,text}`, `quote`, `code`, `links{items:[{title,url}]}`, `image{url}`, `gallery`, `divider`. Tones: neutral/accent/good/warn/bad.
- **Design principles (follow them in anything visual):** one glass card; lead with the single most important thing; neutral surfaces,
  system colours, tone only for meaning; short labels; real numbers with units; no decoration. Use the built-ins whenever they can express it.
- Build nodes in Swift with `UINode.node("card", ["title": "…"], [children])`.
- **A brand-new visual** (e.g. a commit graph) = a SwiftUI view in your ability file, registered as a component:
  `AbilityRegistry.components` maps a `type` string to `(UINode) -> AnyView`. Read props via `node.str("k")`, `node.num("k")`,
  `node.rows("items")`, `node.props["k"]?.array`. Keep it native-looking (`Color.primary.opacity(0.05)` fills, `.secondary` text,
  `Color.accentColor`, `cardBackground()` for a glass card). Views that contain themselves must wrap children in `AnyView`.
- `Secrets.get/set/ask` — Keychain-backed tokens (see rule 6).
- The AI sees every registered tool automatically. Tell it *when* to use them via `AbilityRegistry.promptNotes` (a short string).

## Recipe

1. Read this file, `Sources/FRIDAY/Abilities/Registry.swift`, and skim `Tools.swift` + `GenUI.swift` for patterns.
2. Test the real API first with `curl` (public endpoints, small responses) so you know the actual JSON.
3. Create `Sources/FRIDAY/Abilities/<Name>Ability.swift`:

```swift
import SwiftUI

enum GitHubAbility {
    static let tools: [Tool] = [
        Tool(name: "github_repo_status",
             description: "Status of a GitHub repository: stars, open issues/PRs, latest commits and CI. Shows a visual card.",
             properties: ["repo": ["type": "string", "description": "owner/name, e.g. apple/swift"]],
             required: ["repo"]) { args in
            let repo = (args["repo"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            guard let url = URL(string: "https://api.github.com/repos/\(repo)") else { return ToolResult(text: "Bad repo name.") }
            var req = URLRequest(url: url)
            req.setValue("F.R.I.D.A.Y/1.0", forHTTPHeaderField: "User-Agent")
            req.timeoutInterval = 15
            guard let (data, _) = try? await URLSession.shared.data(for: req),
                  let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let name = o["full_name"] as? String
            else { return ToolResult(text: "Couldn't reach GitHub or the repo doesn't exist.") }
            let ui = UINode.node("card", ["title": name, "icon": "chevron.left.forwardslash.chevron.right"], [
                UINode.node("grid", ["columns": 3], [
                    UINode.node("stat", ["label": "Stars", "value": "\(o["stargazers_count"] ?? 0)", "icon": "star"]),
                ]),
            ])
            return ToolResult(text: "\(name): \(o["stargazers_count"] ?? 0) stars.", note: "GitHub: \(name)", widget: .ui(ui))
        },
    ]

    static let components: [String: (UINode) -> AnyView] = [:]      // e.g. "gitgraph": { AnyView(GitGraphView(node: $0)) }
    static let promptNotes = "GITHUB: for questions about a repository's status, commits, README or a user's profile call github_* tools; they draw cards."
}
```

4. Register it in `Registry.swift` with one line per property, e.g. `GitHubAbility.tools`, `GitHubAbility.components`,
   `GitHubAbility.promptNotes` (if you register several abilities, concatenate: `A.tools + B.tools`).
5. **Build until it compiles:** `swift build -c release 2>&1 | tail -30`. Fix every error. (Takes a few minutes the first time.)
6. **Test your tools through the built binary** (this is how the AI calls them):

```sh
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"github_repo_status","arguments":{"repo":"apple/swift"}}}' \
  | .build/release/FRIDAY --mcp
```

   Check the text is sensible. Existing tools must still be listed by `tools/list` (the build is regression-tested after you finish).
7. Offer the user a *useful family* of tools for the service, not just the one query that triggered this (for GitHub: repo status,
   recent commits / activity graph, README, user profile, issues/PRs, releases, CI status — whatever the public API supports).

## Finish: write `evolution-result.json` in the project root

```json
{
  "title": "GitHub",
  "summary": "I can now look up repositories, commit history, READMEs and profiles on GitHub.",
  "tools": ["github_repo_status", "github_recent_commits"],
  "examples": ["What's the status of apple/swift?", "Show the commit graph for torvalds/linux", "Who is gaearon on GitHub?"],
  "needs_secrets": [],
  "notes": "Anything unusual: files outside Abilities/ that you had to change, and why."
}
```

Then stop. Do not summarise at length; the orchestrator builds, regression-tests, backs up the current app, installs and restarts.
