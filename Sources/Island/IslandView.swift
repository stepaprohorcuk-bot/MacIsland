import AppKit
import SwiftUI

enum Theme {
    static let accent = Color(red: 0.62, green: 0.52, blue: 1.0)      // фиолетовый, как в концепте
    static let timer = Color(red: 1.0, green: 0.62, blue: 0.2)
    static let card = Color.white.opacity(0.07)
    static let secondary = Color.white.opacity(0.55)
    static let tertiary = Color.white.opacity(0.35)
}

// MARK: - Форма: «ушки» сверху, скругление снизу

struct NotchShape: Shape {
    var ear: CGFloat
    var bottom: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(ear, bottom) }
        set { ear = newValue.first; bottom = newValue.second }
    }

    func path(in r: CGRect) -> Path {
        let w = r.width, h = r.height
        let e = min(ear, w / 4), b = min(bottom, h / 2, (w - 2 * e) / 2)
        var p = Path()
        p.move(to: CGPoint(x: 0, y: 0))
        p.addQuadCurve(to: CGPoint(x: e, y: e), control: CGPoint(x: e, y: 0))
        p.addLine(to: CGPoint(x: e, y: h - b))
        p.addQuadCurve(to: CGPoint(x: e + b, y: h), control: CGPoint(x: e, y: h))
        p.addLine(to: CGPoint(x: w - e - b, y: h))
        p.addQuadCurve(to: CGPoint(x: w - e, y: h - b), control: CGPoint(x: w - e, y: h))
        p.addLine(to: CGPoint(x: w - e, y: e))
        p.addQuadCurve(to: CGPoint(x: w, y: 0), control: CGPoint(x: w - e, y: 0))
        p.closeSubpath()
        return p
    }
}

// MARK: - Остров целиком

struct IslandView: View {
    @ObservedObject var state: IslandState
    @ObservedObject var settings = AppSettings.shared

    var body: some View {
        let size = state.size
        let shape = NotchShape(ear: state.ear, bottom: state.bottomRadius)
        ZStack(alignment: .top) {
            if state.expanded {
                ExpandedView(state: state)
                    .frame(width: state.expandedSize.width)
                    .fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { h in
                        if abs(h - state.contentHeight) > 0.5 {
                            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { state.contentHeight = h }
                        }
                    }
                    // Убираем сразу, без анимации исчезновения: её SwiftUI иногда не доводит до конца,
                    // и «призрак» раскрытого вида остаётся висеть. Плавность даёт сжимающаяся форма острова.
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.94, anchor: .top))
                            .animation(.easeOut(duration: 0.26).delay(0.06)),
                        removal: .identity))
            } else {
                CompactView(state: state)
                    .frame(width: state.collapsedSize.width, height: state.collapsedSize.height, alignment: .top)
                    .transition(.opacity.animation(.easeInOut(duration: 0.18)))
            }
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .clipShape(shape)
        .background(IslandBackground(shape: shape, glassStyle: settings.style == .glass,
                                     expanded: state.expanded, notchHeight: state.notch.height))
        .shadow(color: .black.opacity(state.expanded ? 0.45 : 0), radius: 16, y: 8)
        .offset(x: state.compactOffset)     // одна боковая часть — сдвигаем, чтобы чёлка была на месте
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .id(state.renderEpoch)        // после сворачивания перестраиваем остров начисто
        .environment(\.colorScheme, .dark)
        // Остров не забирает фокус у программ, поэтому macOS считает его «неактивным» и рисует стекло
        // плоским серым. Говорим SwiftUI, что вид всегда активен.
        .environment(\.appearsActive, true)
    }
}

/// Фон: чёрный (сливается с чёлкой) или стекло с чёрной полосой под камерой.
/// Системный Liquid Glass меняет вид в зависимости от фокуса окна (наведение — светлее, нажатие — темнее),
/// поэтому стекло своё: размытие, которое macOS всегда рисует «активным», плюс тёмный тон и блик по краю.
struct IslandBackground: View {
    let shape: NotchShape
    let glassStyle: Bool
    let expanded: Bool
    let notchHeight: CGFloat

