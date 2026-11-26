import AppKit
import Combine
import Foundation

func clock(_ seconds: TimeInterval) -> String {
    let s = max(0, Int(ceil(seconds)))
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                     : String(format: "%02d:%02d", s / 60, s % 60)
}

// MARK: - Обычные таймеры (несколько сразу) и секундомер

@MainActor
final class Timers: ObservableObject {
    static let shared = Timers()

    struct Item: Identifiable, Equatable {
        let id = UUID()
        var total: TimeInterval          // 0 — секундомер
        var endsAt: Date?                // идёт обратный отсчёт
        var startedAt: Date?             // идёт секундомер
        var stored: TimeInterval         // остаток (таймер) или накоплено (секундомер), пока на паузе
        var finished = false

        var isStopwatch: Bool { total == 0 }
        var running: Bool { endsAt != nil || startedAt != nil }

        func value(at now: Date) -> TimeInterval {
            if isStopwatch { return stored + (startedAt.map { now.timeIntervalSince($0) } ?? 0) }
            return endsAt.map { max(0, $0.timeIntervalSince(now)) } ?? stored
        }
        var title: String {
            isStopwatch ? L("Stopwatch") : Lf("Timer %@", clock(total))
        }
    }

    @Published private(set) var items: [Item] = []
    let finishedEvent = PassthroughSubject<Item, Never>()
    private var ticker: Timer?

    var active: Bool { !items.isEmpty }

    func start(seconds: TimeInterval) {
        let s = seconds.rounded()
        guard s >= 1 else { return }
        items.append(Item(total: s, endsAt: Date().addingTimeInterval(s), startedAt: nil, stored: s))
        ensureTicker()
    }

    func startStopwatch() {
        items.append(Item(total: 0, endsAt: nil, startedAt: Date(), stored: 0))
        ensureTicker()
    }

    func toggle(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        let now = Date()
        var it = items[i]
        if it.finished { return }
        if it.isStopwatch {
            if let s = it.startedAt { it.stored += now.timeIntervalSince(s); it.startedAt = nil } else { it.startedAt = now }
        } else {
            if let e = it.endsAt { it.stored = max(0, e.timeIntervalSince(now)); it.endsAt = nil }
            else { it.endsAt = now.addingTimeInterval(it.stored) }
        }
        items[i] = it
        ensureTicker()
    }

    /// Быстрый повтор: тот же таймер ещё раз.
    func repeatTimer(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        let t = items[i].total
        items.remove(at: i)
        if t > 0 { start(seconds: t) } else { startStopwatch() }
    }

    func remove(_ id: UUID) { items.removeAll { $0.id == id } }

    private func ensureTicker() {
        guard ticker == nil else { return }
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    private func tick() {
        let now = Date()
        for i in items.indices where !items[i].isStopwatch && !items[i].finished {
            if let e = items[i].endsAt, e <= now {
                items[i].endsAt = nil
                items[i].stored = 0
                items[i].finished = true
                NSSound(named: "Glass")?.play()
                finishedEvent.send(items[i])
            }
        }
        if !items.contains(where: { $0.running }) { ticker?.invalidate(); ticker = nil }
    }

    /// «5 мин», «10m», «1:30», «таймер 20», «90 сек», «1h» → секунды. nil — это не таймер.
    nonisolated static func parse(_ text: String) -> TimeInterval? {
        var s = text.lowercased().trimmingCharacters(in: .whitespaces)
        for p in ["таймер на ", "таймер ", "timer for ", "timer ", "поставь таймер на ", "set a timer for "] where s.hasPrefix(p) {
            s = String(s.dropFirst(p.count)); break
        }
        s = s.trimmingCharacters(in: .whitespaces)
        // 1:30 → полторы минуты
        let colon = s.split(separator: ":")
        if colon.count == 2, let m = Int(colon[0]), let sec = Int(colon[1]), sec < 60 { return TimeInterval(m * 60 + sec) }

        let scanner = Scanner(string: s)
        guard let n = scanner.scanDouble(), n > 0, n <= 24 * 60 else { return nil }
        let unit = s[scanner.currentIndex...].trimmingCharacters(in: .whitespaces)
        let minutes = ["", "m", "min", "mins", "minute", "minutes", "м", "мин", "минут", "минута", "минуты", "минуту"]
        let seconds = ["s", "sec", "secs", "second", "seconds", "с", "сек", "секунд", "секунда", "секунды", "секунду"]
        let hours = ["h", "hr", "hour", "hours", "ч", "час", "часа", "часов"]
        if unit.isEmpty && s != String(Int(n)) { return nil }
        if minutes.contains(unit) {
            // одно голое число — считаем минутами, только если запрос начинался со слова «таймер»
            if unit.isEmpty && !text.lowercased().contains("тайм") && !text.lowercased().contains("timer") { return nil }
            return n * 60
        }
        if seconds.contains(unit) { return n }
        if hours.contains(unit) { return n * 3600 }
        return nil
    }
}

// MARK: - Pomodoro: фокус → перерыв, каждый 4-й перерыв длинный

enum Phase {
    case focus, rest
    var title: String { self == .focus ? L("FOCUS") : L("BREAK") }
}

@MainActor
final class PomodoroModel: ObservableObject {
    static let shared = PomodoroModel()

