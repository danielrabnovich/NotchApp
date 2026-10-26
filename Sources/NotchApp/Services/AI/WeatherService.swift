import Foundation

/// Weather from Open-Meteo (free, no API key). Web pages for weather are script-rendered and scrape badly.
struct WeatherReport: Equatable, Sendable, Codable {
    struct Day: Equatable, Sendable, Identifiable, Codable {
        var id: Date { date }
        let date: Date
        let code: Int
        let high: Double
        let low: Double
        let rainChance: Int
        var sunrise: Date? = nil
        var sunset: Date? = nil
        var uvMax: Double = 0
    }

    struct Hour: Equatable, Sendable, Identifiable, Codable {
        var id: Date { date }
        let date: Date
        let code: Int
        let temp: Double
        let rainChance: Int
        let uv: Double
        var isDay = true
    }

    let place: String
    let unit: String
    let currentTemp: Double
    let feelsLike: Double
    let currentCode: Int
    let wind: Double
    let windUnit: String
    let humidity: Int
    let days: [Day]
    /// Which day the question was about (0 = today).
    let focusDay: Int
    var uv: Double = 0
    var isDay = true
    /// The next day's hours, from this one.
    var hours: [Hour] = []

    var summary: String {
        guard days.indices.contains(focusDay) else { return "" }
        let d = days[focusDay]
        let when = focusDay == 0 ? "Today" : focusDay == 1 ? "Tomorrow" : d.date.formatted(.dateTime.weekday(.wide))
        return "\(when) in \(place): \(Self.describe(d.code).lowercased()), high \(Int(d.high.rounded()))°, low \(Int(d.low.rounded()))°, \(d.rainChance)% chance of rain."
    }

    /// The one thing worth knowing about the next few hours, most pressing first: when rain starts
    /// (or stops), strong sun, a strong wind; otherwise how it feels out.
    struct Headline: Equatable {
        enum Kind { case rain, sun, wind, calm }
        let text: String
        let kind: Kind
    }

    var headline: Headline {
        let next = hours.prefix(12)
        let wet: (Int) -> Bool = { $0 >= 50 }
        if Self.isWet(currentCode) {
            if let dry = next.dropFirst().first(where: { !wet($0.rainChance) }) {
                return Headline(text: "\(Self.short(currentCode)) until \(Self.hour(dry.date))", kind: .rain)
            }
            if next.count > 1 { return Headline(text: "\(Self.short(currentCode)) for hours", kind: .rain) }
        } else if let start = next.dropFirst().first(where: { wet($0.rainChance) }) {
            let what = Self.isWet(start.code) ? Self.short(start.code) : "Rain"
            return Headline(text: "\(what) from \(Self.hour(start.date))", kind: .rain)
        }
        let sunny = next.filter { $0.isDay }
        if let peak = sunny.max(by: { $0.uv < $1.uv }), peak.uv >= 6 {
            if uv >= 6, let end = sunny.first(where: { $0.uv < 6 }) {
                return Headline(text: "UV \(Int(uv.rounded())) until \(Self.hour(end.date))", kind: .sun)
            }
            if uv < 6 { return Headline(text: "UV \(Int(peak.uv.rounded())) at \(Self.hour(peak.date))", kind: .sun) }
            return Headline(text: "High UV, \(Int(uv.rounded()))", kind: .sun)
        }
        if wind >= (windUnit == "mph" ? 25 : 40) {
            return Headline(text: "Windy, \(Int(wind.rounded())) \(windUnit)", kind: .wind)
        }
        // How it feels only when that's not just the temperature again.
        var parts = abs(feelsLike - currentTemp) >= 2 ? ["Feels \(Int(feelsLike.rounded()))°"] : []
        if let today = days.first, today.rainChance >= 20 { parts.append("Rain \(today.rainChance)%") }
        else { parts.append("\(humidity)% humid") }
        return Headline(text: parts.joined(separator: " · "), kind: .calm)
    }

    /// "3 PM", or "15:00" where the clock's 24-hour (a bare "15" reads as a number).
    static func hour(_ date: Date) -> String {
        let hour = date.formatted(.dateTime.hour(.defaultDigits(amPM: .abbreviated)))
        return hour.allSatisfy(\.isNumber) ? date.formatted(date: .omitted, time: .shortened) : hour
    }

