import AppKit
import Charts
import SwiftUI

// MARK: - Spec: a tiny, forgiving JSON component tree the AI can emit

enum JSONValue: Codable, Hashable {
    case string(String), number(Double), bool(Bool), array([JSONValue]), object([String: JSONValue]), null

    init(any: Any?, depth: Int = 0) {
        guard depth < 5 else { self = .null; return }
        switch any {
        case let s as String: self = .string(String(s.prefix(600)))
        case let b as Bool where type(of: any!) == type(of: true as Any): self = .bool(b)
        case let n as NSNumber: self = .number(n.doubleValue)
        case let a as [Any]: self = .array(a.prefix(40).map { JSONValue(any: $0, depth: depth + 1) })
        case let o as [String: Any]: self = .object(Dictionary(uniqueKeysWithValues: o.prefix(24).map { ($0.key, JSONValue(any: $0.value, depth: depth + 1)) }))
        default: self = .null
        }
    }

    init(from d: Decoder) throws {
        let c = try d.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    func encode(to e: Encoder) throws {
        var c = e.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }

    var string: String? {
        switch self {
        case .string(let s): return s
        case .number(let n): return n == n.rounded() && abs(n) < 1e15 ? String(Int64(n)) : String(n)
        case .bool(let b): return b ? "true" : "false"
        default: return nil
        }
    }
    var double: Double? {
        switch self {
        case .number(let n): return n
        case .string(let s): return Double(s.filter { $0.isNumber || $0 == "." || $0 == "-" })
        default: return nil
        }
    }
    var array: [JSONValue] { if case .array(let a) = self { return a }; return [] }
    var object: [String: JSONValue] { if case .object(let o) = self { return o }; return [:] }
}

struct UINode: Codable, Hashable {
    var type: String
    var props: [String: JSONValue] = [:]
    var children: [UINode] = []

    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    init(type: String, props: [String: JSONValue] = [:], children: [UINode] = []) {
        self.type = type; self.props = props; self.children = children
    }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: Key.self)
        type = try c.decode(String.self, forKey: Key(stringValue: "type"))
        children = (try? c.decode([UINode].self, forKey: Key(stringValue: "children"))) ?? []
        for k in c.allKeys where k.stringValue != "type" && k.stringValue != "children" {
            props[k.stringValue] = try c.decode(JSONValue.self, forKey: k)
        }
    }

    func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: Key.self)
        try c.encode(type, forKey: Key(stringValue: "type"))
        if !children.isEmpty { try c.encode(children, forKey: Key(stringValue: "children")) }
        for (k, v) in props { try c.encode(v, forKey: Key(stringValue: k)) }
    }

    /// Builds a validated tree from whatever JSON the model produced: bounded depth, size and string lengths.
    static func sanitize(_ any: Any?, depth: Int = 0, budget: inout Int) -> UINode? {
        guard depth < 7, budget > 0, let o = any as? [String: Any] else { return nil }
        budget -= 1
        let type = ((o["type"] ?? o["component"]) as? String ?? "").lowercased().trimmingCharacters(in: .whitespaces)
        guard !type.isEmpty else { return nil }
        var node = UINode(type: type)
        for (k, v) in o where !["type", "component", "children"].contains(k) { node.props[k] = JSONValue(any: v) }
        node.children = (o["children"] as? [Any] ?? []).prefix(24).compactMap { sanitize($0, depth: depth + 1, budget: &budget) }
        return node
    }

    func str(_ k: String) -> String? { props[k]?.string.flatMap { $0.isEmpty ? nil : $0 } }
    func num(_ k: String) -> Double? { props[k]?.double }
    func rows(_ k: String) -> [[String: JSONValue]] { (props[k]?.array ?? []).compactMap { v -> [String: JSONValue]? in
        if case .object(let o) = v { return o }
        if let s = v.string { return ["title": .string(s)] }
        return nil
    } }
}

// MARK: - Design system tokens