    @Published private(set) var active = false          // режим Pomodoro включён
    @Published private(set) var phase: Phase = .focus
    @Published private(set) var isRunning = false
    @Published private(set) var completedFocus = 0
    @Published private(set) var now = Date()
    @Published private(set) var runChangedAt = Date.distantPast
    let phaseFinished = PassthroughSubject<Phase, Never>()

    private var endDate: Date?
    private var pausedRemaining: TimeInterval = 25 * 60
    private var ticker: Timer?
    private let settings = AppSettings.shared

    var isLongBreak: Bool { phase == .rest && completedFocus > 0 && completedFocus % 4 == 0 }

    var duration: TimeInterval {
        if ProcessInfo.processInfo.environment["POMO_FAST"] == "1" { return phase == .focus ? 20 : 10 }
        switch phase {
        case .focus: return TimeInterval(settings.focusMinutes * 60)
        case .rest: return TimeInterval((isLongBreak ? settings.longBreakMinutes : settings.breakMinutes) * 60)
        }
    }

    func remaining(at date: Date = Date()) -> TimeInterval {
        if let end = endDate { return max(0, end.timeIntervalSince(date)) }
        return pausedRemaining
    }

    func progress(at date: Date = Date()) -> Double {
        min(1, max(0, 1 - remaining(at: date) / max(duration, 1)))
    }

    func timeString(at date: Date? = nil) -> String { clock(remaining(at: date ?? now)) }

    var phaseTitle: String {
        phase == .focus ? L("Focus") : (isLongBreak ? L("Long break") : L("Break"))
    }

    // MARK: Управление

    /// Включить режим Pomodoro и сразу начать фокус.
    func begin() {
        active = true
        phase = .focus
        completedFocus = 0
        pausedRemaining = duration
        start()
    }

    func toggle() { isRunning ? pause() : start() }

    func start() {
        guard !isRunning else { return }
        active = true
        endDate = Date().addingTimeInterval(pausedRemaining)
        isRunning = true
        runChangedAt = Date()
        ensureTicker()
    }

    func pause() {
        guard isRunning else { return }
        pausedRemaining = remaining()
        endDate = nil
        isRunning = false
        runChangedAt = Date()
    }

    /// Выключить режим Pomodoro совсем.
    func stop() {
        endDate = nil
        isRunning = false
        active = false
        phase = .focus
        completedFocus = 0
        pausedRemaining = duration
        ticker?.invalidate(); ticker = nil
    }

    func skip() { advance(natural: false) }

    private func ensureTicker() {
        guard ticker == nil else { return }
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    private func tick() {
        now = Date()
        if let end = endDate, now >= end { advance(natural: true) }
    }

    private func advance(natural: Bool) {
        if phase == .focus && natural { completedFocus += 1 }
        phase = phase == .focus ? .rest : .focus
        pausedRemaining = duration
        if isRunning { endDate = Date().addingTimeInterval(pausedRemaining) }
        if natural {
            NSSound(named: NSSound.Name(phase == .rest ? "Glass" : "Hero"))?.play()
            phaseFinished.send(phase)
        }
    }

    func debugSet(phase: Phase, progress: Double, running: Bool, completed: Int) {
        active = true
        self.phase = phase
        completedFocus = completed
        pausedRemaining = duration * (1 - progress)
        isRunning = running
        endDate = running ? Date().addingTimeInterval(pausedRemaining) : nil
        runChangedAt = Date().addingTimeInterval(-10)
    }
}
