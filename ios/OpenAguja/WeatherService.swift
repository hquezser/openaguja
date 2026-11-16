import CoreLocation
import Foundation

#if canImport(OpenAgujaCore)
    import OpenAgujaCore
#endif

/// Météo envoyée à la montre (0x77) : Open-Meteo (gratuit, sans clé —
/// WeatherKit demande un compte développeur payant), pour la position du
/// téléphone ou une ville choisie.
final class WeatherService: NSObject, ObservableObject {
    enum Source: String, CaseIterable, Identifiable {
        case location, city

        var id: String { rawValue }
        var label: String { self == .location ? "Position actuelle" : "Chosen city" }
    }

    struct Snapshot: Codable, Equatable {
        var place: String
        var currentC: Double
        var minC: Double
        var maxC: Double
        var wmoCode: Int
        var isDay: Bool
        var days: [Day]
        var fetchedAt: Date

        struct Day: Codable, Equatable {
            var minC: Double
            var maxC: Double
            var wmoCode: Int
        }
    }

    @Published var enabled: Bool { didSet { defaults.set(enabled, forKey: Keys.enabled) } }
    @Published var source: Source { didSet { defaults.set(source.rawValue, forKey: Keys.source) } }
    @Published private(set) var cityName: String
    @Published private(set) var snapshot: Snapshot?
    @Published private(set) var lastError: String?
    @Published private(set) var busy = false

    /// Rafraîchissement automatique au-delà de cet âge.
    static let maxAge: TimeInterval = 3600

    private enum Keys {
        static let enabled = "weather.enabled"
        static let source = "weather.source"
        static let city = "weather.city"
        static let lat = "weather.lat"
        static let lon = "weather.lon"
        static let snapshot = "weather.snapshot"
    }

    private let defaults: UserDefaults
    private let log: LogStore
    private let locationManager = CLLocationManager()
    private var locationContinuation: CheckedContinuation<CLLocation, Error>?

    init(log: LogStore, defaults: UserDefaults = .standard) {
        self.log = log
        self.defaults = defaults
        enabled = defaults.object(forKey: Keys.enabled) as? Bool ?? true
        source = Source(rawValue: defaults.string(forKey: Keys.source) ?? "") ?? .location
        cityName = defaults.string(forKey: Keys.city) ?? ""
        if let data = defaults.data(forKey: Keys.snapshot) {
            snapshot = try? JSONDecoder().decode(Snapshot.self, from: data)
        }
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
    }

    var isStale: Bool {
        guard let snapshot else { return true }
        return Date().timeIntervalSince(snapshot.fetchedAt) > Self.maxAge
    }

    /// Choisit une ville par son nom (géocodage Open-Meteo).
    @MainActor
    func setCity(_ query: String) async {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        busy = true
        defer { busy = false }
        do {
            var components = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
            components.queryItems = [
                URLQueryItem(name: "name", value: trimmed),
                URLQueryItem(name: "count", value: "1"),
                URLQueryItem(name: "language", value: "fr"),
            ]
            let (data, _) = try await URLSession.shared.data(from: components.url!)
            let result = try JSONDecoder().decode(GeocodingResponse.self, from: data)
            guard let place = result.results?.first else {
                lastError = "Ville introuvable : \(trimmed)"
                return
            }
            cityName = place.name
            defaults.set(place.name, forKey: Keys.city)
            defaults.set(place.latitude, forKey: Keys.lat)
            defaults.set(place.longitude, forKey: Keys.lon)
            source = .city
            lastError = nil
        } catch {
            lastError = "Geocoding: \(error.localizedDescription)"
        }
    }

    /// Récupère la météo et l'envoie à la montre si elle est connectée.
    @MainActor
    func refresh(sendTo watch: ZeTimeBluetoothManager?) async {
        guard enabled else { return }
        busy = true
        defer { busy = false }
        do {
            let (lat, lon, place) = try await coordinates()
            let fresh = try await fetch(latitude: lat, longitude: lon, place: place)
            snapshot = fresh
            defaults.set(try? JSONEncoder().encode(fresh), forKey: Keys.snapshot)
            lastError = nil
            log.add(.info, "Weather \(place): \(Int(fresh.currentC.rounded())) °C, code \(fresh.wmoCode)")
            if let watch, watch.isReady {
                try await watch.perform(.sendWeather(report: report(from: fresh)), label: String(localized: "Weather"))
            }
        } catch {
            lastError = error.localizedDescription
            log.add(.error, "Weather: \(error.localizedDescription)")
        }
    }

