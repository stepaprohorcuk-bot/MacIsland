import AppKit
import AVFoundation
import Combine
import NaturalLanguage
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Строка «Спросить»: таймер («5 мин»), калькулятор («12*7») или вопрос нейросети.
/// Кто отвечает — решается для каждого вопроса:
///   Apple Intelligence, если она включена и знает язык вопроса (русский она пока не знает);
///   иначе — API пользователя из настроек (OpenRouter, OpenAI, Groq, локальная Ollama…).
@MainActor
final class Assistant: ObservableObject {
    static let shared = Assistant()

    enum Phase: Equatable { case idle, thinking, answering, done, failed(String), needsSetup }

    @Published var query = ""
    @Published private(set) var answer = ""
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var source = ""
    @Published var focused = false
    @Published private(set) var speaking = false
    let focusRequest = PassthroughSubject<Void, Never>()
    var onDismiss: (() -> Void)?
    /// Показать короткое уведомление в острове (например, «Таймер на 5 мин»).
    var onToast: ((String, String) -> Void)?

    private var task: Task<Void, Never>?
    private var asked = ""
    private let synth = AVSpeechSynthesizer()
    private let settings = AppSettings.shared

    var busy: Bool { phase == .thinking || phase == .answering }
    var panelVisible: Bool { phase != .idle }
    var hasCustomAPI: Bool { !settings.apiBase.isEmpty && (APIKey.load() != nil || isLocalAPI) }
    var isLocalAPI: Bool { settings.apiBase.contains("localhost") || settings.apiBase.contains("127.0.0.1") }

    func requestFocus() { focusRequest.send() }

    func submit() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }

        if let secs = Timers.parse(q) {
            Timers.shared.start(seconds: secs)
            query = ""
            clear()
            onToast?("timer", Lf("Timer for %@ started", clock(secs)))
            return
        }
        // «открой Telegram» или точное название программы — запускаем её
        if settings.quickLaunch {
            let found = AppIndex.shared.search(q)
            if let first = found.first, AppIndex.isOpenCommand(q) || first.name.lowercased() == q.lowercased() {
                AppIndex.shared.open(first)
                query = ""
                clear()
                onToast?("arrow.up.forward.app", Lf("Opening %@", first.name))
                onDismiss?()
                return
            }
        }
        if let v = Calculator.evaluate(q) {
            task?.cancel()
            asked = q
            source = L("Calculator")
            answer = "\(q) = **\(Calculator.format(v))**"
            phase = .done
            return
        }
        guard settings.showAssistant else { return }
        ask(q)
    }

    private func ask(_ q: String) {
        task?.cancel()
        synth.stopSpeaking(at: .immediate)
        asked = q
        answer = ""
        let useApple = AppleAI.canAnswer(q) && settings.aiMode != .custom
        if settings.aiMode == .apple && !useApple {
            phase = .failed(AppleAI.whyNot(q)); source = "Apple Intelligence"; return
        }
        if !useApple && !hasCustomAPI {
            phase = .needsSetup; source = ""; return
        }
        phase = .thinking
        source = useApple ? "Apple Intelligence" : settings.apiModel
        let base = settings.apiBase, model = settings.apiModel, key = APIKey.load() ?? "local"
        task = Task { [weak self] in
            do {
                let onText: @MainActor (String, Bool) -> Void = { t, replace in
                    guard let self else { return }
                    if replace { self.answer = t } else { self.answer += t }
                    if !self.answer.isEmpty { self.phase = .answering }
                }
                if useApple {
                    try await AppleAI.stream(q, onText: onText)
                } else {
                    try await OpenAICompatible.stream(q, base: base, model: model, key: key, onText: onText)
                }
                guard let self, !Task.isCancelled else { return }
                self.phase = self.answer.isEmpty ? .failed(L("Empty answer. Try rephrasing.")) : .done
            } catch is CancellationError {
            } catch let e as URLError where e.code == .cancelled {
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.phase = .failed(error.localizedDescription)
            }
        }
    }

    func cancel() {
        task?.cancel(); task = nil
        if busy { phase = answer.isEmpty ? .idle : .done }
    }

    func clear() {
        cancel()
        synth.stopSpeaking(at: .immediate)
        speaking = false
        answer = ""
        phase = .idle
    }

    /// Открыть тот же вопрос в браузере (ChatGPT) — работает без ключей.
    func askInBrowser() {
        let q = asked.isEmpty ? query : asked
        var c = URLComponents(string: "https://chatgpt.com/")!
        c.queryItems = [URLQueryItem(name: "q", value: q)]
        if let u = c.url { NSWorkspace.shared.open(u) }
        clear()
        onDismiss?()
    }

    func speak() {
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate); speaking = false; return }
        let plain = answer.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
        let u = AVSpeechUtterance(string: plain)
        let lang = NLLanguageRecognizer.dominantLanguage(for: plain)?.rawValue ?? "en"
        u.voice = AVSpeechSynthesisVoice(language: lang)
        synth.speak(u)
        speaking = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.pollSpeaking() }
    }

    private func pollSpeaking() {
        speaking = synth.isSpeaking
        if speaking { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.pollSpeaking() } }
    }

    func debugShow(query: String, answer: String, source: String) {
        self.query = query; self.answer = answer; self.source = source; phase = .done
    }
}

// MARK: - Apple Intelligence (на устройстве, бесплатно)

enum AppleAI {
    static let instructions = """
    You are a quick assistant built into the MacBook notch. Answer in the language of the question, \
    briefly: usually 1–4 sentences or a short list. No introductions, no headings. If you don't know, say so.
    """

    static func language(of text: String) -> String {
        NLLanguageRecognizer.dominantLanguage(for: text)?.rawValue ?? "en"
    }