    static func isWet(_ code: Int) -> Bool {
        (51...67).contains(code) || (71...86).contains(code) || code >= 95
    }

    /// Short enough for a tile: "Storms" rather than "Thunderstorms".
    private static func short(_ code: Int) -> String {
        switch code {
        case 51...57: "Drizzle"
        case 71...77, 85, 86: "Snow"
        case 80...82: "Showers"
        case 95...: "Storms"
        default: "Rain"
        }
    }

    static func describe(_ code: Int) -> String {
        switch code {
        case 0: "Clear"
        case 1: "Mostly clear"
        case 2: "Partly cloudy"
        case 3: "Overcast"
        case 45, 48: "Foggy"
        case 51, 53, 55, 56, 57: "Drizzle"
        case 61, 63, 65, 66, 67: "Rain"
        case 71, 73, 75, 77: "Snow"
        case 80, 81, 82: "Showers"
        case 85, 86: "Snow showers"
        case 95, 96, 99: "Thunderstorms"
        default: "Mixed"
        }
    }

    /// The symbol, with a moon for clear or partly cloudy skies at night.
    static func symbol(_ code: Int, isDay: Bool = true) -> String {
        if !isDay {
            switch code {
            case 0, 1: return "moon.stars.fill"
            case 2: return "cloud.moon.fill"
            default: break
            }
        }
        return switch code {
        case 0: "sun.max.fill"
        case 1: "sun.min.fill"
        case 2: "cloud.sun.fill"
        case 3: "cloud.fill"
        case 45, 48: "cloud.fog.fill"
        case 51, 53, 55, 56, 57: "cloud.drizzle.fill"
        case 61, 63, 65, 66, 67, 80, 81, 82: "cloud.rain.fill"
        case 71, 73, 75, 77, 85, 86: "cloud.snow.fill"
        case 95, 96, 99: "cloud.bolt.rain.fill"
        default: "cloud.sun.fill"
        }
    }
}

