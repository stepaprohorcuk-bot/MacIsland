import AppKit
import NaturalLanguage
import SwiftUI
#if canImport(Translation)
import Translation
#endif

/// Перевод через встроенный переводчик macOS (macOS 15+): бесплатно, языки скачиваются один раз
/// и дальше работают без интернета. На macOS 14 — открываем Google Переводчик в браузере.
///
/// Если языки уже скачаны — переводим прямо в острове. Если нет — открываем обычное окно,
/// в котором macOS спрашивает про загрузку (в острове это окно не держится: остров сворачивается).
@MainActor
final class Translator: ObservableObject {
    static let shared = Translator()

    enum Place { case island, setup }

    @Published private(set) var results: [UUID: String] = [:]
    @Published private(set) var busy: Set<UUID> = []
    @Published private(set) var errors: [UUID: String] = [:]

    /// Для снимков README: готовый перевод элемента буфера.
    func debugSet(result: String, for id: UUID) { results[id] = result }
    /// TranslationSession.Configuration (хранится как Any, чтобы класс собирался и на macOS 14).
    @Published fileprivate(set) var islandConfig: Any?
    @Published fileprivate(set) var setupConfig: Any?
    @Published fileprivate(set) var setupLanguages = ""

    private var pending: [Place: [(id: UUID, text: String)]] = [:]
    private var setupWindow: NSWindow?

    var translatingInIsland: Bool { !(pending[.island] ?? []).isEmpty }

    static var isAvailable: Bool {
        if #available(macOS 15, *) { return true }
        return false
    }

    static let languages: [(code: String, name: String)] = [
        ("en", "English"), ("ru", "Русский"), ("uk", "Українська"), ("de", "Deutsch"), ("fr", "Français"),
        ("es", "Español"), ("it", "Italiano"), ("pt", "Português"), ("tr", "Türkçe"), ("zh", "中文"),
        ("ja", "日本語"), ("ko", "한국어"), ("ar", "العربية"), ("pl", "Polski"), ("nl", "Nederlands"),
    ]

    static func source(of text: String) -> String {
        NLLanguageRecognizer.dominantLanguage(for: text)?.rawValue ?? "en"
    }

    /// Куда переводим: язык из настроек; «авто» — на язык системы, а текст на языке системы — на английский.
    func target(for text: String) -> String {
        let setting = AppSettings.shared.translateTarget
        if setting != "auto" { return setting }
        let system = Locale.preferredLanguages.first.map { String($0.prefix(2)) } ?? "en"
        let src = String(Self.source(of: text).prefix(2))
        return src == system ? (system == "en" ? "ru" : "en") : system
    }