private enum Tone {
    case neutral, accent, good, warn, bad
    init(_ s: String?) {
        switch s?.lowercased() {
        case "accent", "info", "primary", "blue": self = .accent
        case "good", "success", "positive", "green": self = .good
        case "warn", "warning", "caution", "orange", "yellow": self = .warn
        case "bad", "danger", "error", "negative", "red": self = .bad
        default: self = .neutral
        }
    }
    var color: Color {
        switch self {
        case .neutral: return Color.primary
        case .accent: return Color.accentColor
        case .good: return Color(nsColor: .systemGreen)
        case .warn: return Color(nsColor: .systemOrange)
        case .bad: return Color(nsColor: .systemRed)
        }
    }
    var symbol: String {
        switch self {
        case .neutral: return "info.circle.fill"
        case .accent: return "info.circle.fill"
        case .good: return "checkmark.circle.fill"
        case .warn: return "exclamationmark.triangle.fill"
        case .bad: return "xmark.octagon.fill"
        }
    }
}

private func safeURL(_ s: String?) -> URL? {
    guard let s, let u = URL(string: s), ["http", "https", "mailto", "tel"].contains(u.scheme?.lowercased() ?? "") else { return nil }
    return u
}

private func symbolImage(_ name: String?) -> Image? {
    guard let name, NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil else { return nil }
    return Image(systemName: name)
}

private func inset(_ radius: CGFloat = 12) -> some View {
    RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Color.primary.opacity(0.05))
}

// MARK: - Renderer

/// Renders an AI-described layout with the app's own glass components. The AI picks structure and content;
/// the app owns every visual decision (materials, type scale, spacing, colours), so it always looks native.
struct GenUIView: View {
    let node: UINode
    var depth = 0

    var body: some View {
        if depth == 0 && node.type != "card" {
            AnyView(GenUIView(node: UINode(type: "card", children: [node]), depth: 0))       // every answer sits on a glass card
        } else {
            content
        }
    }

    @ViewBuilder private var content: some View {
        if let ext = AbilityRegistry.components[node.type] {
            ext(node)                                   // a component F.R.I.D.A.Y taught itself
        } else {
            builtIn
        }
    }

    @ViewBuilder private var builtIn: some View {
        switch node.type {
        case "card", "section", "panel": card
        case "stack", "column", "vstack", "group": VStack(alignment: .leading, spacing: node.num("spacing").map { CGFloat($0) } ?? 10) { kids }
        case "row", "hstack": HStack(alignment: .center, spacing: node.num("spacing").map { CGFloat($0) } ?? 8) { kids; Spacer(minLength: 0) }
        case "grid": grid
        case "text", "title", "heading", "paragraph": text
        case "stat", "metric", "kpi": stat
        case "badge", "tag", "chip": badge
        case "kv", "keyvalue", "properties": kv
        case "list", "items": list
        case "table": table
        case "progress", "bar_progress": progress
        case "gauge", "ring": gauge
        case "chart": chart
        case "steps", "timeline", "checklist": steps
        case "callout", "note", "alert": callout
        case "quote": quote
        case "code": code
        case "links", "actions", "buttons": links
        case "image": image
        case "gallery": gallery
        case "divider", "separator": Divider().opacity(0.6)
        default: if !node.children.isEmpty { VStack(alignment: .leading, spacing: 10) { kids } }
        }
    }

    private var kids: some View {
        // AnyView breaks the recursive view type (a view that contains itself would otherwise overflow the stack at runtime)
        ForEach(Array(node.children.enumerated()), id: \.offset) { _, c in AnyView(GenUIView(node: c, depth: depth + 1)) }
    }

    // MARK: containers

    private var card: some View {
        VStack(alignment: .leading, spacing: 12) {
            if node.str("title") != nil || node.str("subtitle") != nil {
                HStack(spacing: 10) {
                    if let icon = symbolImage(node.str("icon")) {
                        icon.font(.system(size: 17)).foregroundStyle(.secondary).frame(width: 22)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        if let t = node.str("title") { Text(t).font(.system(size: 16, weight: .semibold)).foregroundStyle(.primary) }
                        if let s = node.str("subtitle") { Text(s).font(.system(size: 12)).foregroundStyle(.secondary) }
                    }
                    Spacer(minLength: 0)
                }
            }
            kids
        }
        .padding(depth == 0 ? 14 : 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if depth == 0 { cardBackground() } else { inset(14) }
        }
    }