enum WeatherService {
    struct WeatherError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func report(location: String?, dayOffset: Int) async throws -> WeatherReport {
        let place = try await geocode(location?.isEmpty == false ? location! : await defaultLocation())
        let fahrenheit = Locale.current.measurementSystem == .us
        var comps = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        comps.queryItems = [
            .init(name: "latitude", value: String(place.lat)),
            .init(name: "longitude", value: String(place.lon)),
            .init(name: "current", value: "temperature_2m,apparent_temperature,weather_code,wind_speed_10m,relative_humidity_2m,uv_index,is_day"),
            .init(name: "hourly", value: "weather_code,temperature_2m,precipitation_probability,uv_index,is_day"),
            .init(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max,sunrise,sunset,uv_index_max"),
            .init(name: "temperature_unit", value: fahrenheit ? "fahrenheit" : "celsius"),
            .init(name: "wind_speed_unit", value: fahrenheit ? "mph" : "kmh"),
            .init(name: "timezone", value: "auto"),
            // A week, so "this weekend" asked on a Monday reaches Saturday.
            .init(name: "forecast_days", value: "7"),
        ]
        let (data, _) = try await URLSession.shared.data(from: comps.url!)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let current = obj["current"] as? [String: Any],
              let daily = obj["daily"] as? [String: Any] else { throw WeatherError(message: "Weather service didn't respond") }

        let num: ([String: Any], String) -> Double = { ($0[$1] as? NSNumber)?.doubleValue ?? 0 }
        let times = daily["time"] as? [String] ?? []
        let codes = daily["weather_code"] as? [NSNumber] ?? []
        let highs = daily["temperature_2m_max"] as? [NSNumber] ?? []
        let lows = daily["temperature_2m_min"] as? [NSNumber] ?? []
        let rain = daily["precipitation_probability_max"] as? [Any] ?? []
        let sunrises = daily["sunrise"] as? [String] ?? [], sunsets = daily["sunset"] as? [String] ?? []
        let uvMaxes = daily["uv_index_max"] as? [Any] ?? []
        // Sun times come in the place's local time ("2026-10-11T18:21").
        let clock = DateFormatter()
        clock.dateFormat = "yyyy-MM-dd'T'HH:mm"
        clock.timeZone = TimeZone(secondsFromGMT: (obj["utc_offset_seconds"] as? NSNumber)?.intValue ?? TimeZone.current.secondsFromGMT())
        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd"
        let days: [WeatherReport.Day] = times.indices.compactMap { i in
            guard let date = parser.date(from: times[i]), codes.indices.contains(i), highs.indices.contains(i), lows.indices.contains(i) else { return nil }
            return .init(date: date, code: codes[i].intValue, high: highs[i].doubleValue, low: lows[i].doubleValue,
                         rainChance: (rain.indices.contains(i) ? (rain[i] as? NSNumber)?.intValue : nil) ?? 0,
                         sunrise: sunrises.indices.contains(i) ? clock.date(from: sunrises[i]) : nil,
                         sunset: sunsets.indices.contains(i) ? clock.date(from: sunsets[i]) : nil,
                         uvMax: (uvMaxes.indices.contains(i) ? (uvMaxes[i] as? NSNumber)?.doubleValue : nil) ?? 0)
        }
        // The hourly figures (in the place's local time too) from this hour on, for a day.
        let hourly = obj["hourly"] as? [String: Any] ?? [:]
        let column: (String) -> [Any] = { hourly[$0] as? [Any] ?? [] }
        let value: ([Any], Int) -> Double? = { $0.indices.contains($1) ? ($0[$1] as? NSNumber)?.doubleValue : nil }
        let hourCodes = column("weather_code"), temps = column("temperature_2m"), chances = column("precipitation_probability")
        let uvs = column("uv_index"), light = column("is_day"), hourTimes = hourly["time"] as? [String] ?? []
        let thisHour = Calendar.current.dateInterval(of: .hour, for: Date())?.start ?? Date()
        let hours: [WeatherReport.Hour] = hourTimes.indices.compactMap { i in
            guard let date = clock.date(from: hourTimes[i]), date >= thisHour,
                  let code = value(hourCodes, i), let temp = value(temps, i) else { return nil }
            return .init(date: date, code: Int(code), temp: temp, rainChance: Int(value(chances, i) ?? 0),
                         uv: value(uvs, i) ?? 0, isDay: value(light, i) != 0)
        }
        return WeatherReport(place: place.name, unit: fahrenheit ? "F" : "C",
                             currentTemp: num(current, "temperature_2m"), feelsLike: num(current, "apparent_temperature"),
                             currentCode: Int(num(current, "weather_code")), wind: num(current, "wind_speed_10m"),
                             windUnit: fahrenheit ? "mph" : "km/h", humidity: Int(num(current, "relative_humidity_2m")),
                             days: days, focusDay: min(max(0, dayOffset), max(0, days.count - 1)),
                             uv: num(current, "uv_index"), isDay: num(current, "is_day") != 0, hours: Array(hours.prefix(24)))
    }

    @MainActor private static func defaultLocation() -> String {
        let home = AppSettings.shared.homeCity.trimmingCharacters(in: .whitespaces)
        if !home.isEmpty { return home }
        // Best guess without asking for location access: the time zone's city.
        return TimeZone.current.identifier.split(separator: "/").last.map { $0.replacingOccurrences(of: "_", with: " ") } ?? "New York"
    }

    private static func geocode(_ query: String) async throws -> (name: String, lat: Double, lon: Double) {
        // "Chapel Hill, NC" → try the full string, then just the city.
        let attempts = [query, query.split(separator: ",").first.map(String.init) ?? query]
        for attempt in attempts {
            var comps = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
            comps.queryItems = [.init(name: "name", value: attempt), .init(name: "count", value: "1"), .init(name: "language", value: "en")]
            let (data, _) = try await URLSession.shared.data(from: comps.url!)
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let first = (obj["results"] as? [[String: Any]])?.first,
               let lat = (first["latitude"] as? NSNumber)?.doubleValue,
               let lon = (first["longitude"] as? NSNumber)?.doubleValue {
                let name = first["name"] as? String ?? attempt
                let region = first["admin1"] as? String
                return (region.map { "\(name), \($0)" } ?? name, lat, lon)
            }
        }
        throw WeatherError(message: "Couldn't find “\(query)”")
    }
}
