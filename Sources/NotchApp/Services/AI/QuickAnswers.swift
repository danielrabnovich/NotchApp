import Foundation

/// Answers that need neither the network nor a model: maths, percentages, unit conversions,
/// the time in other cities and day counts. Instant and offline.
enum QuickAnswers {
    struct Answer: Equatable {
        /// The answer itself, e.g. "36" or "8.05 km".
        let title: String
        /// What was asked, restated, e.g. "15% of 240".
        let subtitle: String
        /// What Return copies.
        let copyValue: String
        let icon: String
    }

    static func answer(_ raw: String) -> Answer? {
        var q = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for prefix in ["what is ", "what's ", "whats ", "calculate ", "calc ", "convert ", "how much is ", "="]
        where q.hasPrefix(prefix) { q.removeFirst(prefix.count) }
        q = q.trimmingCharacters(in: CharacterSet(charactersIn: " ?="))
        guard !q.isEmpty else { return nil }
        return percent(q) ?? conversion(q) ?? timeIn(q) ?? daysUntil(q) ?? today(q) ?? math(q)
    }

    // MARK: - Maths

    private static func math(_ q: String) -> Answer? {
        var expr = q
        for (word, op) in [(" plus ", "+"), (" minus ", "-"), (" times ", "*"), (" divided by ", "/"), (" over ", "/"),
                           ("×", "*"), ("÷", "/"), (" x ", "*"), ("**", "^")] {
            expr = expr.replacingOccurrences(of: word, with: op)
        }
        expr = expr.replacingOccurrences(of: ",", with: "")
        // Needs an operator and a digit, and nothing but maths characters (plus sqrt/pi).
        let allowed = CharacterSet(charactersIn: "0123456789.+-*/^%() sqrtpi")
        guard expr.unicodeScalars.allSatisfy(allowed.contains),
              expr.contains(where: \.isNumber),
              expr.contains(where: { "+-*/^%".contains($0) }) || expr.contains("sqrt"),
              !(expr.hasPrefix("-") && !expr.dropFirst().contains(where: { "+-*/^%".contains($0) })) else { return nil }
        var parser = Parser(expr)
        guard let value = parser.parse(), value.isFinite else { return nil }
        return Answer(title: format(value), subtitle: q, copyValue: format(value, grouping: false), icon: "equal.circle.fill")
    }

    /// Recursive-descent parser for + - * / ^ %, parentheses, sqrt() and pi.
    private struct Parser {
        let chars: [Character]
        var i = 0
        init(_ s: String) { chars = Array(s.filter { $0 != " " }) }

        mutating func parse() -> Double? {
            guard let v = expression(), i == chars.count else { return nil }
            return v
        }

        private mutating func expression() -> Double? {
            guard var v = term() else { return nil }
            while i < chars.count, chars[i] == "+" || chars[i] == "-" {
                let op = chars[i]; i += 1
                guard let r = term() else { return nil }
                v = op == "+" ? v + r : v - r
            }
            return v
        }

        private mutating func term() -> Double? {
            guard var v = power() else { return nil }
            while i < chars.count, chars[i] == "*" || chars[i] == "/" {
                let op = chars[i]; i += 1
                guard let r = power() else { return nil }
                if op == "/" && r == 0 { return nil }
                v = op == "*" ? v * r : v / r
            }
            return v
        }

        private mutating func power() -> Double? {
            guard let base = unary() else { return nil }
            if i < chars.count, chars[i] == "^" {
                i += 1
                guard let exp = power() else { return nil }
                return pow(base, exp)
            }
            return base
        }

        private mutating func unary() -> Double? {
            if i < chars.count, chars[i] == "-" { i += 1; return unary().map { -$0 } }
            if i < chars.count, chars[i] == "+" { i += 1; return unary() }
            guard var v = primary() else { return nil }
            while i < chars.count, chars[i] == "%" { i += 1; v /= 100 }
            return v
        }