    var body: some View {
        let showGlass = glassStyle && expanded
        // Фон строго в размер острова — ничего не должно вылезать ниже чёлки
        GeometryReader { g in
            ZStack(alignment: .top) {
                if glassStyle {
                    ActiveBlur(ear: shape.ear, bottom: shape.bottom, size: g.size)
                    shape.fill(Color.black.opacity(0.38))
                    shape.stroke(Color.white.opacity(0.14), lineWidth: 1).opacity(showGlass ? 1 : 0)
                }
                shape.fill(Color.black).opacity(showGlass ? 0 : 1)
                LinearGradient(colors: [.black, .black, .black.opacity(0)], startPoint: .top, endPoint: .bottom)
                    .frame(height: min(notchHeight + 18, g.size.height))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .clipShape(shape)
                    .opacity(showGlass ? 1 : 0)
            }
            .frame(width: g.size.width, height: g.size.height)
        }
        .animation(.easeInOut(duration: 0.22), value: showGlass)
    }
}

/// Размытие того, что под островом. Состояние всегда «активное» — не зависит от фокуса окна.
/// Форма задаётся maskImage (рисуется под текущий размер), а не маской слоя: с ней размытие ломается.
struct ActiveBlur: NSViewRepresentable {
    var ear: CGFloat
    var bottom: CGFloat
    var size: CGSize

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        v.appearance = NSAppearance(named: .darkAqua)
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        let ear = ear, bottom = bottom
        let mask = NSImage(size: NSSize(width: max(size.width, 1), height: max(size.height, 1)), flipped: true) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.addPath(NotchShape(ear: ear, bottom: bottom).path(in: rect).cgPath)
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.fillPath()
            return true
        }
        mask.resizingMode = .stretch       // растягиваем на весь остров (по умолчанию картинка повторяется плиткой)
        mask.capInsets = NSEdgeInsetsZero
        v.maskImage = mask
    }
}

// MARK: - Свёрнутый вид: по бокам от камеры

struct CompactView: View {
    @ObservedObject var state: IslandState
    @ObservedObject var music = NowPlaying.shared
    @ObservedObject var timers = Timers.shared
    @ObservedObject var pomodoro = PomodoroModel.shared
    @ObservedObject var settings = AppSettings.shared

    var body: some View {
        VStack(spacing: 0) {
            if state.showLeft || state.showRight || state.toast != nil {
                HStack(spacing: 0) {
                    if state.showLeft || state.toast != nil { left.frame(width: IslandState.wing + 6) }
                    Spacer(minLength: 0)
                    if state.showRight || state.toast != nil { right.frame(width: IslandState.wing + 6) }
                }
                .frame(height: state.notch.height)
            } else {
                Color.clear.frame(height: state.notch.height)
            }
            if let t = state.toast {
                HStack(spacing: 8) {
                    Image(systemName: t.icon).font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.accent)
                    Text(t.text).font(.system(size: 12.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white).lineLimit(1)
                }
                .padding(.horizontal, 18)
                .frame(height: IslandState.toastH - 4)
                .id(t.id)
                .transition(.opacity)
            }
        }
    }

    private var showMusic: Bool { settings.showMusic && music.hasTrack }

    @ViewBuilder private var left: some View {
        if showMusic, let art = music.artwork {
            Image(nsImage: art).resizable().aspectRatio(contentMode: .fill)
                .frame(width: 20, height: 20)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        } else if pomodoro.active {
            LiquidOrb(model: pomodoro, size: state.notch.height * 0.72, fps: 24)
        } else if timers.active {
            Image(systemName: "timer").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.timer)
        } else if downloads.items.contains(where: { !$0.finished }) {
            Image(systemName: "arrow.down.circle.fill").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.accent)
        } else if showMusic {
            Image(systemName: "music.note").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.accent)
        }
    }

    @ObservedObject var devices = Devices.shared
    @ObservedObject var downloads = DownloadsWatcher.shared

    @ViewBuilder private var right: some View {
        HStack(spacing: 3) {
            if devices.cameraInUse { Circle().fill(Color.green).frame(width: 6, height: 6).help(L("Camera is in use")) }
            if devices.micInUse { Circle().fill(Color.orange).frame(width: 6, height: 6).help(L("Microphone is in use")) }
            rightContent
        }
    }

    @ViewBuilder private var rightContent: some View {
        if pomodoro.active {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                Text(pomodoro.timeString(at: ctx.date))
                    .font(.system(size: 12, weight: .bold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(LiquidPalette.for(pomodoro.phase).top)
            }
        } else if let first = timers.items.first {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                Text(clock(first.value(at: ctx.date)))
                    .font(.system(size: 12, weight: .bold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(Theme.timer)
            }
        } else if let d = downloads.items.first(where: { !$0.finished }) {
            ZStack {
                Circle().stroke(Color.white.opacity(0.2), lineWidth: 2.5)
                Circle().trim(from: 0, to: d.fraction ?? 0.25)
                    .stroke(Theme.accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 14, height: 14)
        } else if showMusic && music.playing {
            EqualizerBars(color: Theme.accent)
        }
    }
}

struct EqualizerBars: View {
    let color: Color
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 12)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2) {
                ForEach(0..<4, id: \.self) { i in
                    Capsule().fill(color)
                        .frame(width: 2.5, height: 4 + 8 * abs(sin(t * (2.2 + Double(i) * 0.7) + Double(i))))
                }
            }
            .frame(height: 14)
        }
    }
}

