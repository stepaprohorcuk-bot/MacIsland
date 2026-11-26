import AppKit
import Combine

// MARK: - Погода (Open-Meteo: бесплатно, без ключей; отправляется только название города и координаты)

@MainActor
final class Weather: ObservableObject {
    static let shared = Weather()

    struct Hour: Identifiable { let id: Date; let temp: Double; let code: Int }

    @Published private(set) var place = ""
    @Published private(set) var temp: Double?
    @Published private(set) var feels: Double?
    @Published private(set) var code = 0
    @Published private(set) var isDay = true
    @Published private(set) var wind: Double = 0
    @Published private(set) var humidity: Double = 0
    @Published private(set) var high: Double?
    @Published private(set) var low: Double?
    @Published private(set) var hours: [Hour] = []
    @Published private(set) var error: String?
    @Published private(set) var loading = false

    private var coords: (lat: Double, lon: Double, city: String)?
    private var lastFetch = Date.distantPast
    private var timer: Timer?
    private var bag = Set<AnyCancellable>()

    func start() {
        AppSettings.shared.$weatherCity.removeDuplicates()
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.coords = nil; self?.refresh(force: true) } }
            .store(in: &bag)
        let t = Timer(timeInterval: 600, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func debugSet(place: String, temp: Double, code: Int, high: Double, low: Double) {
        self.place = place; self.temp = temp; self.feels = temp - 2; self.code = code
        self.high = high; self.low = low; isDay = true; wind = 3; humidity = 0.55
        let now = Date()
        hours = (0..<6).map { Hour(id: now.addingTimeInterval(Double($0) * 3600), temp: temp + Double([0, 1, 1, 0, -1, -2][$0]), code: code) }
    }

    var symbol: String { Self.symbol(code, day: isDay) }
    var condition: String { Self.condition(code) }

    func refresh(force: Bool = false) {
        let s = AppSettings.shared
        let city = s.weatherCity.trimmingCharacters(in: .whitespaces)
        guard s.showWeather, !city.isEmpty else { temp = nil; place = ""; return }
        guard force || Date().timeIntervalSince(lastFetch) > 25 * 60, !loading else { return }
        loading = true
        let lang = String(Locale.preferredLanguages.first?.prefix(2) ?? "en")
        let known = coords?.city == city ? coords : nil
        Task {
            do {
                let c: (lat: Double, lon: Double, city: String, name: String)
                if let k = known { c = (k.lat, k.lon, city, place) } else {
                    var g = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
                    g.queryItems = [.init(name: "name", value: city), .init(name: "count", value: "1"), .init(name: "language", value: lang)]
                    let (d, _) = try await URLSession.shared.data(from: g.url!)
                    let obj = try JSONSerialization.jsonObject(with: d) as? [String: Any]
                    guard let r = (obj?["results"] as? [[String: Any]])?.first,
                          let lat = r["latitude"] as? Double, let lon = r["longitude"] as? Double else {
                        throw APIError(message: L("City not found. Check the name in Settings."))
                    }
                    c = (lat, lon, city, r["name"] as? String ?? city)
                }
                var f = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
                f.queryItems = [
                    .init(name: "latitude", value: String(c.lat)), .init(name: "longitude", value: String(c.lon)),
                    .init(name: "current", value: "temperature_2m,apparent_temperature,weather_code,wind_speed_10m,relative_humidity_2m,is_day"),
                    .init(name: "hourly", value: "temperature_2m,weather_code"),
                    .init(name: "daily", value: "temperature_2m_max,temperature_2m_min"),
                    .init(name: "forecast_days", value: "2"), .init(name: "timezone", value: "auto"),
                    .init(name: "wind_speed_unit", value: "ms"),
                ]
                let (d, _) = try await URLSession.shared.data(from: f.url!)
                guard let o = try JSONSerialization.jsonObject(with: d) as? [String: Any],
                      let cur = o["current"] as? [String: Any] else { throw APIError(message: L("Weather is unavailable right now.")) }
                coords = (c.lat, c.lon, city)
                place = c.name
                temp = cur["temperature_2m"] as? Double
                feels = cur["apparent_temperature"] as? Double
                code = cur["weather_code"] as? Int ?? 0
                isDay = (cur["is_day"] as? Int ?? 1) == 1
                wind = cur["wind_speed_10m"] as? Double ?? 0
                humidity = cur["relative_humidity_2m"] as? Double ?? 0
                if let daily = o["daily"] as? [String: Any] {
                    high = (daily["temperature_2m_max"] as? [Double])?.first
                    low = (daily["temperature_2m_min"] as? [Double])?.first
                }
                if let h = o["hourly"] as? [String: Any], let times = h["time"] as? [String],
                   let temps = h["temperature_2m"] as? [Double], let codes = h["weather_code"] as? [Int] {
                    let df = DateFormatter()
                    df.dateFormat = "yyyy-MM-dd'T'HH:mm"
                    df.timeZone = TimeZone(identifier: o["timezone"] as? String ?? "") ?? .current
                    let now = Date().addingTimeInterval(-3600)
                    hours = zip(times, zip(temps, codes)).compactMap { t, v in
                        guard let date = df.date(from: t), date > now else { return nil }
                        return Hour(id: date, temp: v.0, code: v.1)
                    }.prefix(6).map { $0 }
                }
                error = nil
                lastFetch = Date()
            } catch {
                self.error = (error as? APIError)?.message ?? L("Weather is unavailable right now.")
            }
            loading = false
        }
    }

    static func symbol(_ code: Int, day: Bool) -> String {
        switch code {
        case 0: return day ? "sun.max.fill" : "moon.stars.fill"
        case 1, 2: return day ? "cloud.sun.fill" : "cloud.moon.fill"
        case 3: return "cloud.fill"
        case 45, 48: return "cloud.fog.fill"
        case 51...57: return "cloud.drizzle.fill"
        case 61...67: return "cloud.rain.fill"
        case 71...77, 85, 86: return "cloud.snow.fill"
        case 80...82: return "cloud.heavyrain.fill"
        case 95...99: return "cloud.bolt.rain.fill"
        default: return "cloud.fill"
        }
    }

    static func condition(_ code: Int) -> String {
        switch code {
        case 0: return L("Clear sky")
        case 1, 2: return L("Partly cloudy")
        case 3: return L("Overcast")
        case 45, 48: return L("Fog")
        case 51...57: return L("Drizzle")
        case 61...67, 80...82: return L("Rain")
        case 71...77, 85, 86: return L("Snow")
        case 95...99: return L("Thunderstorm")
        default: return ""
        }
    }

    static func deg(_ v: Double?) -> String {
        guard let v else { return "—" }
        let r = Int(v.rounded())
        return (r > 0 ? "+" : "") + "\(r)°"
    }
}