        private mutating func primary() -> Double? {
            guard i < chars.count else { return nil }
            if chars[i] == "(" {
                i += 1
                guard let v = expression(), i < chars.count, chars[i] == ")" else { return nil }
                i += 1
                return v
            }
            if match("sqrt") { return primary().flatMap { $0 >= 0 ? $0.squareRoot() : nil } }
            if match("pi") { return .pi }
            let start = i
            while i < chars.count, chars[i].isNumber || chars[i] == "." { i += 1 }
            return i > start ? Double(String(chars[start..<i])) : nil
        }

        private mutating func match(_ word: String) -> Bool {
            let w = Array(word)
            guard i + w.count <= chars.count, Array(chars[i..<i + w.count]) == w else { return false }
            i += w.count
            return true
        }
    }

    // MARK: - Percentages

    private static func percent(_ q: String) -> Answer? {
        let pattern = #"^(-?[\d.,]+)\s*%\s*(of|off)\s*\$?(-?[\d.,]+)$"#
        guard let m = groups(pattern, q), let p = number(m[0]), let base = number(m[2]) else { return nil }
        let value = m[1] == "of" ? base * p / 100 : base * (1 - p / 100)
        return Answer(title: format(value), subtitle: q, copyValue: format(value, grouping: false), icon: "percent")
    }

    // MARK: - Units

    private static func conversion(_ q: String) -> Answer? {
        let pattern = #"^(-?[\d.,]+)\s*([a-z°'"/ ]+?)\s+(?:to|in|into|as)\s+([a-z°'"/ ]+?)$"#
        guard let m = groups(pattern, q), let amount = number(m[0]),
              let from = unit(m[1]), let to = unit(m[2]), type(of: from) == type(of: to) else { return nil }
        let result = Measurement(value: amount, unit: from).converted(to: to)
        let value = format(result.value, maxDecimals: 2)
        return Answer(title: "\(value) \(to.symbol)", subtitle: "\(format(amount)) \(from.symbol)",
                      copyValue: format(result.value, grouping: false, maxDecimals: 2), icon: "arrow.left.arrow.right")
    }

    private static let day = UnitDuration(symbol: "d", converter: UnitConverterLinear(coefficient: 86_400))
    private static let week = UnitDuration(symbol: "wk", converter: UnitConverterLinear(coefficient: 604_800))