// MARK: - Раскрытый вид

struct ExpandedView: View {
    @ObservedObject var state: IslandState
    @ObservedObject var music = NowPlaying.shared
    @ObservedObject var timers = Timers.shared
    @ObservedObject var pomodoro = PomodoroModel.shared
    @ObservedObject var assistant = Assistant.shared
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var notes = NotificationWatcher.shared
    @ObservedObject var downloads = DownloadsWatcher.shared
    @ObservedObject var apps = AppIndex.shared

    private var widgetsOn: Bool {
        settings.showWeather || settings.showSystem || settings.showNotes
    }
    private var launch: [AppIndex.Entry] {
        let q = assistant.query
        guard settings.quickLaunch, Timers.parse(q) == nil, Calculator.evaluate(q) == nil else { return [] }
        return apps.search(q)
    }

    private var showMusic: Bool { settings.showMusic && music.hasTrack }
    private var showNotes: Bool { settings.notificationsEnabled && !notes.recent.isEmpty }
    private var nothing: Bool { !showMusic && !pomodoro.active && timers.items.isEmpty && !showNotes && !state.showClipboard && !state.showTimerPicker }

    var body: some View {
        VStack(spacing: 8) {
            HeaderRow(state: state)
            if widgetsOn { WidgetRow(state: state) }
            if let w = state.widget { WidgetDetail(kind: w).transition(.opacity) }
            if showMusic { MediaSection(music: music) }
            if pomodoro.active { PomodoroCard(pomodoro: pomodoro) }
            ForEach(timers.items) { TimerRow(item: $0) }
            if settings.showDownloads && !downloads.items.isEmpty { DownloadsCard() }
            if showNotes { NotificationsCard() }
            if nothing && !assistant.panelVisible && !widgetsOn { IdleCard() }
            if state.showTimerPicker { TimerPicker(state: state) }
            if state.showClipboard {
                ClipboardCard(onCopied: { state.flash?("doc.on.clipboard", $0) })
            }
            if assistant.panelVisible { AnswerCard(assistant: assistant) }
            if !launch.isEmpty {
                LauncherRow(results: launch) { e in
                    apps.open(e)
                    assistant.query = ""
                    assistant.onDismiss?()
                }
            }
            BottomBar(state: state, assistant: assistant)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
    }
}

/// Ряд по бокам от камеры: батарея слева, настройки справа.
struct HeaderRow: View {
    @ObservedObject var state: IslandState
    @ObservedObject var battery = Battery.shared
    @ObservedObject var settings = AppSettings.shared

    var body: some View {
        HStack {
            if settings.showBattery && battery.hasBattery {
                HStack(spacing: 5) {
                    Image(systemName: battery.symbol)
                        .foregroundStyle(battery.level <= 20 && !battery.pluggedIn ? .red : (battery.charging ? .green : Theme.secondary))
                    Text("\(battery.level)%").monospacedDigit()
                }
                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.secondary)
                .help(battery.charging ? L("Charging") : (battery.pluggedIn ? L("Plugged in") : L("On battery")))
            }
            Spacer()
            Button { SettingsWindow.shared.show() } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.secondary)
                    .frame(width: 26, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L("Settings"))
        }
        .padding(.horizontal, 12)
        .frame(height: state.notch.height)
    }
}

// MARK: Карточки

struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.card))
    }
}