// MARK: - Быстрые заметки и список дел (хранятся только на этом Mac)

@MainActor
final class NotesStore: ObservableObject {
    static let shared = NotesStore()

    struct Note: Identifiable, Codable, Equatable {
        var id = UUID()
        var text: String
        var done = false
        var date = Date()
    }

    @Published private(set) var notes: [Note] = []
    private var file: URL { AppInfo.supportDir.appendingPathComponent("notes.json") }

    init() {
        if let d = try? Data(contentsOf: file), let n = try? JSONDecoder().decode([Note].self, from: d) { notes = n }
    }

    var openCount: Int { notes.filter { !$0.done }.count }

    func add(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        notes.insert(Note(text: t), at: 0)
        save()
    }
    func toggle(_ n: Note) { if let i = notes.firstIndex(of: n) { notes[i].done.toggle(); save() } }
    func delete(_ n: Note) { notes.removeAll { $0.id == n.id }; save() }
    func clearDone() { notes.removeAll { $0.done }; save() }

    private func save() {
        if let d = try? JSONEncoder().encode(notes) { try? d.write(to: file, options: .atomic) }
    }
}

// MARK: - Быстрый запуск: программы и основные папки

@MainActor
final class AppIndex: ObservableObject {
    static let shared = AppIndex()

    struct Entry: Identifiable, Hashable {
        let id: URL
        let name: String
        var url: URL { id }
    }

    private(set) var entries: [Entry] = []
    private var built = Date.distantPast

    func refreshIfNeeded() {
        guard Date().timeIntervalSince(built) > 600 else { return }
        built = Date()
        DispatchQueue.global(qos: .utility).async {
            let list = AppIndex.scan()
            DispatchQueue.main.async { MainActor.assumeIsolated { AppIndex.shared.entries = list } }
        }
    }

