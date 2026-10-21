import AppKit
import SwiftUI

enum Metrics {
    static let width: CGFloat = 680
    static let header: CGFloat = 58
    static let row: CGFloat = 46
    static let pad: CGFloat = 5
    static let ghostInset: CGFloat = 0

    static let replyFont = NSFont.systemFont(ofSize: 16)

    /// Height of Grok's reply area, sized to the text and capped (it scrolls beyond that).
    static func replyHeight(_ text: String) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        let rect = (text as NSString).boundingRect(with: NSSize(width: width - 36, height: .greatestFiniteMagnitude),
                                                   options: [.usesLineFragmentOrigin], attributes: [.font: replyFont])
        return min(ceil(rect.height) + 28, 260)
    }

    static let chatHeight: CGFloat = 420
    static func aiHeight(hasChat: Bool) -> CGFloat { header + (hasChat ? chatHeight + 1 : 0) }

    static func height(rows: Int, reply: String = "", contact: ContactCard? = nil, widget: Widget? = nil) -> CGFloat {
        let r = replyHeight(reply)
        let c = contact.map { ContactCardView.height($0) + 16 + 1 } ?? 0
        let w = widget.map { WidgetView.compactHeight($0) + 16 + 1 } ?? 0
        return header + (rows > 0 ? CGFloat(rows) * row + pad * 2 + 1 : 0) + c + w + (r > 0 ? r + 1 : 0)
    }
}

struct Blur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .popover          // adaptive system glass (follows light / dark)
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}

struct SearchView: View {
    @ObservedObject var model: SearchModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: model.mode == .ai ? "eye" : "magnifyingglass")
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(.secondary)
                ZStack(alignment: .leading) {
                    if model.mode == .search, !model.ghost.isEmpty {
                        // Invisible copy of the query pushes the dimmed answer to the end of the typed text.
                        (Text(model.query).foregroundColor(.clear) + Text(model.ghost).foregroundColor(Color.primary.opacity(0.35)))
                            .font(.system(size: 22))
                            .lineLimit(1)
                            .padding(.leading, Metrics.ghostInset)
                            .allowsHitTesting(false)
                    }
                    TextField(model.mode == .ai ? "F.R.I.D.A.Y at your service . . ." : "Searching with F.R.I.D.A.Y . . .",
                              text: model.mode == .ai ? $model.aiInput : $model.query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 22))
                        .focused($focused)
                        .autocorrectionDisabled()
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if model.mode == .search, model.copied {
                    Text("Copied")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.primary.opacity(0.45))
                        .transition(.opacity)
                }

                VoiceIndicator(model: model)

                if model.mode == .search, let swatch = model.swatch {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(swatch)
                        .frame(width: 30, height: 30)
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.25)))
                }

                if model.mode == .search, let flag = model.flag {
                    Text(flag).font(.system(size: 28)).opacity(0.45)
                }
            }
            .padding(.horizontal, 18)
            .frame(height: Metrics.header)

            if model.mode == .ai {
                if !model.chat.isEmpty {
                    Divider().opacity(0.5)
                    ChatView(model: model)
                }
            } else if !model.results.isEmpty || !model.reply.isEmpty { Divider().opacity(0.5) }

            if model.mode == .search, !model.results.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(model.results.enumerated()), id: \.element.id) { i, r in
                        ResultRow(result: r, selected: i == model.selected)
                            .contentShape(Rectangle())
                            .onTapGesture { model.activate(i) }
                    }
                }
                .padding(Metrics.pad)
            }

            if model.mode == .search, let w = model.livePreview {
                Divider().opacity(0.5)
                WidgetView(widget: w, compact: true)
                    .padding(8)
                    .frame(height: WidgetView.compactHeight(w) + 16)
            }

            if model.mode == .search, let c = model.selectedContact {
                Divider().opacity(0.5)
                ContactCardView(card: c)
                    .padding(8)
                    .frame(height: ContactCardView.height(c) + 16)
            }

            if model.mode == .search, !model.reply.isEmpty {
                if !model.results.isEmpty { Divider().opacity(0.5) }
                ScrollView {
                    Text((try? AttributedString(markdown: model.reply, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(model.reply))
                        .font(.system(size: 16))
                        .foregroundStyle(Color.primary.opacity(0.85))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 14)
                }
                .frame(height: Metrics.replyHeight(model.reply))
            }
        }
        .frame(width: Metrics.width, alignment: .top)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Blur())
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.5))
        .animation(.easeOut(duration: 0.15), value: model.copied)
        .onAppear { focused = true }
        .onChange(of: model.focusTick) { _, _ in focused = true }
        .onKeyPress(.downArrow) { model.move(1); return .handled }
        .onKeyPress(.upArrow) { model.move(-1); return .handled }
        .onKeyPress(.escape) { model.escape(); return .handled }
        .onKeyPress(keys: ["k"]) { press in
            guard model.mode == .ai, press.modifiers.contains(.command) else { return .ignored }
            model.clearChat()
            return .handled
        }
        .onKeyPress(.tab) { model.move(1); return .handled }
        .onKeyPress(keys: [.return]) { press in
            model.activate(reveal: press.modifiers.contains(.command))
            return .handled
        }
    }
}

