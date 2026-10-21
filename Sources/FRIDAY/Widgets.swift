import AppKit
import CoreServices
import SwiftUI

// MARK: - Data

/// Rich preview cards, shown in F.R.I.D.A.Y AI replies and as live previews in normal search.
enum Widget: Codable, Hashable {
    case weather(WeatherCard)
    case clock(ClockCard)
    case definition(DefinitionCard)
    case knowledge(KnowledgeCard)
    case system(SystemCard)
    case disk(DiskCard)
    case ui(UINode)           // AI-described layout rendered with the app's own components
}

struct WeatherCard: Codable, Hashable {
    struct Hour: Codable, Hashable { var label: String; var temp: Int; var code: Int; var night: Bool }
    struct Day: Codable, Hashable { var label: String; var hi: Int; var lo: Int; var code: Int }
    var place: String
    var region: String
    var temp: Int
    var feels: Int
    var code: Int
    var isDay: Bool
    var hi: Int
    var lo: Int
    var humidity: Int
    var wind: Int
    var windUnit: String
    var hours: [Hour]
    var days: [Day]
}

struct ClockZone: Codable, Hashable { var name: String; var tz: String }
struct ClockCard: Codable, Hashable { var zones: [ClockZone] }
struct DefinitionCard: Codable, Hashable { var word: String; var text: String; var pron: String? = nil }

// MARK: - Services

enum WeatherService {
    struct Geo { let name: String; let region: String; let lat: Double; let lon: Double; let tz: String }

    static func geocode(_ q: String) async -> Geo? {
        let name = q.split(separator: ",").first.map(String.init) ?? q
        guard var c = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search") else { return nil }
        c.queryItems = [.init(name: "name", value: name.trimmingCharacters(in: .whitespaces)), .init(name: "count", value: "1"),
                        .init(name: "language", value: "en"), .init(name: "format", value: "json")]
        guard let url = c.url, let (data, _) = try? await URLSession.shared.data(from: url),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let r = (o["results"] as? [[String: Any]])?.first,
              let lat = r["latitude"] as? Double, let lon = r["longitude"] as? Double else { return nil }
        let region = [r["admin1"] as? String, r["country"] as? String].compactMap { $0 }.joined(separator: ", ")
        return Geo(name: r["name"] as? String ?? name, region: region, lat: lat, lon: lon, tz: r["timezone"] as? String ?? "UTC")
    }

    /// °F for US locales, °C otherwise; override with: defaults write com.friday.app weatherUnits c   (or f)
    static var fahrenheit: Bool {
        switch UserDefaults.standard.string(forKey: "weatherUnits")?.lowercased() {
        case "c": return false
        case "f": return true
        default: return Locale.current.measurementSystem == .us
        }
    }

