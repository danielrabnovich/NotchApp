import Foundation

/// Weather from Open-Meteo (free, no API key). Web pages for weather are script-rendered and scrape badly.
struct WeatherReport: Equatable, Sendable {
    struct Day: Equatable, Sendable, Identifiable {
        var id: Date { date }
        let date: Date
        let code: Int
        let high: Double
        let low: Double
        let rainChance: Int
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

    var summary: String {
        guard days.indices.contains(focusDay) else { return "" }
        let d = days[focusDay]
        let when = focusDay == 0 ? "Today" : focusDay == 1 ? "Tomorrow" : d.date.formatted(.dateTime.weekday(.wide))
        return "\(when) in \(place): \(Self.describe(d.code).lowercased()), high \(Int(d.high.rounded()))°, low \(Int(d.low.rounded()))°, \(d.rainChance)% chance of rain."
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

    static func symbol(_ code: Int) -> String {
        switch code {
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
            .init(name: "current", value: "temperature_2m,apparent_temperature,weather_code,wind_speed_10m,relative_humidity_2m"),
            .init(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max"),
            .init(name: "temperature_unit", value: fahrenheit ? "fahrenheit" : "celsius"),
            .init(name: "wind_speed_unit", value: fahrenheit ? "mph" : "kmh"),
            .init(name: "timezone", value: "auto"),
            .init(name: "forecast_days", value: "5"),
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
        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd"
        let days: [WeatherReport.Day] = times.indices.compactMap { i in
            guard let date = parser.date(from: times[i]), codes.indices.contains(i), highs.indices.contains(i), lows.indices.contains(i) else { return nil }
            return .init(date: date, code: codes[i].intValue, high: highs[i].doubleValue, low: lows[i].doubleValue,
                         rainChance: (rain.indices.contains(i) ? (rain[i] as? NSNumber)?.intValue : nil) ?? 0)
        }
        return WeatherReport(place: place.name, unit: fahrenheit ? "F" : "C",
                             currentTemp: num(current, "temperature_2m"), feelsLike: num(current, "apparent_temperature"),
                             currentCode: Int(num(current, "weather_code")), wind: num(current, "wind_speed_10m"),
                             windUnit: fahrenheit ? "mph" : "km/h", humidity: Int(num(current, "relative_humidity_2m")),
                             days: days, focusDay: min(max(0, dayOffset), max(0, days.count - 1)))
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
