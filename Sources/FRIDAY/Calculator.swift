import Foundation

/// Scientific expression evaluator (recursive descent; never throws ObjC exceptions like NSExpression).
/// Supports + - * / % ^ ** ! ° ( ), constants, ~30 functions, implicit multiplication (2pi, 3(4)),
/// percentages ("20% of 50", "50 + 10%") and base conversion ("255 to hex").
final class Calculator {
    private var chars: [Character]
    private var i = 0
    private var pct = false   // last term was a percentage literal, so "50 + 10%" means 50 + 10% of 50

    private init(_ s: String) { chars = Array(s) }

    private static func clean(_ input: String) -> String {
        input.lowercased()
            .replacingOccurrences(of: "×", with: "*").replacingOccurrences(of: "÷", with: "/")
            .replacingOccurrences(of: "**", with: "^").replacingOccurrences(of: "π", with: "pi")
            .replacingOccurrences(of: "√", with: "sqrt").replacingOccurrences(of: "−", with: "-")
            .filter { !$0.isWhitespace }
    }

    /// Returns a formatted result if `input` is a math expression (not just a bare number).
    static func evaluate(_ input: String) -> String? {
        var s = input.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("=") { s.removeFirst() }

        // "255 to hex", "1010 bin to dec" style base conversion
        if let m = s.lowercased().range(of: #"\s+(?:to|in|as)\s+(hex|bin|binary|oct|octal)$"#, options: .regularExpression) {
            let target = s.lowercased()[m].split(separator: " ").last.map(String.init) ?? ""
            guard let v = value(String(s[..<m.lowerBound])), v == v.rounded(), abs(v) < 9e15 else { return nil }
            let n = Int64(v)
            switch target {
            case "hex": return "0x" + String(n, radix: 16, uppercase: true)
            case "bin", "binary": return "0b" + String(n, radix: 2)
            default: return "0o" + String(n, radix: 8)
            }
        }

        // "20% of 50"
        if let r = s.lowercased().range(of: #"^(.+?)%\s*of\s+(.+)$"#, options: .regularExpression) {
            let parts = s.lowercased()[r].components(separatedBy: "of ")
            if parts.count == 2, let a = value(parts[0].replacingOccurrences(of: "%", with: "")), let b = value(parts[1]) {
                return format(a / 100 * b)
            }
        }

        let t = clean(s)
        guard !t.isEmpty, t.contains(where: \.isNumber), Double(t) == nil else { return nil }
        guard let v = value(t, raw: true) else { return nil }
        return format(v)
    }

    /// Numeric value of an expression; a bare number is allowed (used for currency/unit amounts).
    static func value(_ input: String, raw: Bool = false) -> Double? {
        var s = raw ? input : clean(input)
        if !raw, !s.contains("(") { s = s.replacingOccurrences(of: ",", with: "") }
        guard !s.isEmpty, s.contains(where: \.isNumber) || s.contains("pi") else { return nil }
        let calc = Calculator(s)
        guard let v = calc.expr(), calc.i == calc.chars.count, v.isFinite else { return nil }
        return v
    }

    static func format(_ v: Double) -> String {
        if v == v.rounded(), abs(v) < 1e15 { return String(Int64(v)) }
        if abs(v) >= 1e15 || abs(v) < 1e-9 { return String(format: "%.10g", v) }
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.usesGroupingSeparator = false
        f.maximumSignificantDigits = 12
        f.maximumFractionDigits = 10
        return f.string(from: NSNumber(value: v)) ?? String(format: "%.10g", v)
    }

    // MARK: - Parser

    private func peek(_ off: Int = 0) -> Character? { i + off < chars.count ? chars[i + off] : nil }

    private func expr() -> Double? {
        guard var l = term() else { return nil }
        while let c = peek(), c == "+" || c == "-" {
            i += 1
            guard let r0 = term() else { return nil }
            let r = pct ? l * r0 : r0
            l = c == "+" ? l + r : l - r
        }
        return l
    }

    private func startsOperand(_ c: Character?) -> Bool {
        guard let c else { return false }
        return c.isNumber || c.isLetter || c == "(" || c == "."
    }

    private func term() -> Double? {
        pct = false
        guard var l = unary() else { return nil }
        while let c = peek() {
            if c == "*" || c == "/" {
                i += 1
                guard let r = unary() else { return nil }
                l = c == "*" ? l * r : l / r
            } else if c == "%" && startsOperand(peek(1)) {
                i += 1
                guard let r = unary() else { return nil }
                l = l.truncatingRemainder(dividingBy: r)
            } else if startsOperand(c) {          // implicit multiplication: 2pi, 3(4)
                guard let r = unary() else { return nil }
                l *= r
            } else { break }
        }
        return l
    }