    static func fetch(_ location: String) async -> WeatherCard? {
        guard let g = await geocode(location) else { return nil }
        let us = fahrenheit
        guard var c = URLComponents(string: "https://api.open-meteo.com/v1/forecast") else { return nil }
        c.queryItems = [
            .init(name: "latitude", value: "\(g.lat)"), .init(name: "longitude", value: "\(g.lon)"),
            .init(name: "current", value: "temperature_2m,apparent_temperature,relative_humidity_2m,weather_code,wind_speed_10m,is_day"),
            .init(name: "hourly", value: "temperature_2m,weather_code,is_day"),
            .init(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min"),
            .init(name: "timezone", value: "auto"), .init(name: "forecast_days", value: "6"),
            .init(name: "temperature_unit", value: us ? "fahrenheit" : "celsius"),
            .init(name: "wind_speed_unit", value: us ? "mph" : "kmh"),
        ]
        guard let url = c.url, let (data, _) = try? await URLSession.shared.data(from: url),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cur = o["current"] as? [String: Any], let hourly = o["hourly"] as? [String: Any],
              let daily = o["daily"] as? [String: Any] else { return nil }

        func num(_ d: [String: Any], _ k: String) -> Double { (d[k] as? Double) ?? Double(d[k] as? Int ?? 0) }
        func arr(_ d: [String: Any], _ k: String) -> [Double] { (d[k] as? [Any] ?? []).map { ($0 as? Double) ?? Double($0 as? Int ?? 0) } }

        let times = hourly["time"] as? [String] ?? []
        let temps = arr(hourly, "temperature_2m"), codes = arr(hourly, "weather_code"), day = arr(hourly, "is_day")
        let nowHour = String((cur["time"] as? String ?? "").prefix(13)) + ":00"
        let start = times.firstIndex { $0 >= nowHour } ?? 0
        var hours: [WeatherCard.Hour] = []
        for i in start..<min(start + 12, times.count) where i < temps.count && i < codes.count && i < day.count {
            let h = Int(times[i].suffix(5).prefix(2)) ?? 0
            hours.append(.init(label: i == start ? "Now" : "\(h % 12 == 0 ? 12 : h % 12) \(h < 12 ? "AM" : "PM")",
                               temp: Int(temps[i].rounded()), code: Int(codes[i]), night: day[i] == 0))
        }

        let dTimes = daily["time"] as? [String] ?? []
        let hi = arr(daily, "temperature_2m_max"), lo = arr(daily, "temperature_2m_min"), dCodes = arr(daily, "weather_code")
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        let wf = DateFormatter()
        wf.dateFormat = "EEE"
        wf.timeZone = TimeZone(identifier: "UTC")
        var days: [WeatherCard.Day] = []
        for (i, t) in dTimes.enumerated() where i < hi.count && i < lo.count && i < dCodes.count {
            days.append(.init(label: i == 0 ? "Today" : (f.date(from: t).map(wf.string(from:)) ?? t),
                              hi: Int(hi[i].rounded()), lo: Int(lo[i].rounded()), code: Int(dCodes[i])))
        }
        guard let today = days.first else { return nil }

        return WeatherCard(place: g.name, region: g.region, temp: Int(num(cur, "temperature_2m").rounded()),
                           feels: Int(num(cur, "apparent_temperature").rounded()), code: Int(num(cur, "weather_code")),
                           isDay: num(cur, "is_day") != 0, hi: today.hi, lo: today.lo,
                           humidity: Int(num(cur, "relative_humidity_2m")), wind: Int(num(cur, "wind_speed_10m").rounded()),
                           windUnit: us ? "mph" : "km/h", hours: hours, days: days)
    }

    static func symbol(_ code: Int, night: Bool = false) -> String {
        switch code {
        case 0: return night ? "moon.stars.fill" : "sun.max.fill"
        case 1: return night ? "cloud.moon.fill" : "cloud.sun.fill"
        case 2: return night ? "cloud.moon.fill" : "cloud.sun.fill"
        case 3: return "cloud.fill"
        case 45, 48: return "cloud.fog.fill"
        case 51, 53, 55, 56, 57: return "cloud.drizzle.fill"
        case 61, 63, 65: return "cloud.rain.fill"
        case 66, 67: return "cloud.sleet.fill"
        case 71, 73, 75, 77, 85, 86: return "cloud.snow.fill"
        case 80, 81, 82: return "cloud.heavyrain.fill"
        case 95: return "cloud.bolt.fill"
        case 96, 99: return "cloud.bolt.rain.fill"
        default: return "cloud.fill"
        }
    }

    static func describe(_ code: Int) -> String {
        switch code {
        case 0: return "Clear"
        case 1: return "Mostly clear"
        case 2: return "Partly cloudy"
        case 3: return "Overcast"
        case 45, 48: return "Fog"
        case 51, 53, 55: return "Drizzle"
        case 56, 57: return "Freezing drizzle"
        case 61: return "Light rain"
        case 63: return "Rain"
        case 65: return "Heavy rain"
        case 66, 67: return "Freezing rain"
        case 71, 73, 75, 77: return "Snow"
        case 80, 81, 82: return "Showers"
        case 85, 86: return "Snow showers"
        case 95: return "Thunderstorm"
        case 96, 99: return "Thunderstorm with hail"
        default: return "Cloudy"
        }
    }

    static func summary(_ w: WeatherCard) -> String {
        let u = fahrenheit ? "°F" : "°C"
        return "\(w.place): \(w.temp)\(u), \(describe(w.code)) (feels \(w.feels)\(u)); high \(w.hi) / low \(w.lo); humidity \(w.humidity)%; wind \(w.wind) \(w.windUnit)."
    }
}

enum TimeLookup {
    private static let aliases: [String: String] = [
        "nyc": "America/New_York", "new york": "America/New_York", "sf": "America/Los_Angeles", "san francisco": "America/Los_Angeles",
        "la": "America/Los_Angeles", "los angeles": "America/Los_Angeles", "chicago": "America/Chicago", "toronto": "America/Toronto",
        "vancouver": "America/Vancouver", "mexico city": "America/Mexico_City", "sao paulo": "America/Sao_Paulo",
        "london": "Europe/London", "uk": "Europe/London", "paris": "Europe/Paris", "berlin": "Europe/Berlin", "madrid": "Europe/Madrid",
        "rome": "Europe/Rome", "amsterdam": "Europe/Amsterdam", "zurich": "Europe/Zurich", "moscow": "Europe/Moscow",
        "istanbul": "Europe/Istanbul", "dubai": "Asia/Dubai", "india": "Asia/Kolkata", "delhi": "Asia/Kolkata", "mumbai": "Asia/Kolkata",
        "bangalore": "Asia/Kolkata", "chennai": "Asia/Kolkata", "singapore": "Asia/Singapore", "hong kong": "Asia/Hong_Kong",
        "tokyo": "Asia/Tokyo", "japan": "Asia/Tokyo", "seoul": "Asia/Seoul", "beijing": "Asia/Shanghai", "shanghai": "Asia/Shanghai",
        "sydney": "Australia/Sydney", "melbourne": "Australia/Melbourne", "brisbane": "Australia/Brisbane", "perth": "Australia/Perth",
        "adelaide": "Australia/Adelaide", "canberra": "Australia/Sydney", "hobart": "Australia/Hobart", "darwin": "Australia/Darwin",
        "auckland": "Pacific/Auckland", "nz": "Pacific/Auckland", "cairo": "Africa/Cairo", "johannesburg": "Africa/Johannesburg",
        "pst": "America/Los_Angeles", "pdt": "America/Los_Angeles", "est": "America/New_York", "edt": "America/New_York",
        "cst": "America/Chicago", "mst": "America/Denver", "utc": "UTC", "gmt": "GMT", "ist": "Asia/Kolkata", "cet": "Europe/Paris",
        "jst": "Asia/Tokyo", "aest": "Australia/Sydney", "aedt": "Australia/Sydney", "bst": "Europe/London",
    ]