    private var grid: some View {
        let n = max(1, min(4, Int(node.num("columns") ?? 2)))
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10, alignment: .top), count: n), alignment: .leading, spacing: 10) { kids }
    }

    // MARK: content

    private var text: some View {
        let style = (node.str("style") ?? (node.type == "title" || node.type == "heading" ? "title" : "body")).lowercased()
        let tone = Tone(node.str("tone"))
        let font: Font = switch style {
        case "title": .system(size: 17, weight: .semibold)
        case "headline": .system(size: 14, weight: .semibold)
        case "caption": .system(size: 12)
        case "mono", "code": .system(size: 12, design: .monospaced)
        default: .system(size: 14)
        }
        return Text(LocalizedStringKey(node.str("text") ?? node.str("content") ?? ""))
            .font(font)
            .foregroundStyle(style == "caption" ? AnyShapeStyle(.secondary) : (tone == .neutral ? AnyShapeStyle(.primary) : AnyShapeStyle(tone.color)))
            .multilineTextAlignment(node.str("align") == "center" ? .center : .leading)
            .frame(maxWidth: .infinity, alignment: node.str("align") == "center" ? .center : .leading)
            .textSelection(.enabled)
    }

    private var stat: some View {
        let tone = Tone(node.str("tone"))
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                if let icon = symbolImage(node.str("icon")) { icon.font(.system(size: 11)).foregroundStyle(.secondary) }
                Text(node.str("label") ?? "").font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(node.str("value") ?? "–").font(.system(size: 26, weight: .semibold)).foregroundStyle(.primary).lineLimit(1).minimumScaleFactor(0.6)
                if let u = node.str("unit") { Text(u).font(.system(size: 13)).foregroundStyle(.secondary) }
            }
            if let d = node.str("delta") ?? node.str("note") {
                Text(d).font(.system(size: 12, weight: .medium)).foregroundStyle(node.str("delta") != nil && tone != .neutral ? tone.color : Color.secondary).lineLimit(2)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(inset())
    }

    private var badge: some View {
        let tone = Tone(node.str("tone"))
        return HStack(spacing: 5) {
            if let icon = symbolImage(node.str("icon")) { icon.font(.system(size: 11)) }
            Text(node.str("text") ?? node.str("label") ?? "").font(.system(size: 12, weight: .medium))
        }
        .foregroundStyle(tone == .neutral ? Color.primary.opacity(0.8) : tone.color)
        .padding(.horizontal, 10).frame(height: 24)
        .background(Capsule().fill(tone == .neutral ? Color.primary.opacity(0.08) : tone.color.opacity(0.16)))
        .fixedSize()
    }

    private var kv: some View {
        let items = node.rows("items")
        return VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { i, row in
                if i > 0 { Divider().opacity(0.4) }
                HStack(alignment: .firstTextBaseline) {
                    Text(row["label"]?.string ?? row["key"]?.string ?? "").font(.system(size: 13)).foregroundStyle(.secondary)
                    Spacer(minLength: 12)
                    Text(row["value"]?.string ?? "").font(.system(size: 13, weight: .medium)).foregroundStyle(.primary).multilineTextAlignment(.trailing)
                }
                .padding(.vertical, 7)
            }
        }
    }

    private var list: some View {
        let items = node.rows("items")
        return VStack(spacing: 0) {
            ForEach(Array(items.prefix(14).enumerated()), id: \.offset) { i, row in
                if i > 0 { Divider().opacity(0.4) }
                let url = safeURL(row["url"]?.string)
                Button { if let url { NSWorkspace.shared.open(url) } } label: {
                    HStack(spacing: 10) {
                        if let icon = symbolImage(row["icon"]?.string) {
                            icon.font(.system(size: 13)).foregroundStyle(.secondary).frame(width: 28, height: 28)
                                .background(Circle().fill(Color.primary.opacity(0.07)))
                        } else if node.str("numbered") == "true" {
                            Text("\(i + 1)").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary).frame(width: 22)
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(row["title"]?.string ?? row["label"]?.string ?? "").font(.system(size: 14)).foregroundStyle(.primary).lineLimit(2)
                            if let s = row["subtitle"]?.string ?? row["detail"]?.string {
                                Text(s).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                        Spacer(minLength: 8)
                        if let t = row["trailing"]?.string ?? row["value"]?.string {
                            Text(t).font(.system(size: 13, weight: .medium).monospacedDigit()).foregroundStyle(Tone(row["tone"]?.string) == .neutral ? Color.primary.opacity(0.8) : Tone(row["tone"]?.string).color)
                        }
                        if url != nil { Image(systemName: "arrow.up.forward").font(.system(size: 10)).foregroundStyle(.tertiary) }
                    }
                    .padding(.vertical, 7)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var table: some View {
        let cols = (node.props["columns"]?.array ?? []).compactMap(\.string)
        let rows = (node.props["rows"]?.array ?? []).prefix(14).map { $0.array.map { $0.string ?? "" } }
        let n = max(cols.count, rows.map(\.count).max() ?? 1)
        func cell(_ s: String, _ i: Int, header: Bool) -> some View {
            Text(s)
                .font(header ? .system(size: 11, weight: .semibold) : .system(size: 13, weight: i == 0 ? .medium : .regular))
                .foregroundStyle(header ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                .textCase(header ? .uppercase : nil)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        return VStack(spacing: 0) {
            if !cols.isEmpty {
                HStack(alignment: .top, spacing: 10) { ForEach(0..<n, id: \.self) { i in cell(i < cols.count ? cols[i] : "", i, header: true) } }
                    .padding(.vertical, 6)
                Divider().opacity(0.6)
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { r, row in
                if r > 0 { Divider().opacity(0.3) }
                HStack(alignment: .top, spacing: 10) { ForEach(0..<n, id: \.self) { i in cell(i < row.count ? row[i] : "", i, header: false) } }
                    .padding(.vertical, 7)
            }
        }
    }

    private var progress: some View {
        let raw = node.num("value") ?? 0
        let v = min(max(raw > 1 ? raw / 100 : raw, 0), 1)
        let tone = Tone(node.str("tone"))
        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(node.str("label") ?? "").font(.system(size: 13)).foregroundStyle(.primary)
                Spacer()
                Text(node.str("detail") ?? "\(Int(v * 100))%").font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
            }
            GeometryReader { g in
                Capsule().fill(Color.primary.opacity(0.1))
                    .overlay(alignment: .leading) { Capsule().fill(tone == .neutral ? Color.accentColor : tone.color).frame(width: max(g.size.width * v, 4)) }
            }
            .frame(height: 6)
        }
    }

    private var gauge: some View {
        let raw = node.num("value") ?? 0
        return RingGauge(value: min(max(raw > 1 ? raw / 100 : raw, 0), 1), title: node.str("label") ?? "", detail: node.str("detail") ?? "")
    }

    // MARK: charts

    private struct Point: Identifiable { let id = UUID(); let label: String; let value: Double }

    private var points: [Point] {
        (node.props["data"]?.array ?? node.props["points"]?.array ?? node.props["items"]?.array ?? []).prefix(24).compactMap { v -> Point? in
            switch v {
            case .object(let o):
                guard let value = (o["value"] ?? o["y"] ?? o["amount"])?.double else { return nil }
                return Point(label: (o["label"] ?? o["name"] ?? o["x"])?.string ?? "", value: value)
            case .array(let a) where a.count >= 2:
                guard let value = a[1].double else { return nil }
                return Point(label: a[0].string ?? "", value: value)
            case .number(let n): return Point(label: "", value: n)
            default: return nil
            }
        }
    }

    @ViewBuilder private var chart: some View {
        let pts = points
        let unit = node.str("unit") ?? ""
        VStack(alignment: .leading, spacing: 6) {
            if let t = node.str("title") { Text(t).font(.system(size: 13, weight: .semibold)).foregroundStyle(.primary) }
            if pts.count < 2 {
                EmptyView()
            } else {
                switch (node.str("kind") ?? "bar").lowercased() {
                case "line", "area", "spark", "trend":
                    Chart(pts) { p in
                        AreaMark(x: .value("x", p.label), y: .value("y", p.value))
                            .foregroundStyle(LinearGradient(colors: [Color.accentColor.opacity(0.28), Color.accentColor.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                            .interpolationMethod(.catmullRom)
                        LineMark(x: .value("x", p.label), y: .value("y", p.value))
                            .foregroundStyle(Color.accentColor)
                            .lineStyle(StrokeStyle(lineWidth: 2.2, lineCap: .round))
                            .interpolationMethod(.catmullRom)
                        if pts.count <= 12 { PointMark(x: .value("x", p.label), y: .value("y", p.value)).foregroundStyle(Color.accentColor).symbolSize(26) }
                    }
                    .chartYAxis { axis(unit) }
                    .chartXAxis { labelAxis }
                    .frame(height: 150)
                case "donut", "pie", "ring":
                    let total = max(pts.reduce(0) { $0 + max($1.value, 0) }, 0.0001)
                    HStack(spacing: 16) {
                        Chart(Array(pts.enumerated()), id: \.offset) { i, p in
                            SectorMark(angle: .value("v", max(p.value, 0)), innerRadius: .ratio(0.62), angularInset: 1.5)
                                .cornerRadius(4)
                                .foregroundStyle(Color.accentColor.opacity(max(0.95 - Double(i) * 0.13, 0.25)))
                        }
                        .frame(width: 130, height: 130)
                        VStack(alignment: .leading, spacing: 5) {
                            ForEach(Array(pts.prefix(7).enumerated()), id: \.offset) { i, p in
                                HStack(spacing: 8) {
                                    Circle().fill(Color.accentColor.opacity(max(0.95 - Double(i) * 0.13, 0.25))).frame(width: 8, height: 8)
                                    Text(p.label).font(.system(size: 12)).foregroundStyle(.primary).lineLimit(1)
                                    Spacer(minLength: 6)
                                    Text("\(Int((p.value / total * 100).rounded()))%").font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                default:
                    let horizontal = pts.count > 6 || (pts.map(\.label.count).max() ?? 0) > 9
                    Chart(pts) { p in
                        if horizontal {
                            BarMark(x: .value("v", p.value), y: .value("l", p.label)).foregroundStyle(Color.accentColor.gradient).cornerRadius(4)
                        } else {
                            BarMark(x: .value("l", p.label), y: .value("v", p.value)).foregroundStyle(Color.accentColor.gradient).cornerRadius(4)
                        }
                    }
                    .chartYAxis {
                        if horizontal { labelAxis } else { axis(unit) }
                    }
                    .chartXAxis {
                        if horizontal { axis(unit) } else { labelAxis }
                    }
                    .frame(height: horizontal ? CGFloat(max(110, pts.count * 26)) : 150)
                }
            }
        }
    }

    private var labelAxis: some AxisContent {
        AxisMarks { v in
            AxisValueLabel { if let t = v.as(String.self) { Text(t).foregroundStyle(Color.secondary) } }
        }
    }

    private func axis(_ unit: String) -> some AxisContent {
        AxisMarks { v in
            AxisGridLine().foregroundStyle(Color.primary.opacity(0.08))
            AxisValueLabel { if let d = v.as(Double.self) { Text(Calculator.format(d) + (unit.count <= 2 ? unit : "")).foregroundStyle(.secondary) } }
        }
    }

    // MARK: narrative blocks

    private var steps: some View {
        let items = node.rows("items")
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.prefix(12).enumerated()), id: \.offset) { i, row in
                let done = row["done"]?.string == "true"
                HStack(alignment: .top, spacing: 12) {
                    ZStack {
                        Circle().fill(done ? Color(nsColor: .systemGreen) : Color.primary.opacity(0.1)).frame(width: 22, height: 22)
                        if done { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white) }
                        else { Text("\(i + 1)").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary) }
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row["title"]?.string ?? row["label"]?.string ?? "").font(.system(size: 14, weight: .medium)).foregroundStyle(.primary)
                        if let d = row["detail"]?.string ?? row["subtitle"]?.string { Text(d).font(.system(size: 12)).foregroundStyle(.secondary) }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.bottom, i < items.count - 1 ? 14 : 0)
                .background(alignment: .topLeading) {
                    if i < items.count - 1 {          // connector to the next step, sized by the row itself
                        Rectangle().fill(Color.primary.opacity(0.14)).frame(width: 1.5).padding(.leading, 10.25).padding(.top, 24)
                    }
                }
            }
        }
    }

    private var callout: some View {
        let tone = Tone(node.str("tone"))
        return HStack(alignment: .top, spacing: 10) {
            (symbolImage(node.str("icon")) ?? Image(systemName: tone.symbol)).font(.system(size: 15)).foregroundStyle(tone == .neutral ? Color.secondary : tone.color)
            VStack(alignment: .leading, spacing: 2) {
                if let t = node.str("title") { Text(t).font(.system(size: 13, weight: .semibold)).foregroundStyle(.primary) }
                Text(LocalizedStringKey(node.str("text") ?? "")).font(.system(size: 13)).foregroundStyle(.primary.opacity(0.85))
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(tone == .neutral ? Color.primary.opacity(0.05) : tone.color.opacity(0.12)))
    }

    private var quote: some View {
        HStack(alignment: .top, spacing: 10) {
            Capsule().fill(Color.primary.opacity(0.25)).frame(width: 3)
            VStack(alignment: .leading, spacing: 3) {
                Text(node.str("text") ?? "").font(.system(size: 14).italic()).foregroundStyle(.primary.opacity(0.9))
                if let s = node.str("source") { Text("— " + s).font(.system(size: 12)).foregroundStyle(.secondary) }
            }
        }
    }

    private var code: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(node.str("text") ?? "", forType: .string)
        } label: {
            Text(node.str("text") ?? "").font(.system(size: 12, design: .monospaced)).foregroundStyle(.primary.opacity(0.9))
                .frame(maxWidth: .infinity, alignment: .leading).padding(10).background(inset(10))
        }
        .buttonStyle(.plain)
        .help("Click to copy")
    }

    private var links: some View {
        let items = node.rows("items")
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(items.prefix(8).enumerated()), id: \.offset) { _, row in
                    let title = row["title"]?.string ?? row["label"]?.string ?? ""
                    let url = safeURL(row["url"]?.string)
                    let copy = row["copy"]?.string
                    if url != nil || copy != nil {
                        Button {
                            if let url { NSWorkspace.shared.open(url) }
                            else if let copy { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(copy, forType: .string) }
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: url != nil ? "link" : "doc.on.doc").font(.system(size: 10))
                                Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                            }
                            .foregroundStyle(Color.primary.opacity(0.85)).padding(.horizontal, 12).frame(height: 28)
                            .background(Capsule().fill(Color.primary.opacity(0.1)))
                            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1)))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .frame(height: 30)
    }

    private var image: some View {
        VStack(alignment: .leading, spacing: 4) {
            if safeURL(node.str("url")) != nil, let u = node.str("url") {
                RemoteImage(url: u).frame(maxHeight: 200).clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            if let c = node.str("caption") { Text(c).font(.system(size: 12)).foregroundStyle(.secondary) }
        }
    }

    private var gallery: some View {
        let urls = (node.props["images"]?.array ?? node.props["items"]?.array ?? []).compactMap { $0.string ?? $0.object["url"]?.string }.filter { safeURL($0) != nil }
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(urls.prefix(10), id: \.self) { u in
                    RemoteImage(url: u).frame(height: 112).clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
        }
        .frame(height: 112)
    }
}