    /// Envoi du dernier relevé sans nouvel appel réseau.
    @MainActor
    func resend(to watch: ZeTimeBluetoothManager) async {
        guard let snapshot else { return }
        do {
            try await watch.perform(.sendWeather(report: report(from: snapshot)), label: String(localized: "Weather"))
        } catch {
            lastError = error.localizedDescription
        }
    }

    func report(from s: Snapshot) -> WeatherReport {
        func c(_ v: Double) -> Int8 { Int8(clamping: Int(v.rounded())) }
        return WeatherReport(
            location: Self.watchLabel(s.place),
            currentC: c(s.currentC),
            minC: c(s.minC),
            maxC: c(s.maxC),
            condition: zetimeConditionFromWmo(wmoCode: UInt8(clamping: s.wmoCode), isDay: s.isDay),
            forecasts: s.days.prefix(3).map {
                DayForecast(minC: c($0.minC), maxC: c($0.maxC), condition: zetimeConditionFromWmo(wmoCode: UInt8(clamping: $0.wmoCode), isDay: true))
            }
        )
    }

    /// Nom affichable par la police de la montre : majuscules sans accents
    /// (comme « GENEVA » envoyé par l'app officielle), 16 caractères max.
    static func watchLabel(_ place: String) -> String {
        let folded = place.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US"))
        return String(folded.uppercased().prefix(16))
    }

