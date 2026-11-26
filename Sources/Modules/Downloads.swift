import AppKit
import Combine

/// Загрузки в папку «Загрузки»: имя, процент, скорость, сколько осталось.
/// Единого системного прогресса загрузок нет, поэтому смотрим на незаконченные файлы браузеров:
///   Safari — папка *.download (в её Info.plist есть «скачано / всего»),
///   Chrome, Яндекс Браузер, Edge, Arc — *.crdownload (размер известен только скачанный),
///   Firefox — *.part.
@MainActor
final class DownloadsWatcher: ObservableObject {
    static let shared = DownloadsWatcher()

    struct Item: Identifiable, Equatable {
        let id: String                 // путь к незаконченному файлу
        var name: String
        var received: Double
        var total: Double?             // nil — браузер не говорит общий размер
        var speed: Double = 0          // байт/с
        var finished = false
        var finalURL: URL?
        var fraction: Double? { total.flatMap { $0 > 0 ? min(1, received / $0) : nil } }
        var eta: Double? {
            guard let t = total, speed > 1 else { return nil }
            return max(0, (t - received) / speed)
        }
    }

    @Published private(set) var items: [Item] = []
    let finishedEvent = PassthroughSubject<Item, Never>()

    private var source: DispatchSourceFileSystemObject?
    private var timer: Timer?
    private var lastSample: [String: (bytes: Double, at: Date)] = [:]
    private var bag = Set<AnyCancellable>()

    static var folder: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true) }

    func start() {
        AppSettings.shared.$showDownloads.removeDuplicates()
            .sink { [weak self] on in DispatchQueue.main.async { MainActor.assumeIsolated { self?.watch(on) } } }
            .store(in: &bag)
    }

    private func watch(_ on: Bool) {
        source?.cancel(); source = nil
        timer?.invalidate(); timer = nil
        items.removeAll()
        guard on else { return }
        let dir = Self.folder
        // Первое обращение к «Загрузкам» вызывает системный запрос доступа — делаем это в фоне
        DispatchQueue.global(qos: .utility).async { [weak self] in
            _ = try? FileManager.default.contentsOfDirectory(atPath: dir.path)
            let fd = Darwin.open(dir.path, O_EVTONLY)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, fd >= 0 else { return }
                    let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
                    src.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.scan() } }
                    src.setCancelHandler { close(fd) }
                    src.resume()
                    self.source = src
                    self.scan()
                }
            }
        }
    }

    private func ensureTimer() {
        let active = items.contains { !$0.finished }
        if active && timer == nil {
            let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.scan() } }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        } else if !active {
            timer?.invalidate(); timer = nil
        }
    }

    private func scan() {
        let dir = Self.folder
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            var found: [(path: String, name: String, received: Double, total: Double?)] = []
            for n in names {
                let url = dir.appendingPathComponent(n)
                let ext = url.pathExtension.lowercased()
                if ext == "download" {
                    // Safari: внутри папки — Info.plist с прогрессом
                    let plist = url.appendingPathComponent("Info.plist")
                    let d = NSDictionary(contentsOf: plist)
                    let got = (d?["DownloadEntryProgressBytesSoFar"] as? NSNumber)?.doubleValue ?? 0
                    let total = (d?["DownloadEntryProgressTotalToLoad"] as? NSNumber)?.doubleValue
                    found.append((url.path, url.deletingPathExtension().lastPathComponent, got, total))
                } else if ext == "crdownload" || ext == "part" {
                    let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.doubleValue ?? 0
                    var name = url.deletingPathExtension().lastPathComponent
                    if name.hasPrefix("Unconfirmed ") { name = L("Downloading…") }
                    found.append((url.path, name, size, nil))
                }
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.apply(found, dir: dir) } }
        }
    }

    private func apply(_ found: [(path: String, name: String, received: Double, total: Double?)], dir: URL) {
        let now = Date()
        var next: [Item] = []
        for f in found {
            var it = items.first { $0.id == f.path } ?? Item(id: f.path, name: f.name, received: f.received, total: f.total)
            it.name = f.name
            it.total = f.total
            if let last = lastSample[f.path] {
                let dt = now.timeIntervalSince(last.at)
                if dt > 0.3 {
                    let inst = max(0, f.received - last.bytes) / dt
                    it.speed = it.speed == 0 ? inst : it.speed * 0.6 + inst * 0.4     // сглаживаем
                    lastSample[f.path] = (f.received, now)
                }
            } else {
                lastSample[f.path] = (f.received, now)
            }
            it.received = f.received
            next.append(it)
        }
        // Незаконченный файл пропал — загрузка завершилась (или её отменили)
        for old in items where !old.finished && !found.contains(where: { $0.path == old.id }) {
            let final = dir.appendingPathComponent(old.name)
            lastSample[old.id] = nil
            guard FileManager.default.fileExists(atPath: final.path) else { continue }     // отменили
            var done = old
            done.finished = true
            done.finalURL = final
            if let t = done.total { done.received = t }
            next.append(done)
            finishedEvent.send(done)
            let id = done.id
            DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in self?.dismiss(id) }
        }
        // Завершённые ещё какое-то время показываем
        next += items.filter { $0.finished && !next.contains($0) }
        if next != items { items = next }
        ensureTimer()
    }

    func dismiss(_ id: String) { items.removeAll { $0.id == id && $0.finished } }

    func open(_ item: Item) { if let u = item.finalURL { NSWorkspace.shared.open(u) }; dismiss(item.id) }
    func reveal(_ item: Item) { if let u = item.finalURL { NSWorkspace.shared.activateFileViewerSelecting([u]) } }

    static func bytes(_ b: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .file)
    }
}
