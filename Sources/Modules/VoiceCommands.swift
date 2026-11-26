import AVFoundation
import Combine
import Speech

/// Голосовые команды музыке и видео, слушаем в фоне, пока что-то играет или стоит на паузе.
/// «дальше» / «следующий трек», «назад» / «предыдущий трек», «пауза» (ставит и снимает),
/// «продолжи» / «включи музыку» (только снимает с паузы), «выключи музыку» (только ставит на паузу).
/// Распознавание — встроенное в macOS, полностью на этом Mac (без интернета).
/// Чтобы песни из колонок не переключали треки, команда срабатывает только если
/// фраза прозвучала отдельно: тишина до неё и тишина после.
@MainActor
final class VoiceCommands: ObservableObject {
    static let shared = VoiceCommands()

    enum Command { case next, previous, toggle, play, pause }
    enum Status: Equatable { case off, listening, denied, unavailable }

    @Published var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: "voiceCommands"); update() }
    }

    @Published private(set) var status: Status = .off
    /// Когда сработала последняя команда (для вспышки значка).
    @Published private(set) var lastFired: Date?
    let fired = PassthroughSubject<Command, Never>()

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: Locale.preferredLanguages.first ?? "en-US")) ?? SFSpeechRecognizer()
    private let engine = AVAudioEngine()
    private let feed = Feed()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var generation = 0
    private var taskStarted = Date()
    private var pendingText = ""
    private var lastChange = Date()
    private var ticker: Timer?
    private var bag = Set<AnyCancellable>()
    private var authorized = false
    private var asking = false

    private init() {
        enabled = UserDefaults.standard.object(forKey: "voiceCommands") as? Bool ?? true
    }

    /// Слушаем, только когда есть что переключать и пока не идёт голосовой вопрос.
    func setup() {
        NowPlaying.shared.$title.map { !$0.isEmpty }.removeDuplicates()
            .sink { [weak self] _ in DispatchQueue.main.async { MainActor.assumeIsolated { self?.update() } } }.store(in: &bag)
        Dictation.shared.$listening.removeDuplicates()
            .sink { [weak self] v in DispatchQueue.main.async { MainActor.assumeIsolated { self?.asking = v; self?.update() } } }.store(in: &bag)
        NotificationCenter.default.publisher(for: .AVAudioEngineConfigurationChange, object: engine)
            .sink { [weak self] _ in
                // Сменился микрофон (AirPods и т.п.) — перезапускаем
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.stopEngine(); self?.update() } }
            }.store(in: &bag)
    }

    private var shouldRun: Bool { enabled && NowPlaying.shared.hasTrack && !asking }

    private func update() {
        if shouldRun {
            if status != .listening { authorizeThenStart() }
        } else if status == .listening {
            stopEngine()
        } else if !enabled {
            status = .off
        }
    }

    private func authorizeThenStart() {
        guard let recognizer, recognizer.supportsOnDeviceRecognition else { status = .unavailable; return }
        if authorized { startEngine(); return }
        Self.requestAccess { [weak self] ok in
            guard let self else { return }
            guard !self.authorized || ok else { return }
            self.authorized = ok
            if !ok { self.status = .denied; return }
            if self.shouldRun { self.startEngine() }
        }
    }

    nonisolated private static func requestAccess(_ done: @escaping @MainActor (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { s in
            guard s == .authorized else { DispatchQueue.main.async { done(false) }; return }
            AVCaptureDevice.requestAccess(for: .audio) { ok in DispatchQueue.main.async { done(ok) } }
        }
    }

    // MARK: Микрофон

    private func startEngine() {
        guard status != .listening else { return }
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        Self.installTap(on: input, feed: feed)
        engine.prepare()
        do { try engine.start() } catch {
            input.removeTap(onBus: 0)
            status = .unavailable
            return
        }
        status = .listening
        startTask()
        let t = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    private func stopEngine() {
        ticker?.invalidate(); ticker = nil
        endTask()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        status = .off
    }

    nonisolated private static func installTap(on node: AVAudioInputNode, feed: Feed) {
        node.installTap(onBus: 0, bufferSize: 2048, format: node.outputFormat(forBus: 0)) { buf, _ in
            feed.append(buf)
        }
    }

    // MARK: Распознавание

    private func startTask() {
        guard let recognizer else { return }
        let r = SFSpeechAudioBufferRecognitionRequest()
        r.requiresOnDeviceRecognition = true
        r.shouldReportPartialResults = true
        r.taskHint = .search
        r.addsPunctuation = false
        r.contextualStrings = ["дальше", "назад", "пауза", "продолжи", "следующий трек", "предыдущий трек", "включи музыку", "выключи музыку",
                               "next", "back", "pause", "resume"]
        request = r
        feed.set(r)
        generation += 1
        let gen = generation
        pendingText = ""
        taskStarted = Date()
        task = Self.makeTask(recognizer, r) { [weak self] text, final, failed in
            self?.handle(gen: gen, text: text, final: final, failed: failed)
        }
    }

    private func endTask() {
        feed.set(nil)
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        generation += 1
    }

    private func restartTask() {
        endTask()
        if status == .listening { startTask() }
    }

    nonisolated private static func makeTask(_ rec: SFSpeechRecognizer, _ req: SFSpeechAudioBufferRecognitionRequest,
                                             _ cb: @escaping @MainActor (String?, Bool, Bool) -> Void) -> SFSpeechRecognitionTask {
        rec.recognitionTask(with: req) { result, error in
            let text = result?.bestTranscription.formattedString
            let final = result?.isFinal ?? false
            let failed = error != nil
            DispatchQueue.main.async { MainActor.assumeIsolated { cb(text, final, failed) } }
        }
    }

    private func handle(gen: Int, text: String?, final: Bool, failed: Bool) {
        guard gen == generation, status == .listening else { return }
        if let text, text != pendingText {
            pendingText = text
            lastChange = Date()
        }
        if final || failed {
            evaluate()
            // Ошибка «ничего не услышал» прилетает после тишины — просто начинаем заново
            DispatchQueue.main.asyncAfter(deadline: .now() + (failed ? 0.4 : 0)) { [weak self] in
                guard let self, gen == self.generation else { return }
                self.restartTask()
            }
        }
    }

    private func tick() {
        let now = Date()
        // Фраза закончилась (0.7 с без новых слов) — проверяем и начинаем слушать с чистого листа
        if !pendingText.isEmpty, now.timeIntervalSince(lastChange) > 0.7 {
            evaluate()
            restartTask()
        } else if now.timeIntervalSince(taskStarted) > 50 {
            restartTask()   // у системного распознавания лимит на длину одной сессии
        }
    }

    private func evaluate() {
        let text = pendingText
        pendingText = ""
        guard let cmd = Self.parse(text) else { return }
        perform(cmd)
    }

    private func perform(_ cmd: Command) {
        lastFired = Date()
        fired.send(cmd)
        let np = NowPlaying.shared
        switch cmd {
        case .next: np.next()
        case .previous: np.previous()
        case .toggle: np.toggle()
        case .play: if !np.playing { np.toggle() }
        case .pause: if np.playing { np.toggle() }
        }
    }

    /// Вся фраза целиком должна быть командой (слово «пожалуйста» не мешает).
    nonisolated static func parse(_ text: String) -> Command? {
        let words = text.lowercased().replacingOccurrences(of: "ё", with: "е")
            .components(separatedBy: CharacterSet.letters.inverted)
            .filter { !$0.isEmpty && !["пожалуйста", "please"].contains($0) }
        return phrases[words.joined(separator: " ")]
    }

    nonisolated private static let phrases: [String: Command] = {
        var m: [String: Command] = [:]
        for p in ["дальше", "следующий трек", "следующая песня", "следующее видео", "next", "next track", "skip"] { m[p] = .next }
        for p in ["назад", "предыдущий трек", "предыдущая песня", "предыдущее видео", "back", "previous", "previous track"] { m[p] = .previous }
        for p in ["пауза", "pause"] { m[p] = .toggle }
        for p in ["продолжи", "включи музыку", "resume", "play music"] { m[p] = .play }
        for p in ["выключи музыку", "stop music", "stop the music"] { m[p] = .pause }
        return m
    }()
}

/// Передаёт звук с микрофона в текущий запрос распознавания (из аудиопотока).
private final class Feed: @unchecked Sendable {
    private let lock = NSLock()
    private var req: SFSpeechAudioBufferRecognitionRequest?
    func set(_ r: SFSpeechAudioBufferRecognitionRequest?) { lock.lock(); req = r; lock.unlock() }
    func append(_ b: AVAudioPCMBuffer) { lock.lock(); let r = req; lock.unlock(); r?.append(b) }
}