    /// Pluie dans l'heure (Open-Meteo, pas de 15 min) + température.
    @MainActor
    func nextHourRain() async throws -> String {
        let (lat, lon, _) = try await coordinates()
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(lat)),
            URLQueryItem(name: "longitude", value: String(lon)),
            URLQueryItem(name: "current", value: "temperature_2m"),
            URLQueryItem(name: "minutely_15", value: "precipitation"),
            URLQueryItem(name: "forecast_minutely_15", value: "5"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "timeformat", value: "unixtime"),
        ]
        let (data, _) = try await URLSession.shared.data(from: components.url!)
        let r = try JSONDecoder().decode(RainResponse.self, from: data)
        let temperature = "\(Int(r.current.temperature_2m.rounded()))°"
        let slots = zip(r.minutely_15.time, r.minutely_15.precipitation)
        guard let wet = slots.first(where: { $0.1 >= 0.1 }) else {
            return "\(temperature), no rain within the hour"
        }
        let at = Date(timeIntervalSince1970: TimeInterval(wet.0))
        if at <= Date() {
            return "\(temperature), il pleut (\(String(format: "%.1f", wet.1)) mm)"
        }
        return "\(temperature), pluie vers \(at.formatted(date: .omitted, time: .shortened))"
    }

    private struct RainResponse: Decodable {
        struct Current: Decodable { let temperature_2m: Double }
        struct Minutely: Decodable {
            let time: [Int]
            let precipitation: [Double]
        }
        let current: Current
        let minutely_15: Minutely
    }

    // MARK: - Interne

    @MainActor
    private func coordinates() async throws -> (Double, Double, String) {
        if source == .city {
            guard let lat = defaults.object(forKey: Keys.lat) as? Double,
                  let lon = defaults.object(forKey: Keys.lon) as? Double
            else { throw WatchError.invalid("No city chosen (Settings → Weather)") }
            return (lat, lon, cityName)
        }
        let location = try await currentLocation()
        let place = (try? await CLGeocoder().reverseGeocodeLocation(location).first?.locality) ?? nil
        return (location.coordinate.latitude, location.coordinate.longitude, place ?? "Here")
    }

    @MainActor
    private func currentLocation() async throws -> CLLocation {
        let status = locationManager.authorizationStatus
        if status == .denied || status == .restricted {
            throw WatchError.invalid("Location denied: choose a city in settings")
        }
        // Position récente déjà connue : pas de nouvelle demande.
        if status != .notDetermined, let last = locationManager.location,
           Date().timeIntervalSince(last.timestamp) < 1800
        {
            return last
        }
        return try await withCheckedThrowingContinuation { continuation in
            locationContinuation?.resume(throwing: WatchError.invalid("Location request superseded"))
            locationContinuation = continuation
            if status == .notDetermined {
                // La position est demandée une fois l'autorisation donnée
                // (locationManagerDidChangeAuthorization).
                #if os(iOS)
                    locationManager.requestWhenInUseAuthorization()
                #endif
            } else {
                locationManager.requestLocation()
            }
        }
    }

    private func fetch(latitude: Double, longitude: Double, place: String) async throws -> Snapshot {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(latitude)),
            URLQueryItem(name: "longitude", value: String(longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,weather_code,is_day"),
            URLQueryItem(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "forecast_days", value: "4"),
        ]
        let (data, response) = try await URLSession.shared.data(from: components.url!)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(status) else { throw WatchError.invalid("Open-Meteo : HTTP \(status)") }
        let r = try JSONDecoder().decode(ForecastResponse.self, from: data)
        let daily = r.daily
        let count = min(daily.weather_code.count, daily.temperature_2m_max.count, daily.temperature_2m_min.count)
        guard count > 0 else { throw WatchError.invalid("Open-Meteo: empty forecast") }
        // Jour 0 = aujourd'hui (min/max), jours 1-3 = prévisions.
        let days = (1..<count).map {
            Snapshot.Day(minC: daily.temperature_2m_min[$0], maxC: daily.temperature_2m_max[$0], wmoCode: daily.weather_code[$0])
        }
        return Snapshot(
            place: place,
            currentC: r.current.temperature_2m,
            minC: daily.temperature_2m_min[0],
            maxC: daily.temperature_2m_max[0],
            wmoCode: r.current.weather_code,
            isDay: r.current.is_day == 1,
            days: days,
            fetchedAt: Date()
        )
    }

    private struct GeocodingResponse: Decodable {
        struct Place: Decodable {
            let name: String
            let latitude: Double
            let longitude: Double
        }

        let results: [Place]?
    }

    // swiftlint:disable identifier_name — noms du JSON Open-Meteo
    private struct ForecastResponse: Decodable {
        struct Current: Decodable {
            let temperature_2m: Double
            let weather_code: Int
            let is_day: Int
        }

        struct Daily: Decodable {
            let weather_code: [Int]
            let temperature_2m_max: [Double]
            let temperature_2m_min: [Double]
        }

        let current: Current
        let daily: Daily
    }
}

extension WeatherService: CLLocationManagerDelegate {
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        locationContinuation?.resume(returning: location)
        locationContinuation = nil
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard locationContinuation != nil else { return }
        switch manager.authorizationStatus {
        case .notDetermined:
            break
        case .denied, .restricted:
            locationContinuation?.resume(throwing: WatchError.invalid("Location denied: choose a city in settings"))
            locationContinuation = nil
        default:
            manager.requestLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        locationContinuation?.resume(throwing: error)
        locationContinuation = nil
    }
}

extension WeatherService {
    /// Symbole SF pour un code WMO (affichage dans l'app).
    static func symbol(wmo: Int, isDay: Bool = true) -> String {
        switch wmo {
        case 0: return isDay ? "sun.max.fill" : "moon.stars.fill"
        case 1, 2: return isDay ? "cloud.sun.fill" : "cloud.moon.fill"
        case 3: return "cloud.fill"
        case 45, 48: return "cloud.fog.fill"
        case 51, 53, 55, 56, 57: return "cloud.drizzle.fill"
        case 61, 63, 65, 66, 67, 80, 81, 82: return "cloud.rain.fill"
        case 71, 73, 75, 77, 85, 86: return "cloud.snow.fill"
        case 95, 96, 99: return "cloud.bolt.rain.fill"
        default: return "questionmark.circle"
        }
    }
}
