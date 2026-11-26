import AppKit
import Combine
import SwiftUI

/// Что сейчас играет (Яндекс Музыка или любой другой плеер) и управление им.
/// Данные приходят от мостика MacIslandNowPlaying.dylib, запущенного внутри /usr/bin/perl.
@MainActor
final class NowPlaying: ObservableObject {
    static let shared = NowPlaying()

    @Published private(set) var title = ""
    @Published private(set) var artist = ""
    @Published private(set) var playing = false
    @Published private(set) var artwork: NSImage?
    @Published private(set) var duration: Double = 0
    @Published private(set) var appName = ""
    @Published private(set) var appIcon: NSImage?
    /// Все плееры сразу (музыка, видео в браузере…) — для раздельной карточки.
    @Published private(set) var players: [Player] = []
    /// Свайп/переключение: −1 — назад, +1 — вперёд (для анимации обложки).
    let skips = PassthroughSubject<Int, Never>()

    private var elapsed: Double = 0
    private var stamp = Date()
    private var rate: Double = 0
    private var pid: Int32 = 0

    private var proc: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var restartDelay: TimeInterval = 2

    var hasTrack: Bool { !title.isEmpty }
    /// Плеер, который показан в свёрнутом острове (ему же уходят общие команды).
    var currentPid: Int32 { pid }

    func position(at now: Date) -> Double {
        let p = elapsed + (playing ? now.timeIntervalSince(stamp) * max(rate, 1) : 0)
        return duration > 0 ? min(max(p, 0), duration) : max(p, 0)
    }

    // MARK: Управление

    func toggle() {
        let now = Date()
        elapsed = position(at: now); stamp = now
        playing.toggle()                    // сразу, не дожидаясь ответа плеера
        send("toggle")
    }

    func next() { skips.send(1); send("next") }
    func previous() { skips.send(-1); send("prev") }

    /// Управление конкретным плеером из раздельной карточки.
    func toggle(_ p: Player) {
        if let i = players.firstIndex(where: { $0.id == p.id }) {
            let now = Date()
            players[i].elapsed = players[i].position(at: now); players[i].stamp = now
            players[i].playing.toggle()
        }
        if p.id == pid { let now = Date(); elapsed = position(at: now); stamp = now; playing.toggle() }
        send("toggle \(p.id)")
    }
    func next(_ p: Player) { if p.id == pid { skips.send(1) }; send("next \(p.id)") }
    func previous(_ p: Player) { if p.id == pid { skips.send(-1) }; send("prev \(p.id)") }

    private func send(_ cmd: String) {
        guard let input else { return }
        try? input.write(contentsOf: Data((cmd + "\n").utf8))
    }

    // MARK: Мостик

    func start() {
        guard proc == nil,
              let lib = Bundle.main.url(forResource: "MacIslandNowPlaying", withExtension: "dylib") else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = ["-e", """
            use DynaLoader;
            my $h = DynaLoader::dl_load_file($ARGV[0], 0) or die DynaLoader::dl_error();
            my $s = DynaLoader::dl_find_symbol($h, "island_run") or die "no island_run";
            my $f = DynaLoader::dl_install_xsub("main::island_run", $s);
            &$f;
            """, lib.path]
        let out = Pipe(), inp = Pipe()
        p.standardOutput = out
        p.standardInput = inp
        p.standardError = FileHandle.nullDevice

        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty else { h.readabilityHandler = nil; return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.consume(d) } }
        }
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.died() } }
        }
        do {
            try p.run()
            proc = p
            input = inp.fileHandleForWriting
        } catch {
            died()
        }
    }

    private func died() {
        proc = nil
        input = nil
        buffer.removeAll()
        clear()
        // Перезапуск с нарастающей паузой, чтобы не крутиться впустую, если мостик не работает
        let d = restartDelay
        restartDelay = min(restartDelay * 2, 120)
        DispatchQueue.main.asyncAfter(deadline: .now() + d) { [weak self] in self?.start() }
    }

    private func consume(_ d: Data) {
        buffer.append(d)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            if let o = try? JSONSerialization.jsonObject(with: line) as? [String: Any] { apply(o) }
        }
    }

    private func apply(_ o: [String: Any]) {
        guard o["error"] == nil else { return }
        if let cmd = o["direct"] as? String {
            DirectControl.send(cmd, pid: Int32(o["pid"] as? Int ?? 0), bundle: o["bid"] as? String ?? "")
            return
        }
        restartDelay = 2
        if let list = o["players"] as? [[String: Any]] { applyPlayers(list); return }
        let newPid = Int32(o["pid"] as? Int ?? 0)
        if newPid != pid {
            pid = newPid
            let app = NSRunningApplication(processIdentifier: newPid)
            appName = app?.localizedName ?? ""
            appIcon = app?.icon
        }
        title = o["title"] as? String ?? ""
        artist = o["artist"] as? String ?? ""
        rate = o["rate"] as? Double ?? 0
        playing = rate > 0
        duration = o["dur"] as? Double ?? 0
        elapsed = o["el"] as? Double ?? 0
        stamp = Date(timeIntervalSince1970: o["ts"] as? Double ?? Date().timeIntervalSince1970)
        if let a = o["art"] as? String {
            artwork = a.isEmpty ? nil : Data(base64Encoded: a).flatMap(NSImage.init(data:))
        }
        if title.isEmpty { clear() }
    }

    private var iconCache: [Int32: (name: String, icon: NSImage?)] = [:]

    private func applyPlayers(_ list: [[String: Any]]) {
        var next: [Player] = []
        for o in list {
            let id = Int32(o["pid"] as? Int ?? 0)
            let old = players.first { $0.id == id }
            if iconCache[id] == nil {
                let app = NSRunningApplication(processIdentifier: id)
                iconCache[id] = (app?.localizedName ?? "", app?.icon)
            }
            var p = Player(id: id, bundle: o["bid"] as? String ?? "", appName: iconCache[id]?.name ?? "",
                           appIcon: iconCache[id]?.icon, isVideo: o["video"] as? Bool ?? false,
                           title: o["title"] as? String ?? "", artist: o["artist"] as? String ?? "",
                           playing: (o["rate"] as? Double ?? 0) > 0, rate: o["rate"] as? Double ?? 0,
                           duration: o["dur"] as? Double ?? 0, elapsed: o["el"] as? Double ?? 0,
                           stamp: Date(timeIntervalSince1970: o["ts"] as? Double ?? Date().timeIntervalSince1970),
                           artwork: old?.artwork)
            if let a = o["art"] as? String { p.artwork = a.isEmpty ? nil : Data(base64Encoded: a).flatMap(NSImage.init(data:)) }
            next.append(p)
        }
        players = next
    }

    private func clear() {
        title = ""; artist = ""; playing = false; artwork = nil; duration = 0
    }

    func debugSet(title: String, artist: String, playing: Bool, position: Double, duration: Double) {
        self.title = title; self.artist = artist; self.playing = playing
        self.duration = duration; elapsed = position; stamp = Date(); rate = playing ? 1 : 0
        appName = "Music"
    }

    func debugSetArtwork(_ img: NSImage?) { artwork = img }

    func debugSetPlayers(_ ps: [Player]) { players = ps; if let p = ps.last { pid = p.id } }
}