    /// Offline lookup by city / alias / tz database name.
    static func resolve(_ raw: String) -> ClockZone? {
        let q = raw.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return nil }
        if let id = aliases[q] { return ClockZone(name: label(q), tz: id) }
        for id in TimeZone.knownTimeZoneIdentifiers {
            if (id.split(separator: "/").last.map { $0.replacingOccurrences(of: "_", with: " ").lowercased() }) == q {
                return ClockZone(name: label(q), tz: id)
            }
        }
        return nil
    }

    /// Falls back to a geocoding lookup (needs network) for places the offline table doesn't know.
    static func resolveOnline(_ raw: String) async -> ClockZone? {
        if let z = resolve(raw) { return z }
        guard let g = await WeatherService.geocode(raw) else { return nil }
        return ClockZone(name: g.name, tz: g.tz)
    }

    private static func label(_ q: String) -> String {
        q.count <= 4 && aliases[q] != nil && q == q.uppercased() ? q.uppercased() : q.capitalized
    }

    static func timeString(_ z: ClockZone, _ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.dateFormat = "EEE h:mm a"
        f.timeZone = TimeZone(identifier: z.tz) ?? .current
        return f.string(from: date)
    }
}

enum Dictionary_ {
    /// The Mac may have ~90 dictionaries installed and the first hit is often a bilingual one (e.g. Chinese),
    /// so look up the English monolingual dictionary explicitly. The listing calls are not in the public header,
    /// so they are resolved at runtime and we fall back to the system default if anything is missing.
    private static let preferred: DCSDictionary? = {
        typealias CopyAvail = @convention(c) () -> Unmanaged<CFSet>?
        typealias GetName = @convention(c) (UnsafeRawPointer) -> Unmanaged<CFString>?
        guard let h = dlopen("/System/Library/Frameworks/CoreServices.framework/CoreServices", RTLD_NOW),
              let s = dlsym(h, "DCSCopyAvailableDictionaries"), let g = dlsym(h, "DCSDictionaryGetName") else { return nil }
        let copyAvailable = unsafeBitCast(s, to: CopyAvail.self), getName = unsafeBitCast(g, to: GetName.self)
        guard let set = copyAvailable()?.takeRetainedValue() else { return nil }
        var vals = [UnsafeRawPointer?](repeating: nil, count: CFSetGetCount(set))
        CFSetGetValues(set, &vals)
        var byName: [String: UnsafeRawPointer] = [:]
        for case let v? in vals { if let n = getName(v)?.takeUnretainedValue() as String? { byName[n] = v } }
        let order = Locale.current.region?.identifier == "US"
            ? ["New Oxford American Dictionary", "Oxford Dictionary of English"]
            : ["Oxford Dictionary of English", "New Oxford American Dictionary"]
        guard let ptr = order.compactMap({ byName[$0] }).first else { return nil }
        return Unmanaged<DCSDictionary>.fromOpaque(ptr).takeUnretainedValue()
    }()