struct ResultRow: View {
    let result: SearchResult
    let selected: Bool

    var body: some View {
        HStack(spacing: 12) {
            if result.isPreview {
                // small paper-like page preview
                Image(nsImage: result.icon)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 30, maxHeight: 36)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(.black.opacity(0.25), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
                    .frame(width: 30, height: 36)
            } else {
                Image(nsImage: result.icon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 30, height: 30)
                    .foregroundStyle(selected ? Color.white : Color.primary)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(result.title).font(.system(size: 15, weight: .medium)).lineLimit(1)
                if !result.subtitle.isEmpty { Text(result.subtitle).font(.system(size: 11)).lineLimit(1)
                    .foregroundStyle(selected ? Color.white.opacity(0.8) : Color.secondary) }
            }
            Spacer(minLength: 8)
            Text(result.kind)
                .font(.system(size: 11))
                .foregroundStyle(selected ? Color.white.opacity(0.8) : Color.secondary)
        }
        .foregroundStyle(selected ? Color.white : Color.primary)
        .padding(.horizontal, 10)
        .frame(height: Metrics.row)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(selected ? Color.accentColor : Color.clear))
    }
}

struct ChatView: View {
    @ObservedObject var model: SearchModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 16) {
                    ForEach(model.chat) { m in
                        Group {
                            if m.role == "user" {
                                Text(m.text)
                                    .font(.system(size: 16))
                                    .foregroundStyle(Color.primary.opacity(0.65))
                                    .padding(.horizontal, 14).padding(.vertical, 9)
                                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.09)))
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                            } else {
                                VStack(alignment: .leading, spacing: 6) {
                                    AssistantText(full: m.text, streaming: m.streaming)
                                    ForEach(m.notes, id: \.self) { note in
                                        if let map = note.map {
                                            MapCardView(preview: map)
                                        } else if let w = note.widget {
                                            WidgetView(widget: w)
                                        } else if !note.contacts.isEmpty {
                                            VStack(spacing: 8) {
                                                ForEach(note.contacts) { ContactCardView(card: $0) }
                                            }
                                        } else {
                                        HStack(spacing: 6) {
                                            ForEach(note.icons, id: \.self) { path in
                                                Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                                                    .resizable().frame(width: 20, height: 20)
                                            }
                                            Text(note.icons.isEmpty ? "↳ \(note.text)" : note.text)
                                                .font(.system(size: 13)).foregroundStyle(Color.primary.opacity(0.45))
                                        }
                                        }
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .transition(.opacity.combined(with: .offset(y: 10)))
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .animation(.spring(response: 0.35, dampingFraction: 0.85), value: model.chat.count)
            }
            .onAppear { proxy.scrollTo("bottom") }
            .onChange(of: model.chat.last?.text) { _, _ in withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom") } }
            .onChange(of: model.chat.count) { _, _ in withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("bottom") } }
        }
        .frame(height: Metrics.chatHeight)
    }

    static func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}

/// Reveals the reply like typing: network chunks arrive in bursts, so characters are released at a
/// smooth pace (faster when the backlog grows), with a blinking caret while the reply is still streaming.
struct AssistantText: View {
    let full: String
    let streaming: Bool
    @State private var shown: Int

    init(full: String, streaming: Bool) {
        self.full = full
        self.streaming = streaming
        _shown = State(initialValue: streaming ? 0 : full.count)
    }

    private var typing: Bool { streaming || shown < full.count }

    var body: some View {
        Group {
            if full.isEmpty && streaming {
                ThinkingDots()
            } else {
                TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
                    let on = Int(ctx.date.timeIntervalSinceReferenceDate * 2) % 2 == 0
                    Text(ChatView.markdown(String(full.prefix(shown))))
                        .foregroundColor(Color.primary.opacity(0.92))
                    + Text(typing ? " ▍" : "").foregroundColor(Color.primary.opacity(on ? 0.7 : 0.1))
                }
                .font(.system(size: 17))
                .textSelection(.enabled)
            }
        }
        .task(id: full) {
            shown = min(shown, full.count)
            while shown < full.count {
                let backlog = full.count - shown
                shown = min(full.count, shown + max(1, backlog / 10))
                try? await Task.sleep(nanoseconds: 18_000_000)
                if Task.isCancelled { return }
            }
        }
    }
}