    private static func unit(_ raw: String) -> Dimension? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        let table: [String: Dimension] = [
            "mm": UnitLength.millimeters, "millimeter": UnitLength.millimeters, "cm": UnitLength.centimeters,
            "centimeter": UnitLength.centimeters, "m": UnitLength.meters, "meter": UnitLength.meters, "metre": UnitLength.meters,
            "km": UnitLength.kilometers, "kilometer": UnitLength.kilometers, "kilometre": UnitLength.kilometers,
            "in": UnitLength.inches, "inch": UnitLength.inches, "inche": UnitLength.inches, "\"": UnitLength.inches,
            "ft": UnitLength.feet, "foot": UnitLength.feet, "feet": UnitLength.feet, "'": UnitLength.feet,
            "yd": UnitLength.yards, "yard": UnitLength.yards, "mi": UnitLength.miles, "mile": UnitLength.miles,
            "nmi": UnitLength.nauticalMiles,
            "mg": UnitMass.milligrams, "g": UnitMass.grams, "gram": UnitMass.grams, "kg": UnitMass.kilograms,
            "kilogram": UnitMass.kilograms, "kilo": UnitMass.kilograms, "lb": UnitMass.pounds, "lbs": UnitMass.pounds,
            "pound": UnitMass.pounds, "oz": UnitMass.ounces, "ounce": UnitMass.ounces, "st": UnitMass.stones,
            "stone": UnitMass.stones, "tonne": UnitMass.metricTons, "ton": UnitMass.shortTons,
            "c": UnitTemperature.celsius, "°c": UnitTemperature.celsius, "celsius": UnitTemperature.celsius,
            "f": UnitTemperature.fahrenheit, "°f": UnitTemperature.fahrenheit, "fahrenheit": UnitTemperature.fahrenheit,
            "k": UnitTemperature.kelvin, "kelvin": UnitTemperature.kelvin,
            "ml": UnitVolume.milliliters, "milliliter": UnitVolume.milliliters, "l": UnitVolume.liters,
            "liter": UnitVolume.liters, "litre": UnitVolume.liters, "cup": UnitVolume.cups, "tbsp": UnitVolume.tablespoons,
            "tablespoon": UnitVolume.tablespoons, "tsp": UnitVolume.teaspoons, "teaspoon": UnitVolume.teaspoons,
            "floz": UnitVolume.fluidOunces, "fl oz": UnitVolume.fluidOunces, "gal": UnitVolume.gallons,
            "gallon": UnitVolume.gallons, "qt": UnitVolume.quarts, "quart": UnitVolume.quarts, "pt": UnitVolume.pints,
            "pint": UnitVolume.pints,
            "mph": UnitSpeed.milesPerHour, "kph": UnitSpeed.kilometersPerHour, "kmh": UnitSpeed.kilometersPerHour,
            "km/h": UnitSpeed.kilometersPerHour, "m/s": UnitSpeed.metersPerSecond, "knot": UnitSpeed.knots,
            "kn": UnitSpeed.knots,
            "kb": UnitInformationStorage.kilobytes, "mb": UnitInformationStorage.megabytes,
            "gb": UnitInformationStorage.gigabytes, "tb": UnitInformationStorage.terabytes,
            "byte": UnitInformationStorage.bytes,
            "s": UnitDuration.seconds, "sec": UnitDuration.seconds, "second": UnitDuration.seconds,
            "min": UnitDuration.minutes, "minute": UnitDuration.minutes, "h": UnitDuration.hours, "hr": UnitDuration.hours,
            "hour": UnitDuration.hours, "day": day, "week": week,
        ]
        if let u = table[s] { return u }
        if s.hasSuffix("s"), let u = table[String(s.dropLast())] { return u }   // plurals
        if s.hasPrefix("degrees "), let u = table[String(s.dropFirst(8))] { return u }
        return nil
    }

    // MARK: - Time in another city

    private static func timeIn(_ q: String) -> Answer? {
        let place = groups(#"^(?:the )?time (?:is it )?in (.+)$"#, q)?.first
            ?? groups(#"^what time is it in (.+)$"#, q)?.first
            ?? groups(#"^(.+?) time$"#, q)?.first
        guard let place, let zone = timeZone(for: place) else { return nil }
        let now = Date()
        // Follows the system 12/24-hour preference.
        let time = now.formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: zone))
        let dayFormatter = DateFormatter()
        dayFormatter.timeZone = zone
        dayFormatter.dateFormat = "EEEE"
        let diff = (zone.secondsFromGMT(for: now) - TimeZone.current.secondsFromGMT(for: now)) / 60
        let offset: String = {
            if diff == 0 { return "same time as you" }
            let h = abs(diff) / 60, m = abs(diff) % 60
            let amount = m == 0 ? "\(h) hour\(h == 1 ? "" : "s")" : "\(h)h \(m)m"
            return "\(amount) \(diff > 0 ? "ahead" : "behind")"
        }()
        let city = place.split(separator: " ").map { $0.capitalized }.joined(separator: " ")
        return Answer(title: time, subtitle: "\(city) · \(dayFormatter.string(from: now)) · \(offset)",
                      copyValue: time, icon: "clock.fill")
    }

    private static let cityAliases: [String: String] = [
        "nyc": "America/New_York", "new york": "America/New_York", "boston": "America/New_York", "miami": "America/New_York",
        "washington": "America/New_York", "dc": "America/New_York", "atlanta": "America/New_York",
        "charlotte": "America/New_York", "philadelphia": "America/New_York", "toronto": "America/Toronto",
        "chicago": "America/Chicago", "dallas": "America/Chicago", "houston": "America/Chicago", "austin": "America/Chicago",
        "denver": "America/Denver", "phoenix": "America/Phoenix", "la": "America/Los_Angeles",
        "los angeles": "America/Los_Angeles", "sf": "America/Los_Angeles", "san francisco": "America/Los_Angeles",
        "seattle": "America/Los_Angeles", "vancouver": "America/Vancouver", "hawaii": "Pacific/Honolulu",
        "uk": "Europe/London", "england": "Europe/London", "france": "Europe/Paris", "germany": "Europe/Berlin",
        "spain": "Europe/Madrid", "italy": "Europe/Rome", "rome": "Europe/Rome", "netherlands": "Europe/Amsterdam",
        "russia": "Europe/Moscow", "israel": "Asia/Jerusalem", "tel aviv": "Asia/Jerusalem", "dubai": "Asia/Dubai",
        "india": "Asia/Kolkata", "delhi": "Asia/Kolkata", "new delhi": "Asia/Kolkata", "mumbai": "Asia/Kolkata",
        "bangalore": "Asia/Kolkata", "china": "Asia/Shanghai", "beijing": "Asia/Shanghai", "japan": "Asia/Tokyo",
        "korea": "Asia/Seoul", "australia": "Australia/Sydney", "melbourne": "Australia/Melbourne",
        "new zealand": "Pacific/Auckland", "brazil": "America/Sao_Paulo", "mexico": "America/Mexico_City",
        "mexico city": "America/Mexico_City", "ukraine": "Europe/Kyiv", "kyiv": "Europe/Kyiv", "kiev": "Europe/Kyiv",
        "utc": "UTC", "gmt": "GMT",
    ]

    private static func timeZone(for place: String) -> TimeZone? {
        let p = place.trimmingCharacters(in: .whitespaces)
        if let id = cityAliases[p] { return TimeZone(identifier: id) }
        let match = TimeZone.knownTimeZoneIdentifiers.first {
            $0.split(separator: "/").last.map { $0.replacingOccurrences(of: "_", with: " ").lowercased() } == p
        }
        return match.flatMap(TimeZone.init(identifier:))
    }

    // MARK: - Dates

    private static func daysUntil(_ q: String) -> Answer? {
        guard let target = groups(#"^(?:how many )?days (?:until|till|til|to|before) (.+)$"#, q)?.first,
              let date = date(from: target) else { return nil }
        let cal = Calendar.current
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: Date()), to: cal.startOfDay(for: date)).day ?? 0
        let when = date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day().year())
        return Answer(title: "\(days) day\(abs(days) == 1 ? "" : "s")", subtitle: "until \(when)",
                      copyValue: "\(days)", icon: "calendar")
    }

    private static func today(_ q: String) -> Answer? {
        guard ["date", "the date", "today's date", "todays date", "what day is it", "what day is today", "day"].contains(q)
        else { return nil }
        let text = Date().formatted(.dateTime.weekday(.wide).month(.wide).day().year())
        return Answer(title: text, subtitle: "Today", copyValue: text, icon: "calendar")
    }

    private static func date(from text: String) -> Date? {
        let cal = Calendar.current
        let now = Date()
        func next(month: Int, day: Int) -> Date? {
            let year = cal.component(.year, from: now)
            for y in [year, year + 1] {
                if let d = cal.date(from: DateComponents(year: y, month: month, day: day)), d >= cal.startOfDay(for: now) { return d }
            }
            return nil
        }
        switch text {
        case "christmas": return next(month: 12, day: 25)
        case "new year", "new years", "new year's", "new years day": return next(month: 1, day: 1)
        case "halloween": return next(month: 10, day: 31)
        case "valentines", "valentine's day", "valentines day": return next(month: 2, day: 14)
        case "independence day", "july 4th", "4th of july": return next(month: 7, day: 4)
        default: break
        }
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
        return detector?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))?.date
    }

    // MARK: - Helpers

    private static func groups(_ pattern: String, _ s: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        return (1..<m.numberOfRanges).map { i in
            Range(m.range(at: i), in: s).map { String(s[$0]) } ?? ""
        }
    }

    private static func number(_ s: String) -> Double? { Double(s.replacingOccurrences(of: ",", with: "")) }

    static func format(_ v: Double, grouping: Bool = true, maxDecimals: Int? = nil) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.usesGroupingSeparator = grouping
        f.maximumFractionDigits = maxDecimals.map { abs(v) < 1 ? max($0, 4) : $0 } ?? (abs(v) >= 100 ? 2 : abs(v) >= 1 ? 4 : 6)
        return f.string(from: NSNumber(value: v)) ?? String(v)
    }
}