    func translate(id: UUID, text: String) {
        if results[id] != nil { results[id] = nil; return }     // повторное нажатие — скрыть перевод
        guard !busy.contains(id) else { return }
        let src = Self.source(of: text), tgt = target(for: text)
        guard Self.isAvailable else {
            var c = URLComponents(string: "https://translate.google.com/")!
            c.queryItems = [.init(name: "sl", value: "auto"), .init(name: "tl", value: tgt), .init(name: "text", value: text)]
            if let u = c.url { NSWorkspace.shared.open(u) }
            return
        }
        errors[id] = nil
        busy.insert(id)
        #if canImport(Translation)
        if #available(macOS 15, *) {
            let job = (id: id, text: String(text.prefix(5000)))
            Task {
                let s = Locale.Language(identifier: src), t = Locale.Language(identifier: tgt)
                let status = await LanguageAvailability().status(from: s, to: t)
                switch status {
                case .installed:
                    pending[.island, default: []].append(job)
                    islandConfig = Self.config(old: islandConfig, s, t)
                    // Страховка: если перевод не пришёл за 30 с — не крутим кружок вечно
                    DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in self?.timeout(id) }
                case .supported:
                    pending[.setup, default: []].append(job)
                    openSetupWindow(s, t)
                    setupConfig = Self.config(old: setupConfig, s, t)
                case .unsupported:
                    fail(id, L("This language pair isn't supported by the macOS translator."))
                @unknown default:
                    fail(id, L("Couldn't translate. The language pair may not be supported."))
                }
            }
        }
        #endif
    }

    private func fail(_ id: UUID, _ msg: String) {
        busy.remove(id)
        errors[id] = msg
    }

    private func timeout(_ id: UUID) {
        guard busy.contains(id), (pending[.island] ?? []).contains(where: { $0.id == id }) else { return }
        pending[.island]?.removeAll { $0.id == id }
        fail(id, L("Translation took too long. Try again."))
    }

    /// Остров свернулся посреди перевода — снимаем «крутилку».
    func islandHostGone() {
        for job in pending[.island] ?? [] { busy.remove(job.id) }
        pending[.island] = []
    }

    #if canImport(Translation)
    @available(macOS 15, *)
    private static func config(old: Any?, _ s: Locale.Language, _ t: Locale.Language) -> TranslationSession.Configuration {
        if var c = old as? TranslationSession.Configuration, c.source == s, c.target == t {
            c.invalidate()                     // та же пара языков — просто перезапускаем
            return c
        }
        return TranslationSession.Configuration(source: s, target: t)
    }

    @available(macOS 15, *)
    fileprivate func run(_ session: TranslationSession, place: Place) async {
        while let job = pending[place]?.first {
            pending[place]?.removeFirst()
            do {
                let r = try await session.translate(job.text)
                results[job.id] = r.targetText
                busy.remove(job.id)
            } catch {
                fail(job.id, place == .setup ? L("Languages weren't downloaded, so the text wasn't translated.")
                                              : L("Couldn't translate. The language pair may not be supported."))
            }
        }
        if place == .setup { closeSetupWindow() }
    }
    #endif

    // MARK: Окно загрузки языков

    private func openSetupWindow(_ s: Locale.Language, _ t: Locale.Language) {
        let name: (Locale.Language) -> String = { l in
            Locale.current.localizedString(forLanguageCode: l.languageCode?.identifier ?? "")?.capitalized ?? l.minimalIdentifier
        }
        setupLanguages = "\(name(s)) → \(name(t))"
        if setupWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 230),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = L("Translation languages")
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: TranslationSetupView())
            w.center()
            setupWindow = w
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        setupWindow?.makeKeyAndOrderFront(nil)
    }

    func cancelSetup() {
        for job in pending[.setup] ?? [] { busy.remove(job.id) }
        pending[.setup] = []
        closeSetupWindow()
    }

    private func closeSetupWindow() {
        setupWindow?.orderOut(nil)
        setupConfig = nil
        NSApp.setActivationPolicy(.accessory)
    }
}

/// Невидимый вид, через который работает системный переводчик.
struct TranslationHost: View {
    var place: Translator.Place = .island
    @ObservedObject var translator = Translator.shared

    var body: some View {
        #if canImport(Translation)
        if #available(macOS 15, *) {
            Color.clear.frame(width: 1, height: 1)
                .translationTask((place == .island ? translator.islandConfig : translator.setupConfig)
                                 as? TranslationSession.Configuration) { session in
                    await translator.run(session, place: place)
                }
                .onDisappear { if place == .island { translator.islandHostGone() } }
        }
        #endif
    }
}

/// Окно, в котором macOS предлагает скачать языки для перевода.
struct TranslationSetupView: View {
    @ObservedObject var translator = Translator.shared

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "character.bubble.fill")
                .font(.system(size: 34)).foregroundStyle(.blue)
            Text("Download languages for translation")
                .font(.headline)
            Text(translator.setupLanguages).foregroundStyle(.secondary)
            Text("macOS will ask to download these languages once. After that, translation works offline.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                ProgressView().controlSize(.small)
                Spacer()
                Button("Cancel") { translator.cancelSetup() }
            }
            TranslationHost(place: .setup)
        }
        .padding(22)
        .frame(width: 440)
    }
}