    /// Definition from the built-in macOS dictionary (offline), split into pronunciation and a readable body.
    static func define(_ word: String) -> (pron: String, text: String)? {
        let w = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !w.isEmpty, w.count <= 40 else { return nil }
        let range = CFRangeMake(0, (w as NSString).length)
        guard let raw = (DCSCopyTextDefinition(preferred, w as CFString, range)?.takeRetainedValue() as String?
                         ?? DCSCopyTextDefinition(nil, w as CFString, range)?.takeRetainedValue() as String?) else { return nil }

        // "serendipity ser·en·dip·i·ty | ˌserənˈdipədē | noun the occurrence …"
        let parts = raw.components(separatedBy: " | ")
        var pron = "", body = raw
        if parts.count >= 3 {
            pron = parts[1].trimmingCharacters(in: .whitespaces)
            body = parts[2...].joined(separator: " | ")
        }
        body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        for label in ["ORIGIN", "DERIVATIVES", "PHRASES", "USAGE"] {
            body = body.replacingOccurrences(of: " \(label) ", with: "\n\n\(label) ")
        }
        body = body.replacingOccurrences(of: " • ", with: "\n• ")
        if let re = try? NSRegularExpression(pattern: "\\s*([\u{2460}-\u{2473}])") {   // ① ② ③ sense numbers
            body = re.stringByReplacingMatches(in: body, range: NSRange(body.startIndex..., in: body), withTemplate: "\n$1")
        }
        body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.count > 700 { body = String(body.prefix(700)).trimmingCharacters(in: .whitespaces) + "…" }
        return (pron, body)
    }
}

// MARK: - Views

struct WidgetView: View {
    let widget: Widget
    var compact = false

    /// Fixed heights for the live preview under the search results.
    static func compactHeight(_ w: Widget) -> CGFloat {
        switch w {
        case .weather: return 172
        case .clock: return 170
        case .definition: return 204
        case .knowledge: return 216
        case .system: return 262
        case .disk: return 330
        case .ui: return 300
        }
    }

    var body: some View {
        switch widget {
        case .weather(let c): WeatherCardView(card: c, compact: compact)
        case .clock(let c): ClockCardView(card: c, compact: compact)
        case .definition(let c): DefinitionCardView(card: c, compact: compact)
        case .knowledge(let c): KnowledgeCardView(card: c, compact: compact)
        case .system(let c): SystemCardView(card: c, compact: compact)
        case .disk(let c): DiskCardView(card: c, compact: compact)
        case .ui(let n): GenUIView(node: n)
        }
    }
}

/// Neutral glass card that sits on the panel's vibrancy (the tint argument is kept for call sites but no longer used).
func cardBackground(_ tint: Color = .clear) -> some View {
    RoundedRectangle(cornerRadius: 14, style: .continuous)
        .fill(Color.primary.opacity(0.05))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.09), lineWidth: 0.5))
}

struct WeatherCardView: View {
    let card: WeatherCard
    let compact: Bool

    private var tint: Color {
        if !card.isDay { return Color(red: 0.25, green: 0.28, blue: 0.7) }
        switch card.code {
        case 0, 1: return Color(red: 0.2, green: 0.55, blue: 1.0)
        case 2: return Color(red: 0.3, green: 0.55, blue: 0.85)
        case 51...67, 80...82, 95...99: return Color(red: 0.35, green: 0.45, blue: 0.6)
        case 71...77, 85, 86: return Color(red: 0.55, green: 0.7, blue: 0.85)
        default: return Color(red: 0.45, green: 0.5, blue: 0.6)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(card.place).font(.system(size: 19, weight: .semibold)).foregroundStyle(Color.primary.opacity(0.96)).lineLimit(1)
                    Text(WeatherService.describe(card.code)).font(.system(size: 13)).foregroundStyle(Color.primary.opacity(0.65))
                    Text("H:\(card.hi)°  L:\(card.lo)°").font(.system(size: 12)).foregroundStyle(Color.primary.opacity(0.5))
                }
                Spacer()
                HStack(spacing: 10) {
                    Image(systemName: WeatherService.symbol(card.code, night: !card.isDay))
                        .symbolRenderingMode(.multicolor).font(.system(size: 32))
                    Text("\(card.temp)°").font(.system(size: 46, weight: .light)).foregroundStyle(.primary)
                }
            }
            .frame(height: 56)