struct ThinkingDots: View {
    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(spacing: 6) {
                ForEach(0..<3, id: \.self) { i in
                    let phase = (sin(t * 5 - Double(i) * 0.9) + 1) / 2
                    Circle()
                        .fill(Color.primary.opacity(0.25 + 0.55 * phase))
                        .frame(width: 8, height: 8)
                        .offset(y: -3 * phase)
                }
            }
            .padding(.vertical, 6)
        }
    }
}

struct ContactCardView: View {
    let card: ContactCard
    @State private var copied: String?

    // Fixed row sizes keep the panel height predictable (see `height`).
    private static let headerH: CGFloat = 60
    private static let rowH: CGFloat = 34
    private static let pillH: CGFloat = 32

    private struct Field: Hashable { let icon: String; let label: String; let value: String }

    private static func fields(_ c: ContactCard) -> [Field] {
        var f = c.phones.prefix(3).map { Field(icon: "phone.fill", label: $0.label.isEmpty ? "phone" : $0.label, value: $0.value) }
        f += c.emails.prefix(3).map { Field(icon: "envelope.fill", label: $0.label.isEmpty ? "email" : $0.label, value: $0.value) }
        if let b = c.birthday { f.append(Field(icon: "gift.fill", label: "birthday", value: b)) }
        return f
    }

    static func height(_ c: ContactCard) -> CGFloat {
        let n = CGFloat(fields(c).count)
        let hasActions = !c.phones.isEmpty || !c.emails.isEmpty
        return 28 + headerH + (n > 0 ? 12 + n * rowH + (n - 1) : 0) + (hasActions ? 12 + pillH : 0)
    }

    var body: some View {
        let fields = Self.fields(card)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                Image(nsImage: Avatar.image(name: card.name, id: card.id))
                    .resizable()
                    .frame(width: Self.headerH, height: Self.headerH)
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.18), lineWidth: 1))
                    .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
                VStack(alignment: .leading, spacing: 3) {
                    Text(card.name).font(.system(size: 19, weight: .semibold)).foregroundStyle(Color.primary.opacity(0.96)).lineLimit(1)
                    if !card.subtitle.isEmpty {
                        Text(card.subtitle).font(.system(size: 13)).foregroundStyle(Color.primary.opacity(0.5)).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                Button { ContactsIndex.open(card.id) } label: {
                    Image(systemName: "arrow.up.forward.app").font(.system(size: 16)).foregroundStyle(Color.primary.opacity(0.5))
                }
                .buttonStyle(.plain)
                .help("Open in Contacts")
            }
            .frame(height: Self.headerH)

            if !fields.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(fields.enumerated()), id: \.element) { i, f in
                        if i > 0 { Divider().opacity(0.35) }
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(f.value, forType: .string)
                            copied = f.value
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { if copied == f.value { copied = nil } }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: f.icon).font(.system(size: 12)).frame(width: 16).foregroundStyle(Color.primary.opacity(0.4))
                                Text(f.label.capitalized).font(.system(size: 12)).foregroundStyle(Color.primary.opacity(0.4)).frame(width: 64, alignment: .leading)
                                Text(f.value).font(.system(size: 14)).foregroundStyle(Color.primary.opacity(0.9)).lineLimit(1)
                                Spacer(minLength: 6)
                                if copied == f.value { Text("Copied").font(.system(size: 11)).foregroundStyle(Color.primary.opacity(0.45)) }
                            }
                            .padding(.horizontal, 12)
                            .frame(height: Self.rowH)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.primary.opacity(0.05)))
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            }

            if !card.phones.isEmpty || !card.emails.isEmpty {
                HStack(spacing: 8) {
                    if let p = card.phones.first {
                        let digits = p.value.filter { $0.isNumber || $0 == "+" }
                        pill("Call", "phone.fill", "tel:\(digits)")
                        pill("Message", "message.fill", "sms:\(digits)")
                    }
                    if let e = card.emails.first { pill("Email", "envelope.fill", "mailto:\(e.value)") }
                    Spacer(minLength: 0)
                }
                .frame(height: Self.pillH)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.primary.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
    }

    private func pill(_ title: String, _ icon: String, _ url: String) -> some View {
        Button {
            if let u = URL(string: url) { NSWorkspace.shared.open(u) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 11))
                Text(title).font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(Color.primary.opacity(0.88))
            .padding(.horizontal, 14)
            .frame(height: Self.pillH)
            .background(Capsule().fill(Color.primary.opacity(0.1)))
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1)))
        }
        .buttonStyle(.plain)
    }
}