struct IconButton: View {
    let symbol: String
    var size: CGFloat = 30
    var filled = false
    var tint: Color = .white
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.42, weight: .bold))
                .foregroundStyle(filled ? Color.black : tint.opacity(0.9))
                .frame(width: size, height: size)
                .background(Circle().fill(filled ? tint : Color.white.opacity(0.1)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

struct MusicCard: View {
    @ObservedObject var music: NowPlaying
    @ObservedObject var voice = VoiceCommands.shared

    var body: some View {
        Card {
            HStack(spacing: 11) {
                cover
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(music.title)
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundStyle(.white).lineLimit(1)
                        if voice.status == .listening {
                            Image(systemName: "waveform")
                                .font(.system(size: 9.5, weight: .semibold))
                                .foregroundStyle(Theme.accent.opacity(0.8))
                                .help(L("Voice control is on: say “next”, “back” or “pause”"))
                        }
                    }
                    Text(music.artist.isEmpty ? music.appName : music.artist)
                        .font(.system(size: 11.5, weight: .medium, design: .rounded))
                        .foregroundStyle(Theme.secondary).lineLimit(1)
                    if music.duration > 0 { progress.padding(.top, 4) }
                }
                Spacer(minLength: 4)
                HStack(spacing: 4) {
                    IconButton(symbol: "backward.fill", size: 28, help: L("Previous track")) { music.previous() }
                    IconButton(symbol: music.playing ? "pause.fill" : "play.fill", size: 34, filled: true,
                               tint: .white, help: music.playing ? L("Pause") : L("Play")) { music.toggle() }
                    IconButton(symbol: "forward.fill", size: 28, help: L("Next track")) { music.next() }
                }
            }
        }
    }

    private var cover: some View {
        ZStack {
            if let a = music.artwork {
                Image(nsImage: a).resizable().aspectRatio(contentMode: .fill)
            } else if let i = music.appIcon {
                Image(nsImage: i).resizable().padding(4)
            } else {
                Image(systemName: "music.note").font(.system(size: 16)).foregroundStyle(Theme.secondary)
            }
        }
        .frame(width: 44, height: 44)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .help(music.appName)
    }

    /// Тонкая полоска прогресса; время — во всплывающей подсказке, чтобы не занимать место.
    private var progress: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let pos = music.position(at: ctx.date)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.14))
                    Capsule().fill(Theme.accent).frame(width: g.size.width * pos / max(music.duration, 1))
                }
            }
            .frame(height: 3)
            .help("\(clock(pos)) / \(clock(music.duration))")
        }
    }
}

/// Если играют (или стоят на паузе) несколько источников — карточка делится пополам:
/// слева видео, справа музыка, у каждой половины свои кнопки. Один источник — обычная карточка.
struct MediaSection: View {
    @ObservedObject var music: NowPlaying

    private var pair: [Player] {
        let ps = music.players.filter { !$0.title.isEmpty }
        guard ps.count >= 2 else { return [] }
        let videos = ps.filter(\.isVideo).sorted { $0.playing && !$1.playing }
        let songs = ps.filter { !$0.isVideo }.sorted { $0.playing && !$1.playing }
        if let v = videos.first, let m = songs.first { return [v, m] }
        return Array((videos + songs).prefix(2))
    }

    var body: some View {
        let pair = pair
        if pair.count == 2 {
            HStack(spacing: 8) {
                ForEach(pair) { MediaHalf(music: music, player: $0) }
            }
            .transition(.opacity)
        } else {
            MusicCard(music: music)
        }
    }
}

struct MediaHalf: View {
    @ObservedObject var music: NowPlaying
    let player: Player

    private var isMain: Bool { player.id == music.currentPid }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                cover
                VStack(alignment: .leading, spacing: 1) {
                    Text(player.title)
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(.white).lineLimit(1)
                    Text(player.artist.isEmpty ? player.appName : player.artist)
                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                        .foregroundStyle(Theme.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            if player.duration > 0 { progress }
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                IconButton(symbol: "backward.fill", size: 25, help: L("Previous track")) { music.previous(player) }
                IconButton(symbol: player.playing ? "pause.fill" : "play.fill", size: 31, filled: true,
                           tint: .white, help: player.playing ? L("Pause") : L("Play")) { music.toggle(player) }
                IconButton(symbol: "forward.fill", size: 25, help: L("Next track")) { music.next(player) }
                Spacer(minLength: 0)
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(Theme.accent.opacity(isMain ? 0.45 : 0), lineWidth: 1))
        .help(player.appName)
    }