    private func unary() -> Double? {
        if peek() == "-" { i += 1; return unary().map { -$0 } }
        if peek() == "+" { i += 1; return unary() }
        return power()
    }

    private func power() -> Double? {
        guard var base = primary() else { return nil }
        // postfix: factorial, degrees, percent
        while let c = peek() {
            if c == "!" {
                guard base >= 0, base <= 170 else { return nil }
                i += 1
                base = tgamma(base + 1).rounded()
            } else if c == "°" {
                i += 1
                base = base * .pi / 180
            } else if c == "%" && !startsOperand(peek(1)) {
                i += 1
                base /= 100
                pct = true
            } else { break }
        }
        if peek() == "^" {
            i += 1
            guard let e = unary() else { return nil }
            pct = false
            return pow(base, e)
        }
        return base
    }

    private static let unaryFns: [String: (Double) -> Double] = [
        "sqrt": sqrt, "cbrt": cbrt, "sin": sin, "cos": cos, "tan": tan,
        "asin": asin, "acos": acos, "atan": atan, "sinh": sinh, "cosh": cosh, "tanh": tanh,
        "asinh": asinh, "acosh": acosh, "atanh": atanh,
        "log": log10, "log10": log10, "log2": log2, "ln": log, "exp": exp, "abs": abs,
        "floor": floor, "ceil": ceil, "round": { $0.rounded() }, "trunc": trunc,
        "deg": { $0 * 180 / .pi }, "rad": { $0 * .pi / 180 },
        "sec": { 1 / cos($0) }, "csc": { 1 / sin($0) }, "cot": { 1 / tan($0) },
        "fact": { tgamma($0 + 1) }, "gamma": tgamma, "sign": { $0 < 0 ? -1 : ($0 > 0 ? 1 : 0) },
    ]
    private static let constants: [String: Double] = [
        "pi": .pi, "e": M_E, "tau": 2 * .pi, "phi": (1 + sqrt(5)) / 2,
    ]

    private func primary() -> Double? {
        guard let c = peek() else { return nil }
        if c == "(" {
            i += 1
            guard let v = expr(), peek() == ")" else { return nil }
            i += 1
            pct = false
            return v
        }
        if c.isNumber || c == "." {
            let start = i
            while let d = peek(), d.isNumber || d == "." { i += 1 }
            // scientific notation: 1.5e3, 2e-4
            if peek() == "e", let n = peek(1), n.isNumber || ((n == "-" || n == "+") && (peek(2)?.isNumber ?? false)) {
                i += 2
                while let d = peek(), d.isNumber { i += 1 }
            }
            pct = false
            return Double(String(chars[start..<i]))
        }
        if c.isLetter {
            let start = i
            while let d = peek(), d.isLetter { i += 1 }
            var j = i                                   // names like log2( / log10(
            while j < chars.count, chars[j].isNumber { j += 1 }
            if j > i, j < chars.count, chars[j] == "(" { i = j }
            let name = String(chars[start..<i])
            pct = false
            if peek() != "(" {
                if let k = Self.constants[name] { return k }
                // bracket-less call: "tan 20", "sqrt 16 + 1", "sin 30°"
                guard let f = Self.unaryFns[name], let a = unary() else { return nil }
                pct = false
                return f(a)
            }
            i += 1
            var args: [Double] = []
            while true {
                guard let a = expr() else { return nil }
                args.append(a)
                if peek() == "," { i += 1; continue }
                break
            }
            guard peek() == ")" else { return nil }
            i += 1
            pct = false
            switch (name, args.count) {
            case ("pow", 2): return pow(args[0], args[1])
            case ("mod", 2): return args[0].truncatingRemainder(dividingBy: args[1])
            case ("atan2", 2): return atan2(args[0], args[1])
            case ("root", 2): return pow(args[1], 1 / args[0])
            case ("log", 2): return log(args[1]) / log(args[0])
            case ("hypot", 2): return hypot(args[0], args[1])
            case ("min", 1...): return args.min()
            case ("max", 1...): return args.max()
            case ("avg", 1...), ("mean", 1...): return args.reduce(0, +) / Double(args.count)
            case ("sum", 1...): return args.reduce(0, +)
            case ("ncr", 2): return tgamma(args[0] + 1) / (tgamma(args[1] + 1) * tgamma(args[0] - args[1] + 1))
            case ("npr", 2): return tgamma(args[0] + 1) / tgamma(args[0] - args[1] + 1)
            case (_, 1): return Self.unaryFns[name]?(args[0])
            default: return nil
            }
        }
        return nil
    }
}
