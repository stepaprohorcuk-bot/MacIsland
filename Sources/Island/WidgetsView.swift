import AppKit
import SwiftUI

enum WidgetKind: String { case weather, system, notes }

// MARK: - Ряд плиток: Погода · Система · Заметки

struct WidgetRow: View {
    @ObservedObject var state: IslandState
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var weather = Weather.shared
    @ObservedObject var system = SystemMonitor.shared
    @ObservedObject var notes = NotesStore.shared

    var body: some View {
        HStack(spacing: 6) {
            if settings.showWeather {
                tile(.weather, symbol: weather.temp == nil ? "cloud.sun" : weather.symbol,
                     value: Weather.deg(weather.temp),
                     caption: weather.place.isEmpty ? L("Weather") : weather.place, tint: .yellow)
            }
            if settings.showSystem {
                tile(.system, symbol: "cpu", value: "\(Int((system.cpu * 100).rounded()))%",
                     caption: "RAM \(Int((system.ramFraction * 100).rounded()))%", tint: .green)
            }
            if settings.showNotes {
                tile(.notes, symbol: "checklist", value: "\(notes.openCount)", caption: L("Notes"), tint: .orange)
            }
        }
    }

    private func tile(_ kind: WidgetKind, symbol: String, value: String, caption: String, tint: Color) -> some View {
        let active = state.widget == kind
        return Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                state.widget = active ? nil : kind
                state.showTimerPicker = false; state.showClipboard = false
            }
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Image(systemName: symbol).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(tint)
                        .symbolRenderingMode(.multicolor)
                    Text(value).font(.system(size: 12, weight: .bold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.7)
                }
                Text(caption).font(.system(size: 9.5, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.tertiary).lineLimit(1)
            }
            .padding(.horizontal, 7)
            .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(active ? Theme.accent.opacity(0.28) : Theme.card))
            .contentShape(RoundedRectangle(cornerRadius: 11))
        }
        .buttonStyle(.plain)
        .help(caption)
    }
}

/// Подробная карточка выбранной плитки.
struct WidgetDetail: View {
    let kind: WidgetKind
    var body: some View {
        switch kind {
        case .weather: WeatherCard()
        case .system: SystemCard()
        case .notes: NotesCard()
        }
    }
}

// MARK: - Погода

struct WeatherCard: View {
    @ObservedObject var w = Weather.shared
    @ObservedObject var settings = AppSettings.shared

    var body: some View {
        Card {
            if settings.weatherCity.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Choose a city to see the weather.").font(.system(size: 12.5, design: .rounded)).foregroundStyle(.white.opacity(0.85))
                    TextPill(symbol: "gearshape.fill", title: L("Set city")) { SettingsWindow.shared.show(tab: .widgets) }
                }
            } else if let err = w.error, w.temp == nil {
                Text(err).font(.system(size: 12.5, design: .rounded)).foregroundStyle(Color(red: 1, green: 0.6, blue: 0.6))
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        Image(systemName: w.symbol).symbolRenderingMode(.multicolor).font(.system(size: 30))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(Weather.deg(w.temp)).font(.system(size: 26, weight: .bold, design: .rounded)).foregroundStyle(.white)
                            Text("\(w.condition) · \(w.place)").font(.system(size: 11.5, design: .rounded)).foregroundStyle(Theme.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(Lf("Feels like %@", Weather.deg(w.feels)))
                            Text(Lf("Wind %.0f m/s · %.0f%%", w.wind, w.humidity))
                            Text("↑\(Weather.deg(w.high))  ↓\(Weather.deg(w.low))")
                        }
                        .font(.system(size: 10.5, design: .rounded)).foregroundStyle(Theme.secondary)
                    }
                    if !w.hours.isEmpty {
                        HStack {
                            ForEach(w.hours) { h in
                                VStack(spacing: 3) {
                                    Text(h.id.formatted(.dateTime.hour(.twoDigits(amPM: .omitted))))
                                        .font(.system(size: 10, design: .rounded)).foregroundStyle(Theme.tertiary)
                                    Image(systemName: Weather.symbol(h.code, day: true)).symbolRenderingMode(.multicolor).font(.system(size: 13))
                                    Text(Weather.deg(h.temp)).font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(.white)
                                }
                                .frame(maxWidth: .infinity)
                            }
                        }
                    }
                }
            }
        }
        .onAppear { w.refresh() }
    }
}

// MARK: - Система

struct SystemCard: View {
    @ObservedObject var sys = SystemMonitor.shared

    var body: some View {
        Card {
            VStack(spacing: 8) {
                row(L("CPU"), "\(Int((sys.cpu * 100).rounded()))%", sys.cpu, .green)
                row(L("Memory"), "\(SystemMonitor.gb(sys.ramUsed)) / \(SystemMonitor.gb(sys.ramTotal)) GB", sys.ramFraction, .yellow)
                let used = sys.diskTotal > 0 ? 1 - sys.diskFree / sys.diskTotal : 0
                row(L("Disk"), Lf("%@ GB free", SystemMonitor.gb(sys.diskFree)), used, .blue)
                HStack {
                    Spacer()
                    Button(L("Activity Monitor")) {
                        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(Theme.accent)
                }
            }
        }
    }

    private func row(_ title: String, _ value: String, _ f: Double, _ tint: Color) -> some View {
        VStack(spacing: 3) {
            HStack {
                Text(title).font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(.white)
                Spacer()
                Text(value).font(.system(size: 11.5, design: .rounded)).monospacedDigit().foregroundStyle(Theme.secondary)
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.12))
                    Capsule().fill(f > 0.85 ? Color.red : tint).frame(width: g.size.width * min(1, max(0, f)))
                }
            }
            .frame(height: 4)
        }
    }
}