    private var cover: some View {
        ZStack(alignment: .bottomTrailing) {
            ZStack {
                if let a = player.artwork {
                    Image(nsImage: a).resizable().aspectRatio(contentMode: .fill)
                } else if let i = player.appIcon {
                    Image(nsImage: i).resizable().padding(3)
                } else {
                    Image(systemName: player.isVideo ? "play.rectangle.fill" : "music.note")
                        .font(.system(size: 14)).foregroundStyle(Theme.secondary)
                }
            }
            .frame(width: 36, height: 36)
            .background(Color.white.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            // значок программы поверх обложки — видно, откуда звук
            if player.artwork != nil, let i = player.appIcon {
                Image(nsImage: i).resizable().frame(width: 15, height: 15).offset(x: 4, y: 4)
            }
        }
        .frame(width: 40, height: 40, alignment: .topLeading)
    }

    private var progress: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let pos = player.position(at: ctx.date)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.14))
                    Capsule().fill(Theme.accent).frame(width: g.size.width * pos / max(player.duration, 1))
                }
            }
            .frame(height: 3)
            .help("\(clock(pos)) / \(clock(player.duration))")
        }
    }
}

struct PomodoroCard: View {
    @ObservedObject var pomodoro: PomodoroModel

    var body: some View {
        let palette = LiquidPalette.for(pomodoro.phase)
        Card {
            HStack(spacing: 14) {
                LiquidOrb(model: pomodoro, size: 56, fps: 60)
                    .dropDestination(for: URL.self) { urls, _ in
                        guard let u = urls.first else { return false }
                        return BackgroundStore.shared.set(u)
                    }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Pomodoro · " + pomodoro.phaseTitle)
                        .font(.system(size: 11.5, weight: .bold, design: .rounded))
                        .foregroundStyle(palette.top)
                    Text(pomodoro.timeString())
                        .font(.system(size: 26, weight: .bold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(.white)
                        .contentTransition(.numericText(countsDown: true))
                        .animation(.snappy, value: pomodoro.timeString())
                    HStack(spacing: 5) {
                        ForEach(0..<4, id: \.self) { i in
                            Circle()
                                .fill(i < pomodoro.completedFocus % 4 || (pomodoro.completedFocus > 0 && pomodoro.completedFocus % 4 == 0 && pomodoro.phase == .rest)
                                      ? palette.top : Color.white.opacity(0.15))
                                .frame(width: 6, height: 6)
                        }
                        Text(Lf("%d done", pomodoro.completedFocus))
                            .font(.system(size: 10.5, weight: .medium, design: .rounded))
                            .foregroundStyle(Theme.tertiary)
                    }
                }
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    IconButton(symbol: pomodoro.isRunning ? "pause.fill" : "play.fill", size: 34, filled: true,
                               tint: palette.top, help: pomodoro.isRunning ? L("Pause") : L("Resume")) { pomodoro.toggle() }
                    IconButton(symbol: "forward.end.fill", size: 28,
                               help: pomodoro.phase == .focus ? L("Skip to break") : L("Skip to focus")) { pomodoro.skip() }
                    IconButton(symbol: "xmark", size: 28, help: L("Stop Pomodoro")) { pomodoro.stop() }
                }
            }
        }
    }
}

struct TimerRow: View {
    let item: Timers.Item
    private let timers = Timers.shared

    var body: some View {
        Card {
            HStack(spacing: 12) {
                Image(systemName: item.isStopwatch ? "stopwatch.fill" : "timer")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(item.finished ? Theme.secondary : Theme.timer)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 1) {
                    TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
                        Text(item.finished ? L("Done") : clock(item.value(at: ctx.date)))
                            .font(.system(size: 20, weight: .bold, design: .rounded)).monospacedDigit()
                            .foregroundStyle(item.finished ? Theme.timer : .white)
                    }
                    Text(item.title)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(Theme.tertiary)
                }
                Spacer(minLength: 0)
                if item.finished {
                    TextPill(symbol: "arrow.clockwise", title: L("Repeat")) { timers.repeatTimer(item.id) }
                } else {
                    IconButton(symbol: item.running ? "pause.fill" : "play.fill", size: 30, filled: true,
                               tint: Theme.timer, help: item.running ? L("Pause") : L("Resume")) { timers.toggle(item.id) }
                }
                IconButton(symbol: "xmark", size: 28, help: L("Remove")) {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { timers.remove(item.id) }
                }
            }
        }
    }
}

