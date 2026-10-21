import SwiftUI

/// What F.R.I.D.A.Y has taught itself. Each evolved ability lives in its own file in this folder and is hooked in by
/// ONE line in the properties below (see EVOLVE.md). The core app never needs to change to gain a new ability.
enum AbilityRegistry {
    /// New AI tools. Example: `GitHubAbility.tools`
    static var tools: [Tool] {
        []
    }

    /// New render_ui component types, keyed by the node's `type`. Example: `GitHubAbility.components`
    static var components: [String: (UINode) -> AnyView] {
        [:]
    }

    /// Plain-text guidance appended to the AI's instructions: when to use the new tools and the props of any new component.
    static var promptNotes: String {
        ""
    }
}

/// Record of an ability that was learned (stored in ~/Library/Application Support/FRIDAY/abilities.json).
struct AbilityInfo: Codable, Hashable {
    var title: String
    var summary: String
    var tools: [String]
    var examples: [String]
    var learned: Date
}

extension UINode {
    /// Convenience for building UI in Swift: `.node("stat", ["label": "Stars", "value": "1.2k"])`.
    static func node(_ type: String, _ props: [String: Any] = [:], _ children: [UINode] = []) -> UINode {
        UINode(type: type, props: props.mapValues { JSONValue(any: $0) }, children: children)
    }
}