    static func canAnswer(_ q: String) -> Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            let m = SystemLanguageModel.default
            guard case .available = m.availability else { return false }
            return m.supportsLocale(Locale(identifier: language(of: q)))
        }
        #endif
        return false
    }

    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            if case .available = SystemLanguageModel.default.availability { return true }
        }
        #endif
        return false
    }

    static func whyNot(_ q: String) -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return L("Apple Intelligence doesn't support this language yet. Add your own API in Settings.")
            case .unavailable(.appleIntelligenceNotEnabled):
                return L("Turn on Apple Intelligence in System Settings, or add your own API.")
            case .unavailable(.modelNotReady):
                return L("Apple Intelligence model is still downloading. Try again later.")
            default:
                return L("Apple Intelligence isn't available on this Mac.")
            }
        }
        #endif
        return L("Apple Intelligence requires macOS 26 or later.")
    }

    static func stream(_ q: String, onText: @escaping @MainActor (String, Bool) -> Void) async throws {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            let session = LanguageModelSession(instructions: instructions)
            for try await snap in session.streamResponse(to: q) {
                try Task.checkCancellation()
                await onText(snap.content, true)
            }
            return
        }
        #endif
        throw APIError(message: whyNot(q))
    }
}

// MARK: - Свой API (любой OpenAI-совместимый)

struct APIError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum OpenAICompatible {
    static func stream(_ q: String, base: String, model: String, key: String,
                       onText: @escaping @MainActor (String, Bool) -> Void) async throws {
        let trimmed = base.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard let url = URL(string: trimmed + "/chat/completions") else {
            throw APIError(message: L("Invalid API address. Check Settings."))
        }
        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        r.timeoutInterval = 90
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        r.setValue(AppInfo.name, forHTTPHeaderField: "X-Title")
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        r.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "stream": true,
            "messages": [
                ["role": "system", "content": AppleAI.instructions + " Today is \(df.string(from: Date()))."],
                ["role": "user", "content": q],
            ],
        ] as [String: Any])

        let (bytes, resp) = try await URLSession.shared.bytes(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            var raw = Data()
            for try await b in bytes { raw.append(b); if raw.count > 20_000 { break } }
            throw error(code: code, body: raw)
        }
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if let err = obj["error"] as? [String: Any] {
                throw APIError(message: err["message"] as? String ?? L("The model stopped with an error."))
            }
            let delta = ((obj["choices"] as? [[String: Any]])?.first?["delta"]) as? [String: Any]
            if let t = delta?["content"] as? String, !t.isEmpty { await onText(t, false) }
        }
    }

    static func error(code: Int, body: Data) -> APIError {
        let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        let msg = (obj?["error"] as? [String: Any])?["message"] as? String
            ?? String(data: body.prefix(300), encoding: .utf8) ?? ""
        switch code {
        case 401, 403: return APIError(message: L("The API key was rejected. Check it in Settings."))
        case 402: return APIError(message: L("Out of credits on your API account."))
        case 404: return APIError(message: L("Model or address not found. Check Settings.") + " \(msg)")
        case 429: return APIError(message: L("Rate limit reached. Wait a little."))
        default: return APIError(message: "HTTP \(code): \(msg)")
        }
    }
}

// MARK: - Калькулятор (свой разбор, без NSExpression — тот падает на кривом вводе)

enum Calculator {
    static func evaluate(_ text: String) -> Double? {
        let s = text.replacingOccurrences(of: "×", with: "*").replacingOccurrences(of: "÷", with: "/")
            .replacingOccurrences(of: ",", with: ".").replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "=", with: "")
        guard !s.isEmpty, s.allSatisfy({ "0123456789.+-*/()^%".contains($0) }),
              s.contains(where: { "+-*/^%".contains($0) }), s.contains(where: \.isNumber) else { return nil }
        var p = Parser(chars: Array(s))
        guard let v = p.expr(), p.i == p.chars.count, v.isFinite else { return nil }
        return v
    }

    static func format(_ v: Double) -> String {
        let f = NumberFormatter()
        f.maximumFractionDigits = 8
        f.minimumFractionDigits = 0
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: v)) ?? "\(v)"
    }

    private struct Parser {
        let chars: [Character]
        var i = 0
        mutating func peek() -> Character? { i < chars.count ? chars[i] : nil }
        mutating func expr() -> Double? {
            guard var v = term() else { return nil }
            while let c = peek(), c == "+" || c == "-" {
                i += 1
                guard let r = term() else { return nil }
                v = c == "+" ? v + r : v - r
            }
            return v
        }
        mutating func term() -> Double? {
            guard var v = power() else { return nil }
            while let c = peek(), c == "*" || c == "/" || c == "%" {
                i += 1
                if c == "%" && (peek() == nil || "+-*/)".contains(peek()!)) { v /= 100; continue }
                guard let r = power() else { return nil }
                v = c == "*" ? v * r : (c == "/" ? v / r : v.truncatingRemainder(dividingBy: r))
            }
            return v
        }
        mutating func power() -> Double? {
            guard let b = unary() else { return nil }
            if peek() == "^" { i += 1; guard let e = power() else { return nil }; return pow(b, e) }
            return b
        }
        mutating func unary() -> Double? {
            if peek() == "-" { i += 1; return unary().map { -$0 } }
            if peek() == "+" { i += 1; return unary() }
            return atom()
        }
        mutating func atom() -> Double? {
            if peek() == "(" {
                i += 1
                guard let v = expr(), peek() == ")" else { return nil }
                i += 1
                return v
            }
            let start = i
            while let c = peek(), c.isNumber || c == "." { i += 1 }
            return i > start ? Double(String(chars[start..<i])) : nil
        }
    }
}