// MARK: - Заметки

struct NotesCard: View {
    @ObservedObject var store = NotesStore.shared
    @State private var draft = ""

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "plus.circle.fill").foregroundStyle(Theme.accent)
                    TextField("", text: $draft, prompt: Text("New note or task…").foregroundColor(Theme.tertiary))
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5, design: .rounded)).foregroundStyle(.white)
                        .onSubmit { store.add(draft); draft = "" }
                }
                .padding(.horizontal, 8).frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.07)))

                if store.notes.isEmpty {
                    Text("Notes are stored only on this Mac.").font(.system(size: 11, design: .rounded)).foregroundStyle(Theme.tertiary)
                } else {
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 2) {
                            ForEach(store.notes) { NoteLine(note: $0) }
                        }
                    }
                    .frame(maxHeight: 170)
                    .fixedSize(horizontal: false, vertical: store.notes.count <= 5)
                    if store.notes.contains(where: \.done) {
                        Button(L("Remove completed")) { withAnimation { store.clearDone() } }
                            .buttonStyle(.plain)
                            .font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(Theme.tertiary)
                    }
                }
            }
        }
    }
}

struct NoteLine: View {
    let note: NotesStore.Note
    @State private var hover = false
    var body: some View {
        HStack(spacing: 8) {
            Button { withAnimation { NotesStore.shared.toggle(note) } } label: {
                Image(systemName: note.done ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(note.done ? Theme.accent : Theme.secondary)
            }
            .buttonStyle(.plain)
            Text(note.text)
                .font(.system(size: 12.5, design: .rounded))
                .strikethrough(note.done)
                .foregroundStyle(note.done ? Theme.tertiary : .white.opacity(0.9))
                .lineLimit(2)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if hover {
                SmallIcon(symbol: "xmark", help: L("Delete")) { withAnimation { NotesStore.shared.delete(note) } }
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 7).fill(hover ? Color.white.opacity(0.06) : .clear))
        .onHover { hover = $0 }
    }
}

// MARK: - Загрузки

struct DownloadsCard: View {
    @ObservedObject var dl = DownloadsWatcher.shared

    var body: some View {
        Card {
            VStack(spacing: 8) {
                ForEach(dl.items) { it in
                    HStack(spacing: 10) {
                        Image(systemName: it.finished ? "checkmark.circle.fill" : "arrow.down.circle.fill")
                            .font(.system(size: 20)).foregroundStyle(it.finished ? .green : Theme.accent)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(it.name).font(.system(size: 12.5, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white).lineLimit(1).truncationMode(.middle)
                            if !it.finished {
                                ProgressBar(fraction: it.fraction)
                            }
                            Text(detail(it)).font(.system(size: 10.5, design: .rounded)).monospacedDigit()
                                .foregroundStyle(Theme.tertiary).lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        if it.finished {
                            TextPill(symbol: "arrow.up.forward.app", title: L("Open")) { dl.open(it) }
                            SmallIcon(symbol: "magnifyingglass", help: L("Show in Finder")) { dl.reveal(it) }
                        }
                    }
                }
            }
        }
    }

    private func detail(_ it: DownloadsWatcher.Item) -> String {
        if it.finished { return L("Downloaded") + " · " + DownloadsWatcher.bytes(it.received) }
        var parts: [String] = []
        if let f = it.fraction { parts.append("\(Int(f * 100))%") }
        parts.append(it.total.map { "\(DownloadsWatcher.bytes(it.received)) / \(DownloadsWatcher.bytes($0))" } ?? DownloadsWatcher.bytes(it.received))
        if it.speed > 1 { parts.append(DownloadsWatcher.bytes(it.speed) + L("/s")) }
        if let eta = it.eta { parts.append(Lf("%@ left", clock(eta))) }
        return parts.joined(separator: " · ")
    }
}

struct ProgressBar: View {
    let fraction: Double?
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20, paused: fraction != nil)) { ctx in
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.12))
                    if let f = fraction {
                        Capsule().fill(Theme.accent).frame(width: g.size.width * f)
                    } else {
                        // размер неизвестен — бегущая полоска
                        let ph = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4) / 1.4
                        Capsule().fill(Theme.accent).frame(width: g.size.width * 0.3)
                            .offset(x: g.size.width * (CGFloat(ph) * 1.3 - 0.3))
                    }
                }
                .clipShape(Capsule())
            }
        }
        .frame(height: 4)
    }
}

// MARK: - Быстрый запуск: подходящие программы под строкой

struct LauncherRow: View {
    let results: [AppIndex.Entry]
    var onOpen: (AppIndex.Entry) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(results) { e in
                Button { onOpen(e) } label: {
                    HStack(spacing: 6) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: e.url.path)).resizable().frame(width: 22, height: 22)
                        Text(e.name).font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white).lineLimit(1)
                    }
                    .padding(.horizontal, 8).frame(height: 32)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.card))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(Lf("Open %@", e.name))
            }
        }
    }
}