    func buildNow() { entries = Self.scan(); built = Date() }

    nonisolated static func scan() -> [Entry] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        var dirs = ["/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities"]
            .map { URL(fileURLWithPath: $0) }
        dirs.append(home.appendingPathComponent("Applications"))
        var found: [Entry] = []
        for d in dirs {
            for name in (try? fm.contentsOfDirectory(atPath: d.path)) ?? [] where name.hasSuffix(".app") {
                let u = d.appendingPathComponent(name)
                found.append(Entry(id: u, name: fm.displayName(atPath: u.path).replacingOccurrences(of: ".app", with: "")))
            }
        }
        // Основные папки — их тоже можно «открыть»
        for (key, url) in [("Downloads", home.appendingPathComponent("Downloads")), ("Documents", home.appendingPathComponent("Documents")),
                           ("Desktop", home.appendingPathComponent("Desktop")), ("Applications", URL(fileURLWithPath: "/Applications"))] {
            found.append(Entry(id: url, name: L(key)))
        }
        return Array(Set(found)).sorted { $0.name.count < $1.name.count }
    }

    /// «открой телеграм», «тел», «calc» → подходящие программы, лучшие сначала.
    func search(_ raw: String) -> [Entry] {
        var q = raw.lowercased().trimmingCharacters(in: .whitespaces)
        for p in Self.openPrefixes where q.hasPrefix(p) { q = String(q.dropFirst(p.count)); break }
        q = q.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { return [] }
        // «телеграм» → «telegram», «хром» → «chrome»: пробуем и так, и латиницей
        let variants = Array(Set([q, Self.aliases[q] ?? Self.translit(q)]))
        func score(_ e: Entry) -> Int? {
            variants.compactMap { score(e, $0) }.min()
        }
        func score(_ e: Entry, _ q: String) -> Int? {
            let n = e.name.lowercased()
            if n == q { return 0 }
            if n.hasPrefix(q) { return 1 }
            if n.split(separator: " ").contains(where: { $0.hasPrefix(q) }) { return 2 }
            if q.count >= 3 && n.contains(q) { return 3 }
            return nil
        }
        var scored: [(entry: Entry, rank: Int)] = []
        for e in entries { if let r = score(e) { scored.append((e, r)) } }
        scored.sort { a, b in
            if a.rank != b.rank { return a.rank < b.rank }
            return a.entry.name.count < b.entry.name.count
        }
        return Array(scored.prefix(4).map { $0.entry })
    }

    static let aliases: [String: String] = [
        "хром": "chrome", "гугл хром": "chrome", "телега": "telegram", "тг": "telegram", "яндекс": "yandex",
        "ютуб": "youtube", "вотсап": "whatsapp", "ватсап": "whatsapp", "ворд": "word", "эксель": "excel",
        "пауэрпоинт": "powerpoint", "фотошоп": "photoshop", "вскод": "visual studio code", "иксод": "xcode",
        "дискорд": "discord", "спотифай": "spotify", "зум": "zoom", "фигма": "figma", "нотион": "notion",
    ]

    static func translit(_ s: String) -> String {
        let map: [Character: String] = [
            "а": "a", "б": "b", "в": "v", "г": "g", "д": "d", "е": "e", "ё": "e", "ж": "zh", "з": "z", "и": "i",
            "й": "y", "к": "k", "л": "l", "м": "m", "н": "n", "о": "o", "п": "p", "р": "r", "с": "s", "т": "t",
            "у": "u", "ф": "f", "х": "h", "ц": "ts", "ч": "ch", "ш": "sh", "щ": "sch", "ъ": "", "ы": "y", "ь": "",
            "э": "e", "ю": "yu", "я": "ya",
        ]
        return String(s.flatMap { map[$0] ?? String($0) })
    }

    static let openPrefixes = ["открой ", "запусти ", "открыть ", "open ", "launch ", "start "]

    static func isOpenCommand(_ q: String) -> Bool {
        let l = q.lowercased()
        return openPrefixes.contains { l.hasPrefix($0) }
    }

    func open(_ e: Entry) { NSWorkspace.shared.open(e.url) }
}
