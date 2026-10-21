import AppKit
import SwiftUI

struct KnowledgeImage: Codable, Hashable, Identifiable {
    var thumb: String
    var page: String
    var id: String { thumb }
}

struct KnowledgeLink: Codable, Hashable, Identifiable {
    var title: String
    var url: String
    var id: String { url }
}

struct KnowledgeCard: Codable, Hashable {
    var title: String
    var description: String?
    var images: [KnowledgeImage]
    var links: [KnowledgeLink]
}

/// "What is Interstellar?" -> Wikipedia article + image gallery + links (no API key needed).
enum Knowledge {
    private static func get(_ urlString: String) async -> Data? {
        guard let url = URL(string: urlString) else { return nil }
        var req = URLRequest(url: url)
        req.setValue("F.R.I.D.A.Y/1.0 (macOS launcher)", forHTTPHeaderField: "User-Agent")   // Wikimedia asks for one
        req.timeoutInterval = 10
        return try? await URLSession.shared.data(for: req).0
    }

    private static func json(_ d: Data?) -> [String: Any]? {
        d.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    private static let skipImage = try! NSRegularExpression(
        pattern: #"(logo|icon|flag_of|ambox|commons-|wikiquote|wikisource|wiktionary|edit-|question_book|symbol|disambig|portal|stub|padlock|\.svg|\.ogv|\.webm|\.ogg|\.mp3|\.tif)"#,
        options: .caseInsensitive)

    private static let knownSites: [(host: String, label: String)] = [
        ("imdb.com", "IMDb"), ("rottentomatoes.com", "Rotten Tomatoes"), ("metacritic.com", "Metacritic"),
        ("boxofficemojo.com", "Box Office Mojo"), ("letterboxd.com", "Letterboxd"), ("youtube.com", "YouTube"),
        ("spotify.com", "Spotify"), ("goodreads.com", "Goodreads"), ("github.com", "GitHub"), ("britannica.com", "Britannica"),
        ("nasa.gov", "NASA"), ("x.com", "X"), ("twitter.com", "X"), ("instagram.com", "Instagram"), ("linkedin.com", "LinkedIn"),
    ]

    /// `strict`: require the article title to share a word with the topic (used for automatic lookups while typing).
    static func lookup(_ topic: String, strict: Bool = false) async -> (card: KnowledgeCard, summary: String)? {
        let q = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2, let enc = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let search = json(await get("https://en.wikipedia.org/w/rest.php/v1/search/page?q=\(enc)&limit=3")),
              let pages = search["pages"] as? [[String: Any]], !pages.isEmpty else { return nil }

        // prefer a real article over a disambiguation page
        let page = pages.first { ($0["description"] as? String)?.lowercased().contains("topics referred to") == false } ?? pages[0]
        guard let key = page["key"] as? String, let title = page["title"] as? String else { return nil }
        if strict {
            let words = q.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count > 2 }
            if !words.isEmpty, !words.contains(where: { title.lowercased().contains($0) }) { return nil }
        }

        let path = key.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? key
        async let summaryData = get("https://en.wikipedia.org/api/rest_v1/page/summary/\(path)")
        async let mediaData = get("https://en.wikipedia.org/api/rest_v1/page/media-list/\(path)")
        let titleEnc = title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? title
        async let linkData = get("https://en.wikipedia.org/w/api.php?action=query&prop=extlinks&titles=\(titleEnc)&ellimit=80&format=json")
        let (sd, md, ld) = await (summaryData, mediaData, linkData)

        let summary = json(sd)
        let articleURL = ((summary?["content_urls"] as? [String: Any])?["desktop"] as? [String: Any])?["page"] as? String
            ?? "https://en.wikipedia.org/wiki/\(path)"

        // gallery: lead image first, then the article's images
        var images: [KnowledgeImage] = []
        // the same picture shows up as the lead thumbnail and in the article's image list: compare by file name
        func fileKey(_ u: String) -> String {
            var f = (URL(string: u)?.path as NSString?)?.lastPathComponent.lowercased() ?? u
            if let r = f.range(of: #"^\d+px-"#, options: .regularExpression) { f.removeSubrange(r) }
            return f
        }
        func add(_ thumb: String, _ pageURL: String) {
            guard !images.contains(where: { fileKey($0.thumb) == fileKey(thumb) }) else { return }
            images.append(KnowledgeImage(thumb: thumb, page: pageURL))
        }
        if let src = (summary?["thumbnail"] as? [String: Any])?["source"] as? String { add(src, articleURL) }
        for item in (json(md)?["items"] as? [[String: Any]]) ?? [] where item["type"] as? String == "image" {
            guard let t = item["title"] as? String,
                  skipImage.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) == nil,
                  let src = ((item["srcset"] as? [[String: Any]])?.first?["src"] as? String) else { continue }
            let file = t.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? t
            add(src.hasPrefix("//") ? "https:" + src : src, "https://en.wikipedia.org/wiki/\(file)")
            if images.count >= 10 { break }
        }

        // links: the article, an official site / well-known pages from its references, then web + image search
        var links = [KnowledgeLink(title: "Wikipedia", url: articleURL)]
        let titleToken = title.lowercased().filter { $0.isLetter || $0.isNumber }
        var official: KnowledgeLink?
        var known: [KnowledgeLink] = []
        var further: [KnowledgeLink] = []
        let ext = ((json(ld)?["query"] as? [String: Any])?["pages"] as? [String: Any])?.values
            .compactMap { ($0 as? [String: Any])?["extlinks"] as? [[String: String]] }.first ?? []
        for e in ext {
            guard let u = e["*"], let url = URL(string: u), var host = url.host?.lowercased() else { continue }
            if host.hasPrefix("www.") { host.removeFirst(4) }
            if ["wikipedia.org", "wikimedia.org", "wikidata.org", "archive.org", "doi.org", "worldcat.org", "web.archive.org"]
                .contains(where: { host.hasSuffix($0) }) { continue }
            if let k = knownSites.first(where: { host.hasSuffix($0.host) }) {
                if !known.contains(where: { $0.title == k.label }) { known.append(KnowledgeLink(title: k.label, url: u)) }
            } else if official == nil, host.replacingOccurrences(of: "-", with: "").contains(String(titleToken.prefix(8))), titleToken.count >= 4 {
                official = KnowledgeLink(title: "Official site", url: u)
            } else if further.count < 3, !further.contains(where: { $0.title == host }) {
                further.append(KnowledgeLink(title: host, url: u))
            }
        }
        links += [official].compactMap { $0 } + known.prefix(3) + further.prefix(2)
        links.append(KnowledgeLink(title: "Search the web", url: "https://www.google.com/search?q=\(enc)"))
        links.append(KnowledgeLink(title: "More images", url: "https://www.google.com/search?q=\(enc)&tbm=isch"))

        let card = KnowledgeCard(title: summary?["title"] as? String ?? title,
                                 description: summary?["description"] as? String ?? page["description"] as? String,
                                 images: images, links: links)
        return (card, summary?["extract"] as? String ?? "")
    }
}

