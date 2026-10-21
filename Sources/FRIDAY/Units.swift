import Foundation

/// Unit conversion: "5 km to miles", "100 f to c", "2 hours in minutes", "10 gb to mb".
enum Units {
    private struct Unit { let cat: String; let factor: Double; let offset: Double }

    private static func table() -> [String: Unit] {
        var t: [String: Unit] = [:]
        func add(_ cat: String, _ factor: Double, _ names: String, offset: Double = 0) {
            for n in names.split(separator: " ") { t[n.replacingOccurrences(of: "_", with: " ")] = Unit(cat: cat, factor: factor, offset: offset) }
        }
        // length (m)
        add("len", 1, "m meter metre meters metres")
        add("len", 1000, "km kilometer kilometre kilometers kilometres")
        add("len", 0.01, "cm centimeter centimetre centimeters centimetres")
        add("len", 0.001, "mm millimeter millimetre millimeters millimetres")
        add("len", 1e-6, "um µm micron microns micrometer micrometers")
        add("len", 1e-9, "nm nanometer nanometers")
        add("len", 1609.344, "mi mile miles")
        add("len", 0.9144, "yd yard yards")
        add("len", 0.3048, "ft foot feet")
        add("len", 0.0254, "in inch inches")
        add("len", 1852, "nmi nauticalmile nauticalmiles")
        add("len", 9.4607304725808e15, "ly lightyear lightyears")
        // mass (kg)
        add("mass", 1, "kg kilogram kilograms kilo kilos")
        add("mass", 0.001, "g gram grams gm")
        add("mass", 1e-6, "mg milligram milligrams")
        add("mass", 1e-9, "ug µg microgram micrograms")
        add("mass", 1000, "t tonne tonnes metricton")
        add("mass", 0.45359237, "lb lbs pound pounds")
        add("mass", 0.028349523125, "oz ounce ounces")
        add("mass", 6.35029318, "st stone stones")
        add("mass", 907.18474, "ton tons shortton")
        // volume (L)
        add("vol", 1, "l lt ltr liter litre liters litres")
        add("vol", 0.001, "ml milliliter millilitre milliliters millilitres")
        add("vol", 0.01, "cl centiliter centilitre")
        add("vol", 1000, "m3 cubicmeter cubicmeters")
        add("vol", 3.785411784, "gal gallon gallons")
        add("vol", 0.946352946, "qt quart quarts")
        add("vol", 0.473176473, "pt pint pints")
        add("vol", 0.2365882365, "cup cups")
        add("vol", 0.0295735295625, "floz fl_oz fluidounce fluidounces")
        add("vol", 0.01478676478125, "tbsp tablespoon tablespoons")
        add("vol", 0.00492892159375, "tsp teaspoon teaspoons")
        // time (s)
        add("time", 1, "s sec secs second seconds")
        add("time", 0.001, "ms millisecond milliseconds")
        add("time", 1e-6, "µs us microsecond microseconds")
        add("time", 60, "min mins minute minutes")
        add("time", 3600, "h hr hrs hour hours")
        add("time", 86400, "d day days")
        add("time", 604800, "wk week weeks")
        add("time", 2629746, "mo month months")
        add("time", 31556952, "y yr yrs year years")
        // data (byte)
        add("data", 0.125, "bit bits")
        add("data", 1, "byte bytes")
        add("data", 1e3, "kb kilobyte kilobytes")
        add("data", 1e6, "mb megabyte megabytes")
        add("data", 1e9, "gb gigabyte gigabytes")
        add("data", 1e12, "tb terabyte terabytes")
        add("data", 1e15, "pb petabyte petabytes")
        add("data", 1024, "kib kibibyte")
        add("data", 1048576, "mib mebibyte")
        add("data", 1073741824, "gib gibibyte")
        add("data", 1099511627776, "tib tebibyte")
        // area (m²)
        add("area", 1, "m2 sqm m² squaremeter squaremeters")
        add("area", 1e6, "km2 sqkm km² squarekilometer squarekilometers")
        add("area", 1e-4, "cm2 sqcm cm²")
        add("area", 10000, "ha hectare hectares")
        add("area", 4046.8564224, "acre acres")
        add("area", 0.09290304, "ft2 sqft ft² squarefoot squarefeet")
        add("area", 0.00064516, "in2 sqin in²")
        add("area", 2589988.110336, "mi2 sqmi mi²")
        // speed (m/s)
        add("speed", 1, "m/s mps")
        add("speed", 1 / 3.6, "km/h kmh kph kmph")
        add("speed", 0.44704, "mph mi/h")
        add("speed", 0.514444, "kn kt knot knots")
        add("speed", 0.3048, "ft/s fps")
        // energy (J)
        add("energy", 1, "j joule joules")
        add("energy", 1000, "kj kilojoule kilojoules")
        add("energy", 4.184, "cal calorie calories")
        add("energy", 4184, "kcal kilocalorie kilocalories")
        add("energy", 3600, "wh")
        add("energy", 3.6e6, "kwh")
        // power (W)
        add("power", 1, "w watt watts")
        add("power", 1000, "kw kilowatt kilowatts")
        add("power", 1e6, "mw megawatt megawatts")
        add("power", 745.69987158, "hp horsepower")
        // pressure (Pa)
        add("press", 1, "pa pascal")
        add("press", 1000, "kpa kilopascal")
        add("press", 100000, "bar")
        add("press", 6894.757293, "psi")
        add("press", 101325, "atm")
        add("press", 133.322387, "mmhg torr")
        // angle (rad)
        add("angle", 1, "rad radian radians")
        add("angle", .pi / 180, "deg degree degrees °")
        add("angle", 2 * .pi, "turn turns rev")
        // temperature (°C)
        add("temp", 1, "c °c celsius centigrade")
        add("temp", 5.0 / 9, "f °f fahrenheit", offset: -32 * 5.0 / 9)
        add("temp", 1, "k kelvin", offset: -273.15)
        return t
    }