            HStack(spacing: 0) {
                ForEach(Array(card.hours.prefix(compact ? 8 : 12).enumerated()), id: \.offset) { _, h in
                    VStack(spacing: 6) {
                        Text(h.label).font(.system(size: 11)).foregroundStyle(Color.primary.opacity(0.55))
                        Image(systemName: WeatherService.symbol(h.code, night: h.night)).symbolRenderingMode(.multicolor).font(.system(size: 16))
                        Text("\(h.temp)°").font(.system(size: 13, weight: .medium)).foregroundStyle(Color.primary.opacity(0.9))
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 76)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))

            if !compact {
                HStack(spacing: 18) {
                    stat("thermometer.medium", "Feels \(card.feels)°")
                    stat("humidity.fill", "\(card.humidity)%")
                    stat("wind", "\(card.wind) \(card.windUnit)")
                    Spacer()
                }
                VStack(spacing: 0) {
                    let lo = card.days.map(\.lo).min() ?? 0, hi = card.days.map(\.hi).max() ?? 1
                    ForEach(Array(card.days.prefix(6).enumerated()), id: \.offset) { i, d in
                        if i > 0 { Divider().opacity(0.25) }
                        HStack(spacing: 10) {
                            Text(d.label).font(.system(size: 14)).foregroundStyle(Color.primary.opacity(0.85)).frame(width: 56, alignment: .leading)
                            Image(systemName: WeatherService.symbol(d.code)).symbolRenderingMode(.multicolor).font(.system(size: 15)).frame(width: 24)
                            Text("\(d.lo)°").font(.system(size: 13)).foregroundStyle(Color.primary.opacity(0.5)).frame(width: 34, alignment: .trailing)
                            rangeBar(d.lo, d.hi, lo, hi).frame(height: 5)
                            Text("\(d.hi)°").font(.system(size: 13, weight: .medium)).foregroundStyle(Color.primary.opacity(0.9)).frame(width: 34, alignment: .leading)
                        }
                        .frame(height: 30)
                    }
                }
            }
        }
        .padding(14)
        .frame(height: compact ? WidgetView.compactHeight(.weather(card)) : nil)
        .background(cardBackground(tint))
    }

    private func stat(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 12)).foregroundStyle(Color.primary.opacity(0.45))
            Text(text).font(.system(size: 12)).foregroundStyle(Color.primary.opacity(0.7))
        }
    }

    private func rangeBar(_ lo: Int, _ hi: Int, _ minAll: Int, _ maxAll: Int) -> some View {
        GeometryReader { g in
            let span = Double(max(maxAll - minAll, 1))
            let x0 = g.size.width * Double(lo - minAll) / span
            let x1 = g.size.width * Double(hi - minAll) / span
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                Capsule()
                    .fill(LinearGradient(colors: [Color(red: 0.4, green: 0.8, blue: 1), Color(red: 1, green: 0.75, blue: 0.3)],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(x1 - x0, 6))
                    .offset(x: x0)
            }
        }
    }
}

struct AnalogClock: View {
    let date: Date
    let tz: TimeZone

