import AppKit
import ApplicationServices
import Combine

/// Уведомления других программ (Telegram, Почта…). Официального способа их читать в macOS нет,
/// поэтому смотрим на системные баннеры через «Универсальный доступ» (Accessibility):
/// раз в секунду, только пока функция включена и разрешение дано. Может сломаться с обновлениями macOS.
@MainActor
final class NotificationWatcher: ObservableObject {
    static let shared = NotificationWatcher()

    struct Note: Identifiable, Equatable {
        let id = UUID()
        let appName: String?
        let bundleURL: URL?
        let title: String
        let body: String
        let date = Date()
        var icon: NSImage? { bundleURL.map { NSWorkspace.shared.icon(forFile: $0.path) } }
    }

    @Published private(set) var trusted = AXIsProcessTrusted()
    @Published private(set) var recent: [Note] = []
    let posted = PassthroughSubject<Note, Never>()

    private var timer: Timer?
    private var trustTimer: Timer?
    private var seen: [String: Date] = [:]
    private var bag = Set<AnyCancellable>()

    func start() {
        AppSettings.shared.$notificationsEnabled.removeDuplicates()
            .sink { [weak self] _ in DispatchQueue.main.async { MainActor.assumeIsolated { self?.update() } } }
            .store(in: &bag)
        // Разрешение могут дать в «Системных настройках» в любой момент — проверяем раз в 3 с, пока его нет
        let t = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, AppSettings.shared.notificationsEnabled, !self.trusted else { return }
                if AXIsProcessTrusted() { self.update() }
            }
        }
        RunLoop.main.add(t, forMode: .common)
    }

    /// Показать системный запрос и ждать, пока пользователь включит MacIsland в «Универсальном доступе».
    func requestAccess() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        trusted = AXIsProcessTrustedWithOptions(opts)
        trustTimer?.invalidate()
        var tries = 0
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self else { t.invalidate(); return }
                tries += 1
                self.trusted = AXIsProcessTrusted()
                if self.trusted || tries > 90 { t.invalidate(); self.update() }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        trustTimer = t
    }

    func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    // MARK: Диагностика (локальный лог, чтобы понять, что macOS показывает в баннерах)

    static let logURL: URL = {
        let d = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/MacIsland", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d.appendingPathComponent("notifications.log")
    }()
    private var lastTreeSig = ""
    private var promptedThisLaunch = false

    func log(_ line: String) {
        NSLog("MacIsland.notif %@", line)
        let text = "\(Date().formatted(date: .omitted, time: .standard)) \(line)\n"
        if let h = try? FileHandle(forWritingTo: Self.logURL) {
            h.seekToEndOfFile(); h.write(Data(text.utf8)); try? h.close()
        } else {
            try? Data(text.utf8).write(to: Self.logURL)
        }
    }

    private func update() {
        trusted = AXIsProcessTrusted()
        log("update: enabled=\(AppSettings.shared.notificationsEnabled) trusted=\(trusted)")
        if AppSettings.shared.notificationsEnabled && !trusted && !promptedThisLaunch {
            promptedThisLaunch = true
            requestAccess()            // системный запрос + MacIsland появится в списке «Универсального доступа»
        }
        let run = AppSettings.shared.notificationsEnabled && trusted
        if run && timer == nil {
            let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        } else if !run {
            timer?.invalidate(); timer = nil
        }
    }

    func dismiss(_ n: Note) { recent.removeAll { $0.id == n.id } }
    func clearAll() { recent.removeAll() }

    func debugAdd(app: String, title: String, body: String) {
        recent.insert(Note(appName: app, bundleURL: nil, title: title, body: body), at: 0)
    }

    func open(_ n: Note) {
        if let u = n.bundleURL { NSWorkspace.shared.openApplication(at: u, configuration: .init()) }
        dismiss(n)
    }

    // MARK: Чтение баннеров

    private var idleTicks = 0
    private var ncActive = false

    /// Пока баннера нет — смотрим раз в секунду; когда окно уведомлений есть — 4 раза в секунду.
    private func tick() {
        idleTicks += 1
        if ncActive || idleTicks >= 4 { idleTicks = 0; scan() }
    }

    private func scan() {
        guard let nc = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.notificationcenterui").first
        else { return }
        let app = AXUIElementCreateApplication(nc.processIdentifier)
        var banners: [AXUIElement] = []
        let windows = Self.children(app, kAXWindowsAttribute)
        ncActive = !windows.isEmpty
        for w in windows { Self.findBanners(w, depth: 0, into: &banners) }

        // Диагностика (тексты уведомлений пишутся в лог только если включить MACISLAND_NOTIF_DEBUG=1)
        if ProcessInfo.processInfo.environment["MACISLAND_NOTIF_DEBUG"] == "1" {
            var tree: [String] = []
            for w in windows { Self.dump(w, depth: 0, into: &tree) }
            let sig = tree.joined(separator: "\n")
            if sig != lastTreeSig { lastTreeSig = sig; log("NC windows=\(windows.count) banners=\(banners.count)\n" + sig) }
        }

        let now = Date()
        for b in banners {
            var texts: [String] = []
            Self.collectTexts(b, depth: 0, into: &texts)
            let desc = Self.string(b, kAXDescriptionAttribute) ?? ""
            if texts.isEmpty && !desc.isEmpty { texts = desc.components(separatedBy: ", ") }
            guard !texts.isEmpty else { continue }
            let key = texts.joined(separator: "|")
            if seen[key] == nil { post(texts: texts, description: desc) }
            seen[key] = now
        }
        seen = seen.filter { now.timeIntervalSince($0.value) < 120 }
    }

    private func post(texts: [String], description: String) {
        // Определяем программу: её название обычно стоит первым в описании или в текстах баннера
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        let hay = ([description] + texts).joined(separator: " ")
        let app = apps.first { a in
            guard let n = a.localizedName, n.count > 1 else { return false }
            return description.hasPrefix(n) || texts.first == n || hay.contains(n + ",")
        }
        var t = texts
        if let n = app?.localizedName, t.first == n { t.removeFirst() }
        let descApp = description.components(separatedBy: ", ").first.flatMap { d -> String? in
            d.isEmpty || d == texts.first ? nil : d
        }
        let appName = app?.localizedName ?? descApp
        let appURL = app?.bundleURL ?? descApp.flatMap { NSWorkspace.shared.fullPath(forApplication: $0) }.map { URL(fileURLWithPath: $0) }
        guard let title = t.first else { return }
        let body = t.dropFirst().joined(separator: " ")
        let note = Note(appName: appName, bundleURL: appURL, title: title, body: body)
        log("posted: app=\(note.appName ?? "?")")
        recent.insert(note, at: 0)
        if recent.count > 30 { recent.removeLast(recent.count - 30) }
        posted.send(note)
    }

    // MARK: Помощники Accessibility

    nonisolated private static func value(_ e: AXUIElement, _ attr: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(e, attr as CFString, &v) == .success ? v : nil
    }
    nonisolated private static func string(_ e: AXUIElement, _ attr: String) -> String? { value(e, attr) as? String }
    nonisolated private static func children(_ e: AXUIElement, _ attr: String = kAXChildrenAttribute) -> [AXUIElement] {
        (value(e, attr) as? [AXUIElement]) ?? []
    }

    nonisolated private static func dump(_ e: AXUIElement, depth: Int, into out: inout [String]) {
        guard depth < 14, out.count < 120 else { return }
        let role = string(e, kAXRoleAttribute) ?? "?"
        let sub = string(e, kAXSubroleAttribute) ?? ""
        let desc = (string(e, kAXDescriptionAttribute) ?? "").prefix(80)
        let val = (string(e, kAXValueAttribute) ?? "").prefix(80)
        out.append(String(repeating: "  ", count: depth) + "\(role) [\(sub)] d=\"\(desc)\" v=\"\(val)\"")
        for c in children(e) { dump(c, depth: depth + 1, into: &out) }
    }

    nonisolated private static func findBanners(_ e: AXUIElement, depth: Int, into out: inout [AXUIElement]) {
        guard depth < 10 else { return }
        let sub = string(e, kAXSubroleAttribute) ?? ""
        if sub.hasPrefix("AXNotificationCenterBanner") || sub.hasPrefix("AXNotificationCenterAlert") {
            out.append(e)
            return
        }
        for c in children(e) { findBanners(c, depth: depth + 1, into: &out) }
    }

    nonisolated private static func collectTexts(_ e: AXUIElement, depth: Int, into out: inout [String]) {
        guard depth < 14, out.count < 8 else { return }
        if string(e, kAXRoleAttribute) == kAXStaticTextRole as String,
           let v = string(e, kAXValueAttribute)?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty {
            out.append(v)
        }
        for c in children(e) { collectTexts(c, depth: depth + 1, into: &out) }
    }
}