struct IdleCard: View {
    var body: some View {
        Card {
            TimelineView(.periodic(from: .now, by: 10)) { ctx in
                HStack(spacing: 14) {
                    Text(ctx.date.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 24, weight: .bold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(.white)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ctx.date.formatted(.dateTime.weekday(.wide)).capitalized)
                            .font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundStyle(.white)
                        Text(ctx.date.formatted(.dateTime.day().month(.wide)))
                            .font(.system(size: 12, weight: .medium, design: .rounded)).foregroundStyle(Theme.secondary)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

struct TimerPicker: View {
    @ObservedObject var state: IslandState
    private let presets = [1, 3, 5, 10, 15, 25, 30, 60]

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Text("New timer")
                    .font(.system(size: 11.5, weight: .bold, design: .rounded)).foregroundStyle(Theme.secondary)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 5), spacing: 6) {
                    ForEach(presets, id: \.self) { m in
                        chip(Lf("%d min", m)) { Timers.shared.start(seconds: TimeInterval(m * 60)) }
                    }
                    chip(L("Stopwatch")) { Timers.shared.startStopwatch() }
                    chip(L("Pomodoro")) { PomodoroModel.shared.begin() }
                }
                Text("Tip: type “7 min” or “1:30” in the field below")
                    .font(.system(size: 10.5, design: .rounded)).foregroundStyle(Theme.tertiary)
            }
        }
    }

    private func chip(_ title: String, action: @escaping () -> Void) -> some View {
        Button {
            action()
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { state.showTimerPicker = false }
        } label: {
            Text(title)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1).minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity).frame(height: 28)
                .background(Capsule().fill(Color.white.opacity(0.1)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct AnswerCard: View {
    @ObservedObject var assistant: Assistant

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    if assistant.busy { ProgressView().controlSize(.mini) }
                    Text(status)
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.accent)
                    Spacer()
                    if !assistant.answer.isEmpty && !assistant.busy {
                        SmallIcon(symbol: assistant.speaking ? "speaker.slash.fill" : "speaker.wave.2.fill",
                                  help: L("Read aloud")) { assistant.speak() }
                        SmallIcon(symbol: "doc.on.doc", help: L("Copy")) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(assistant.answer.replacingOccurrences(of: "**", with: ""), forType: .string)
                        }
                    }
                    SmallIcon(symbol: "xmark", help: L("Close")) { assistant.clear() }
                }
                content
            }
        }
    }

    private var status: String {
        switch assistant.phase {
        case .thinking: return L("Thinking…") + (assistant.source.isEmpty ? "" : " · " + assistant.source)
        case .failed: return L("Couldn't answer")
        case .needsSetup: return L("No AI connected")
        default: return assistant.source
        }
    }

    @ViewBuilder private var content: some View {
        switch assistant.phase {
        case .needsSetup:
            VStack(alignment: .leading, spacing: 10) {
                Text("To get answers right here, connect an AI in Settings: Apple Intelligence (English and other supported languages) or your own API key — OpenRouter, OpenAI, Groq or a local Ollama.")
                    .font(.system(size: 12.5, design: .rounded)).foregroundStyle(.white.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    TextPill(symbol: "gearshape.fill", title: L("Open Settings")) { SettingsWindow.shared.show(tab: .ai) }
                    TextPill(symbol: "safari", title: L("Ask in browser")) { assistant.askInBrowser() }
                }
            }
        case .failed(let msg):
            VStack(alignment: .leading, spacing: 10) {
                Text(msg).font(.system(size: 12.5, design: .rounded)).foregroundStyle(Color(red: 1, green: 0.6, blue: 0.6))
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    TextPill(symbol: "safari", title: L("Ask in browser")) { assistant.askInBrowser() }
                    TextPill(symbol: "gearshape.fill", title: L("Settings")) { SettingsWindow.shared.show(tab: .ai) }
                }
            }
        default:
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(assistant.answer.isEmpty ? AttributedString(L("Thinking…")) : Self.markdown(assistant.answer))
                            .font(.system(size: 13, design: .rounded))
                            .foregroundStyle(.white.opacity(assistant.answer.isEmpty ? 0.4 : 0.92))
                            .lineSpacing(2)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Color.clear.frame(height: 1).id("end")
                    }
                }
                .frame(maxHeight: 220)
                .fixedSize(horizontal: false, vertical: assistant.answer.count < 280)
                .onChange(of: assistant.answer) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
            }
        }
    }

    static func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
    }
}