/// Loads a remote image with the User-Agent Wikimedia requires (SwiftUI's AsyncImage sends a generic one), with a cache.
enum RemoteImages {
    static let cache = NSCache<NSString, NSImage>()

    static func load(_ urlString: String) async -> NSImage? {
        if let c = cache.object(forKey: urlString as NSString) { return c }
        guard let url = URL(string: urlString) else { return nil }
        var req = URLRequest(url: url)
        req.setValue("F.R.I.D.A.Y/1.0 (macOS launcher)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200, let img = NSImage(data: data) else { return nil }
        cache.setObject(img, forKey: urlString as NSString)
        return img
    }
}

struct RemoteImage: View {
    let url: String
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
            } else {
                Rectangle().fill(Color.primary.opacity(0.06)).frame(width: 150)
            }
        }
        .task(id: url) { image = await RemoteImages.load(url) }
    }
}

struct KnowledgeCardView: View {
    let card: KnowledgeCard
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(card.title).font(.system(size: 19, weight: .semibold)).foregroundStyle(Color.primary.opacity(0.96)).lineLimit(1)
                if let d = card.description {
                    Text(d).font(.system(size: 13)).foregroundStyle(Color.primary.opacity(0.5)).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .frame(height: 24)

            if !card.images.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(card.images) { img in
                            Button {
                                if let u = URL(string: img.page) { NSWorkspace.shared.open(u) }
                            } label: {
                                RemoteImage(url: img.thumb)
                                    .frame(height: 112)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(height: 112)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(card.links) { l in
                        Button {
                            if let u = URL(string: l.url) { NSWorkspace.shared.open(u) }
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "link").font(.system(size: 10))
                                Text(l.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                            }
                            .foregroundStyle(Color.primary.opacity(0.85))
                            .padding(.horizontal, 12)
                            .frame(height: 28)
                            .background(Capsule().fill(Color.primary.opacity(0.1)))
                            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1)))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(height: 28)
        }
        .padding(14)
        .frame(height: compact ? WidgetView.compactHeight(.knowledge(card)) : nil, alignment: .top)
        .background(cardBackground(Color(red: 0.35, green: 0.45, blue: 0.9)))
    }
}