    private static let units = table()

    private static func lookup(_ raw: String) -> (key: String, unit: Unit)? {
        var k = raw.lowercased().trimmingCharacters(in: .whitespaces)
        for cand in [k, k.replacingOccurrences(of: " ", with: ""), k.replacingOccurrences(of: " ", with: "_"),
                     k.hasSuffix("s") ? String(k.dropLast()) : k] {
            if let u = units[cand] { return (cand, u) }
        }
        k = k.replacingOccurrences(of: "square ", with: "sq").replacingOccurrences(of: "sq ", with: "sq")
        if let u = units[k] { return (k, u) }
        return nil
    }

    /// Returns (formatted number, target unit as typed) or nil if `input` isn't a unit conversion.
    static func convert(_ input: String) -> (value: String, unit: String)? {
        let s = input.trimmingCharacters(in: .whitespaces)
        // last connector wins, so "5 in to cm" and "5 ft in in" both work
        let connector = try! NSRegularExpression(pattern: #"(?:\s+(?:to|into|in|as)(?=\s)|\s*->|\s*=>)"#, options: .caseInsensitive)
        guard let m = connector.matches(in: s, range: NSRange(s.startIndex..., in: s)).last,
              let r = Range(m.range, in: s) else { return nil }
        let left = String(s[..<r.lowerBound]), right = String(s[r.upperBound...]).trimmingCharacters(in: .whitespaces)

        let leftPattern = try! NSRegularExpression(pattern: #"^(.*?[\d)])\s*([a-zA-Z°µ][a-zA-Z°µ0-9²/ ]*)$"#)
        guard let lm = leftPattern.firstMatch(in: left, range: NSRange(left.startIndex..., in: left)),
              let aR = Range(lm.range(at: 1), in: left), let uR = Range(lm.range(at: 2), in: left),
              let amount = Calculator.value(String(left[aR])),
              let from = lookup(String(left[uR])), let to = lookup(right), from.unit.cat == to.unit.cat
        else { return nil }

        let base = amount * from.unit.factor + from.unit.offset
        let out = (base - to.unit.offset) / to.unit.factor
        guard out.isFinite else { return nil }
        return (Calculator.format(out), right.trimmingCharacters(in: .whitespaces))
    }
}