    var body: some View {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let c = cal.dateComponents([.hour, .minute, .second], from: date)
        let hour24 = c.hour ?? 12
        let h = Double(hour24 % 12), m = Double(c.minute ?? 0), s = Double(c.second ?? 0)
        let night = hour24 < 6 || hour24 >= 19

        return Canvas { ctx, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let r = min(size.width, size.height) / 2
            func pt(_ len: Double, _ deg: Double) -> CGPoint {
                let a = (deg - 90) * .pi / 180
                return CGPoint(x: center.x + len * cos(a), y: center.y + len * sin(a))
            }
            func hand(_ deg: Double, _ len: Double, _ width: Double, _ color: Color) {
                var p = Path()
                p.move(to: center)
                p.addLine(to: pt(len, deg))
                ctx.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round))
            }
            let face = Path(ellipseIn: CGRect(origin: .zero, size: size))
            ctx.fill(face, with: .color(Color.primary.opacity(night ? 0.16 : 0.06)))
            ctx.stroke(face.strokedPath(StrokeStyle(lineWidth: 1)), with: .color(Color.primary.opacity(0.2)))
            for i in 0..<12 {
                let major = i % 3 == 0
                var p = Path()
                p.move(to: pt(r * (major ? 0.74 : 0.82), Double(i) * 30))
                p.addLine(to: pt(r * 0.9, Double(i) * 30))
                ctx.stroke(p, with: .color(Color.primary.opacity(major ? 0.7 : 0.35)), lineWidth: major ? 2 : 1)
            }
            hand((h + m / 60) * 30, r * 0.5, 3.5, .primary)
            hand((m + s / 60) * 6, r * 0.75, 2.5, Color.primary.opacity(0.92))
            hand(s * 6, r * 0.82, 1, Color(red: 1, green: 0.6, blue: 0.2))
            ctx.fill(Path(ellipseIn: CGRect(x: center.x - 3, y: center.y - 3, width: 6, height: 6)), with: .color(Color(red: 1, green: 0.6, blue: 0.2)))
        }
    }
}

struct ClockCardView: View {
    let card: ClockCard
    let compact: Bool

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(card.zones.prefix(4).enumerated()), id: \.offset) { _, z in
                ClockCell(zone: z).frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 14)
        .frame(height: compact ? WidgetView.compactHeight(.clock(card)) : nil)
        .background(cardBackground(Color(red: 0.3, green: 0.35, blue: 0.7)))
    }
}

private struct ClockCell: View {
    let zone: ClockZone

    var body: some View {
        let tz = TimeZone(identifier: zone.tz) ?? .current
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            VStack(spacing: 6) {
                AnalogClock(date: ctx.date, tz: tz).frame(width: 76, height: 76)
                Text(zone.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.primary.opacity(0.92)).lineLimit(1)
                Text(time(ctx.date, tz)).font(.system(size: 21, weight: .light).monospacedDigit()).foregroundStyle(.primary)
                Text(relative(ctx.date, tz)).font(.system(size: 11)).foregroundStyle(Color.primary.opacity(0.5)).lineLimit(1)
            }
        }
    }

    private func time(_ d: Date, _ tz: TimeZone) -> String {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        f.timeZone = tz
        return f.string(from: d)
    }

    private func relative(_ d: Date, _ tz: TimeZone) -> String {
        var here = Calendar(identifier: .gregorian), there = Calendar(identifier: .gregorian)
        here.timeZone = .current
        there.timeZone = tz
        let a = here.dateComponents([.year, .month, .day], from: d), b = there.dateComponents([.year, .month, .day], from: d)
        let dayDiff = (here.date(from: b).flatMap { bd in here.date(from: a).map { Int(bd.timeIntervalSince($0) / 86400) } }) ?? 0
        let day = dayDiff == 0 ? "Today" : (dayDiff > 0 ? "Tomorrow" : "Yesterday")
        let hrs = Double(tz.secondsFromGMT(for: d) - TimeZone.current.secondsFromGMT(for: d)) / 3600
        let off = hrs == 0 ? "same time" : (hrs.truncatingRemainder(dividingBy: 1) == 0
                  ? String(format: "%+.0f h", hrs) : String(format: "%+.1f h", hrs))
        return "\(day) · \(off)"
    }
}

struct DefinitionCardView: View {
    let card: DefinitionCard
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "character.book.closed.fill").font(.system(size: 11))
                Text("DICTIONARY").font(.system(size: 10, weight: .semibold)).tracking(1)
            }
            .foregroundStyle(Color.primary.opacity(0.4))
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(card.word.capitalized).font(.system(size: 26, weight: .semibold, design: .serif)).foregroundStyle(Color.primary.opacity(0.96)).lineLimit(1)
                if let p = card.pron, !p.isEmpty {
                    Text(p).font(.system(size: 14)).foregroundStyle(Color.primary.opacity(0.5)).lineLimit(1)
                }
            }
            Text(card.text)
                .font(.system(size: 14))
                .lineSpacing(3)
                .foregroundStyle(Color.primary.opacity(0.78))
                .lineLimit(compact ? 6 : nil)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(16)
        .frame(height: compact ? WidgetView.compactHeight(.definition(card)) : nil, alignment: .topLeading)
        .background(cardBackground(Color(red: 0.75, green: 0.55, blue: 0.3)))
    }
}
