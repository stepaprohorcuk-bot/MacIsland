import AVFoundation
import Combine
import Speech

/// Голосовой ввод в строку «Спросить»: системное распознавание речи на языке системы.
/// Замолчал на ~1.5 с — текст уходит как вопрос.
@MainActor
final class Dictation: ObservableObject {
    static let shared = Dictation()

    @Published private(set) var listening = false
    @Published private(set) var level: Float = 0

    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var lastChange = Date()
    private var started = Date()
    private var text = ""
    private var ticker: Timer?
    private var onPartial: ((String) -> Void)?
    private var onFinal: ((String) -> Void)?

    func toggle(onPartial: @escaping (String) -> Void, onFinal: @escaping (String) -> Void) {
        if listening { finish(); return }
        self.onPartial = onPartial
        self.onFinal = onFinal
        Self.requestAccess { [weak self] ok in
            guard let self else { return }
            if ok { self.begin() } else { Assistant.shared.onToast?("mic.slash", L("Allow microphone and speech recognition in System Settings")) }
        }
    }

    nonisolated private static func requestAccess(_ done: @escaping @MainActor (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { s in
            guard s == .authorized else { DispatchQueue.main.async { MainActor.assumeIsolated { done(false) } }; return }
            AVCaptureDevice.requestAccess(for: .audio) { ok in DispatchQueue.main.async { MainActor.assumeIsolated { done(ok) } } }
        }
    }

    private func begin() {
        guard let rec = SFSpeechRecognizer(locale: Locale(identifier: Locale.preferredLanguages.first ?? "en-US"))
                ?? SFSpeechRecognizer(), rec.isAvailable else { return }
        let r = SFSpeechAudioBufferRecognitionRequest()
        r.shouldReportPartialResults = true
        r.requiresOnDeviceRecognition = rec.supportsOnDeviceRecognition
        r.addsPunctuation = true
        request = r
        text = ""
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        Self.installTap(on: input, request: r) { [weak self] lvl in self?.level = lvl }
        engine.prepare()
        do { try engine.start() } catch { input.removeTap(onBus: 0); return }
        listening = true
        started = Date()
        lastChange = Date()
        task = Self.makeTask(rec, r) { [weak self] t, final in
            guard let self, self.listening else { return }
            if let t, t != self.text { self.text = t; self.lastChange = Date(); self.onPartial?(t) }
            if final { self.finish() }
        }
        let tk = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        RunLoop.main.add(tk, forMode: .common)
        ticker = tk
    }

    private func tick() {
        let now = Date()
        let quiet = now.timeIntervalSince(lastChange)
        if (!text.isEmpty && quiet > 1.5) || (text.isEmpty && quiet > 6) || now.timeIntervalSince(started) > 30 { finish() }
    }

    private func finish() {
        guard listening else { return }
        listening = false
        level = 0
        ticker?.invalidate(); ticker = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        request?.endAudio()
        task?.cancel()
        task = nil; request = nil
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { onFinal?(t) }
    }

    nonisolated private static func installTap(on node: AVAudioInputNode, request: SFSpeechAudioBufferRecognitionRequest,
                                               level: @escaping @MainActor (Float) -> Void) {
        node.installTap(onBus: 0, bufferSize: 2048, format: node.outputFormat(forBus: 0)) { buf, _ in
            request.append(buf)
            guard let ch = buf.floatChannelData?[0] else { return }
            var sum: Float = 0
            let n = Int(buf.frameLength)
            for i in 0..<n { sum += ch[i] * ch[i] }
            let rms = sqrt(sum / Float(max(n, 1)))
            let v = min(1, rms * 12)
            DispatchQueue.main.async { MainActor.assumeIsolated { level(v) } }
        }
    }

    nonisolated private static func makeTask(_ rec: SFSpeechRecognizer, _ req: SFSpeechAudioBufferRecognitionRequest,
                                             _ cb: @escaping @MainActor (String?, Bool) -> Void) -> SFSpeechRecognitionTask {
        rec.recognitionTask(with: req) { result, error in
            let t = result?.bestTranscription.formattedString
            let final = (result?.isFinal ?? false) || error != nil
            DispatchQueue.main.async { MainActor.assumeIsolated { cb(t, final) } }
        }
    }
}