struct SmallIcon: View {
    let symbol: String
    let help: String
    var tint: Color = Theme.secondary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Кнопка с подписью — чтобы было понятно, что она делает.
struct TextPill: View {
    let symbol: String
    let title: String
    var active = false
    var iconOnly = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 11, weight: .bold))
                if !iconOnly {
                    Text(title).font(.system(size: 12, weight: .semibold, design: .rounded)).lineLimit(1)
                }
            }
            .foregroundStyle(active ? Color.black : .white)
            .padding(.horizontal, 11)
            .frame(height: 30)
            .background(Capsule().fill(active ? Theme.accent : Color.white.opacity(0.1)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: Нижняя строка: «Спросить» + «Таймер» + «Фокус»

struct BottomBar: View {
    @ObservedObject var state: IslandState
    @ObservedObject var assistant: Assistant
    @ObservedObject var dictation = Dictation.shared
    @ObservedObject var pomodoro = PomodoroModel.shared
    @ObservedObject var settings = AppSettings.shared
    @FocusState private var focus: Bool

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                if dictation.listening {
                    HStack(spacing: 1.5) {
                        ForEach(0..<4, id: \.self) { i in
                            Capsule().fill(Theme.accent)
                                .frame(width: 2.2, height: 3 + CGFloat(dictation.level) * [8, 13, 10, 6][i])
                        }
                    }
                    .frame(width: 16)
                } else {
                    Image(systemName: settings.showAssistant ? "sparkle.magnifyingglass" : "plusminus")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.tertiary)
                        .frame(width: 16)
                }
                TextField("", text: $assistant.query, prompt: Text(placeholder).foregroundColor(Theme.tertiary))
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.white)
                    .focused($focus)
                    .onSubmit { assistant.submit() }
                    .onExitCommand { assistant.onDismiss?() }
                if assistant.busy {
                    SmallIcon(symbol: "stop.fill", help: L("Stop")) { assistant.cancel() }
                } else {
                    SmallIcon(symbol: dictation.listening ? "mic.fill" : "mic",
                              help: L("Ask by voice"), tint: dictation.listening ? Theme.accent : Theme.secondary) {
                        dictation.toggle(onPartial: { assistant.query = $0 },
                                         onFinal: { assistant.query = $0; assistant.submit() })
                    }
                }
            }
            .padding(.horizontal, 11)
            .frame(height: 34)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(focus || dictation.listening ? Theme.accent.opacity(0.6) : .white.opacity(0.06), lineWidth: 1))

            TextPill(symbol: "timer", title: L("Timer"), active: state.showTimerPicker, iconOnly: typing) {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    state.showTimerPicker.toggle(); state.showClipboard = false; state.widget = nil
                }
            }
            .help(L("Start a timer, stopwatch or Pomodoro"))
            if !pomodoro.active {
                TextPill(symbol: "brain.head.profile", title: L("Focus"), iconOnly: typing) { pomodoro.begin() }
                    .help(Lf("Pomodoro: %d min focus, %d min break", settings.focusMinutes, settings.breakMinutes))
            }
            if settings.clipboardEnabled {
                TextPill(symbol: "doc.on.clipboard", title: L("Clipboard"), active: state.showClipboard, iconOnly: typing) {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        state.showClipboard.toggle(); state.showTimerPicker = false; state.widget = nil
                    }
                }
                .help(L("Recently copied text and screenshots"))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: typing)
        .onChange(of: focus) { _, v in assistant.focused = v }
        .onReceive(assistant.focusRequest) { _ in focus = true }
    }

    /// Пока печатаешь — кнопки сжимаются до значков, чтобы полю хватало места.
    private var typing: Bool { focus || !assistant.query.isEmpty || dictation.listening }

    private var placeholder: String {
        if dictation.listening { return L("Listening…") }
        return settings.showAssistant ? L("Ask or calculate") : L("Calculate or “5 min”")
    }
}