/// Один плеер (программа), о котором знает macOS.
struct Player: Identifiable, Equatable {
    let id: Int32                 // pid
    var bundle: String
    var appName: String
    var appIcon: NSImage?
    var isVideo: Bool             // браузер или видеоплеер
    var title: String
    var artist: String
    var playing: Bool
    var rate: Double
    var duration: Double
    var elapsed: Double
    var stamp: Date
    var artwork: NSImage?

    func position(at now: Date) -> Double {
        let p = elapsed + (playing ? now.timeIntervalSince(stamp) * max(rate, 1) : 0)
        return duration > 0 ? min(max(p, 0), duration) : max(p, 0)
    }
}

/// Команда плееру в обход системы. macOS отдаёт системные команды только «главному» плееру —
/// тому, кто последним начал играть (часто это ролик в браузере). Если остров показывает
/// другой плеер (музыку), команду передаём ему напрямую.
@MainActor
enum DirectControl {
    static func send(_ cmd: String, pid: pid_t, bundle: String) {
        switch bundle {
        case "ru.yandex.desktop.music":
            // Горячие клавиши Яндекс Музыки: K — играть/пауза, N — следующий, P — предыдущий.
            // Клавиша уходит прямо программе, её окно не выходит вперёд.
            let key: CGKeyCode = cmd == "next" ? 45 : cmd == "prev" ? 35 : 40
            postKey(key, to: pid)
        case "com.spotify.client", "com.apple.Music":
            let app = bundle == "com.spotify.client" ? "Spotify" : "Music"
            let verb = cmd == "next" ? "next track" : cmd == "prev" ? "previous track" : "playpause"
            var err: NSDictionary?
            NSAppleScript(source: "tell application \"\(app)\" to \(verb)")?.executeAndReturnError(&err)
            if let err { NotificationWatcher.shared.log("direct \(bundle) \(cmd): \(err)") }
        case _ where browsers.contains(where: { bundle.hasPrefix($0) }):
            // Видео в браузере — горячие клавиши YouTube и большинства видеосайтов:
            // K — играть/пауза, Shift+N — следующее, Shift+P — предыдущее.
            switch cmd {
            case "next": postKey(45, shift: true, to: pid)
            case "prev": postKey(35, shift: true, to: pid)
            default: postKey(40, to: pid)
            }
        default:
            NotificationWatcher.shared.log("direct: не умею управлять \(bundle) в обход системы")
        }
    }

    private static let browsers = ["com.google.Chrome", "com.apple.Safari", "ru.yandex.desktop.yandex-browser",
                                   "company.thebrowser.", "com.microsoft.edgemac", "org.mozilla.", "com.operasoftware.",
                                   "com.brave.Browser", "com.vivaldi.", "org.chromium.", "app.zen-browser."]

    private static func postKey(_ key: CGKeyCode, shift: Bool = false, to pid: pid_t) {
        let src = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: false)
        if shift { down?.flags = .maskShift; up?.flags = .maskShift }
        down?.postToPid(pid)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { up?.postToPid(pid) }
    }
}
