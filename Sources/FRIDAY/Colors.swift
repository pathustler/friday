import Foundation

/// Color parsing: "#ff8800", "#f80", "rgb(255, 136, 0)", "rgb 255 136 0", "hsl(30, 100%, 50%)".
enum ColorParser {
    struct Parsed { let r: Double, g: Double, b: Double, a: Double; let fromHex: Bool }   // r,g,b in 0...255

    static func parse(_ raw: String) -> Parsed? {
        let s = raw.lowercased().trimmingCharacters(in: .whitespaces)

        if s.hasPrefix("#") {
            var h = String(s.dropFirst())
            guard [3, 6, 8].contains(h.count), h.allSatisfy(\.isHexDigit) else { return nil }
            if h.count == 3 { h = h.map { "\($0)\($0)" }.joined() }
            guard let v = UInt64(h, radix: 16) else { return nil }
            let hasAlpha = h.count == 8
            let r = Double((v >> (hasAlpha ? 24 : 16)) & 0xFF), g = Double((v >> (hasAlpha ? 16 : 8)) & 0xFF)
            let b = Double((v >> (hasAlpha ? 8 : 0)) & 0xFF), a = hasAlpha ? Double(v & 0xFF) / 255 : 1
            return Parsed(r: r, g: g, b: b, a: a, fromHex: true)
        }

        let num = #"(\d+(?:\.\d+)?)"#
        let sep = #"[\s,/]+"#
        func match(_ prefix: String) -> [Double]? {
            let pattern = "^\(prefix)a?\\(?\\s*\(num)%?\(sep)\(num)%?\(sep)\(num)%?(?:\(sep)\(num)%?)?\\s*\\)?$"
            guard let re = try? NSRegularExpression(pattern: pattern),
                  let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
            return (1..<m.numberOfRanges).compactMap { i in
                Range(m.range(at: i), in: s).flatMap { Double(s[$0]) }
            }
        }

        if let v = match("rgb"), v.count >= 3, v[0...2].allSatisfy({ $0 <= 255 }) {
            return Parsed(r: v[0], g: v[1], b: v[2], a: v.count > 3 ? min(v[3], 1) : 1, fromHex: false)
        }
        if let v = match("hsl"), v.count >= 3, v[0] <= 360, v[1] <= 100, v[2] <= 100 {
            let h = v[0] / 360, sat = v[1] / 100, l = v[2] / 100
            func f(_ n: Double) -> Double {
                let k = (n + h * 12).truncatingRemainder(dividingBy: 12)
                return l - sat * min(l, 1 - l) * max(-1, min(k - 3, 9 - k, 1))
            }
            return Parsed(r: (f(0) * 255).rounded(), g: (f(8) * 255).rounded(), b: (f(4) * 255).rounded(),
                          a: v.count > 3 ? min(v[3], 1) : 1, fromHex: false)
        }
        return nil
    }

    static func hex(_ c: Parsed) -> String {
        var s = String(format: "#%02X%02X%02X", Int(c.r.rounded()), Int(c.g.rounded()), Int(c.b.rounded()))
        if c.a < 1 { s += String(format: "%02X", Int((c.a * 255).rounded())) }
        return s
    }

    static func rgb(_ c: Parsed) -> String {
        let (r, g, b) = (Int(c.r.rounded()), Int(c.g.rounded()), Int(c.b.rounded()))
        return c.a < 1 ? "rgba(\(r), \(g), \(b), \(Calculator.format((c.a * 100).rounded() / 100)))" : "rgb(\(r), \(g), \(b))"
    }
}
