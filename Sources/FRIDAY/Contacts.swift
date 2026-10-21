import AppKit
import Contacts
import Foundation

struct LabeledValue: Codable, Hashable {
    var label: String
    var value: String
}

/// What the UI shows for a person. The photo isn't stored here (it is looked up by `id` at render time),
/// so contact details never need to be persisted with a chat.
struct ContactCard: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var subtitle: String = ""
    var phones: [LabeledValue] = []
    var emails: [LabeledValue] = []
    var birthday: String?
}

/// In-memory copy of the user's address book (read-only), refreshed whenever the panel opens.
final class ContactsIndex {
    static let shared = ContactsIndex()

    struct Entry {
        let card: ContactCard
        let lower: String
        let initials: String
        let haystack: String      // nickname, organisation, emails
        let phoneDigits: String
        let thumb: Data?
    }

    private(set) var entries: [Entry] = []

    static var status: CNAuthorizationStatus { CNContactStore.authorizationStatus(for: .contacts) }
    static var authorized: Bool { status == .authorized }

    /// Async refresh for the UI. Asks for permission the first time (macOS shows its own prompt).
    func refresh() async {
        if Self.status == .notDetermined { _ = try? await CNContactStore().requestAccess(for: .contacts) }
        guard Self.authorized else { return }
        entries = await Task.detached(priority: .utility) { Self.fetch() }.value
    }

    /// Synchronous load for tools / MCP mode. Returns false if access isn't granted.
    func loadIfNeeded() -> Bool {
        if Self.status == .notDetermined {
            let sem = DispatchSemaphore(value: 0)
            CNContactStore().requestAccess(for: .contacts) { _, _ in sem.signal() }
            sem.wait()
        }
        guard Self.authorized else { return false }
        if entries.isEmpty { entries = Self.fetch() }
        return true
    }

    private static func fetch() -> [Entry] {
        let store = CNContactStore()
        let keys: [CNKeyDescriptor] = [
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
            CNContactIdentifierKey as CNKeyDescriptor, CNContactNicknameKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor, CNContactJobTitleKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor, CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactBirthdayKey as CNKeyDescriptor, CNContactThumbnailImageDataKey as CNKeyDescriptor,
        ]
        let req = CNContactFetchRequest(keysToFetch: keys)
        req.unifyResults = true
        var out: [Entry] = []
        try? store.enumerateContacts(with: req) { c, _ in
            let name = CNContactFormatter.string(from: c, style: .fullName) ?? c.organizationName
            guard !name.isEmpty else { return }
            func label(_ l: String?) -> String { l.map { CNLabeledValue<NSString>.localizedString(forLabel: $0) } ?? "" }
            let phones = c.phoneNumbers.map { LabeledValue(label: label($0.label), value: $0.value.stringValue) }
            let emails = c.emailAddresses.map { LabeledValue(label: label($0.label), value: $0.value as String) }
            var birthday: String?
            if let b = c.birthday, let m = b.month, let d = b.day {
                let f = DateFormatter()
                f.dateFormat = b.year != nil ? "MMM d, yyyy" : "MMM d"
                birthday = Calendar.current.date(from: DateComponents(year: b.year ?? 2000, month: m, day: d)).map(f.string(from:))
            }
            let card = ContactCard(id: c.identifier, name: name,
                                   subtitle: [c.jobTitle, c.organizationName].filter { !$0.isEmpty }.joined(separator: " · "),
                                   phones: phones, emails: emails, birthday: birthday)
            let words = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            out.append(Entry(card: card, lower: name.lowercased(),
                             initials: String(words.compactMap(\.first)).lowercased(),
                             haystack: ([c.nickname, c.organizationName] + emails.map(\.value)).joined(separator: " ").lowercased(),
                             phoneDigits: phones.map { $0.value.filter(\.isNumber) }.joined(separator: " "),
                             thumb: c.thumbnailImageData))
        }
        return out
    }

    /// Name matches rank first, then nickname / company / email, then phone digits.
    func search(_ query: String, limit: Int) -> [Entry] {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { return [] }
        let digits = q.filter(\.isNumber)
        let scored: [(Int, Entry)] = entries.compactMap { e in
            let probe = AppEntry(name: e.card.name, url: URL(fileURLWithPath: "/"), lower: e.lower, initials: e.initials)
            if let s = AppIndex.score(q, probe), s >= 55 { return (s, e) }
            if e.haystack.contains(q) { return (50, e) }
            if digits.count >= 3, digits.count == q.filter({ !" +-()".contains($0) }).count, e.phoneDigits.contains(digits) { return (45, e) }
            return nil
        }
        return scored.sorted { ($0.0, -$0.1.lower.count) > ($1.0, -$1.1.lower.count) }.prefix(limit).map(\.1)
    }

    func thumbnail(_ id: String) -> Data? { entries.first { $0.card.id == id }?.thumb }

    static func open(_ id: String) {
        if let url = URL(string: "addressbook://\(id)") { NSWorkspace.shared.open(url) }
    }
}

enum Avatar {
    private static var cache: [String: NSImage] = [:]

    /// Round photo if the contact has one, otherwise a coloured circle with initials.
    static func image(name: String, id: String, size: CGFloat = 96) -> NSImage {
        if let c = cache[id] { return c }
        let photo = ContactsIndex.shared.thumbnail(id).flatMap { NSImage(data: $0) }
        let words = name.split(separator: " ")
        let letters = String(words.prefix(2).compactMap(\.first)).uppercased()
        let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            NSBezierPath(ovalIn: rect).addClip()
            if let photo {
                photo.draw(in: rect)
            } else {
                NSGradient(starting: NSColor(white: 0.66, alpha: 1), ending: NSColor(white: 0.48, alpha: 1))?.draw(in: rect, angle: -90)
                let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size * 0.4, weight: .semibold),
                                                            .foregroundColor: NSColor.white]
                let s = NSAttributedString(string: letters, attributes: attrs)
                let sz = s.size()
                s.draw(at: NSPoint(x: rect.midX - sz.width / 2, y: rect.midY - sz.height / 2))
            }
            return true
        }
        cache[id] = img
        return img
    }
}
