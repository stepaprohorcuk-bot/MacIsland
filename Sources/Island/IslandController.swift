import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

// MARK: - Состояние острова

struct Toast: Equatable {
    var id = UUID()
    let icon: String
    let text: String
}

@MainActor
final class IslandState: ObservableObject {
    @Published var expanded = false
    @Published var notch = CGSize(width: 185, height: 32)
    @Published var contentHeight: CGFloat = 180
    @Published var wings = false              // в свёрнутом виде есть что показать по бокам
    @Published var leftFree = true            // слева от чёлки нет пунктов меню
    @Published var rightFree = true           // справа от чёлки нет значков
    @Published var toast: Toast?
    @Published var showTimerPicker = false
    @Published var showClipboard = false
    @Published var widget: WidgetKind?
    /// Меняется после сворачивания — остров перестраивается целиком (страховка от «застрявших» кусков).
    @Published var renderEpoch = 0
    /// Показать короткое сообщение (вызывается из карточек).
    var flash: ((String, String) -> Void)?

    static let width: CGFloat = 440
    static let wing: CGFloat = 42
    static let toastH: CGFloat = 34

    var showLeft: Bool { wings && leftFree }
    var showRight: Bool { wings && rightFree }
    var ear: CGFloat { expanded ? 12 : (showLeft || showRight || toast != nil ? 6 : 0) }
    /// Насколько сдвинуть свёрнутый остров, чтобы чёлка оставалась на месте, когда видна только одна сторона.
    var compactOffset: CGFloat {
        guard toast == nil, !expanded else { return 0 }
        return ((showRight ? Self.wing + 6 : 0) - (showLeft ? Self.wing + 6 : 0)) / 2
    }
    var bottomRadius: CGFloat { expanded ? 32 : (toast != nil ? 18 : 10) }

    var collapsedSize: CGSize {
        if toast != nil {
            return CGSize(width: max(notch.width + 2 * Self.wing + 12, 340), height: notch.height + Self.toastH)
        }
        return CGSize(width: notch.width + (showLeft ? Self.wing + 6 : 0) + (showRight ? Self.wing + 6 : 0), height: notch.height)
    }
    var expandedSize: CGSize {
        CGSize(width: max(Self.width, notch.width + 200), height: contentHeight)
    }
    var size: CGSize { expanded ? expandedSize : collapsedSize }
}

// MARK: - Окно у чёлки

final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }   // чтобы печатать в строке «Спросить»
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class IslandController {
    let state = IslandState()
    private var panel: NotchPanel!
    private var poller: Timer?
    private var outsideSince: Date?
    private var pinnedUntil: Date?
    private var bag = Set<AnyCancellable>()
    /// Пользователь нажал что-то внутри острова (или вызвал его ⌥Space) — держим открытым,
    /// пока не нажмёт мимо. Если только навёл курсор — остров сворачивается, когда курсор уходит.
    private var engaged = false
    private var menuTimer: Timer?
    private var menusOnRight = false      // меню программы не влезло слева и продолжается справа от чёлки
    private var extrasNear = false        // значки строки меню подходят к чёлке справа
    private var extrasTick = 0
    private var monitors: [Any] = []
    private var toastWork: DispatchWorkItem?
    private var fullScreenTimer: Timer?
    private var inFullScreen = false

    private let settings = AppSettings.shared
    private let assistant = Assistant.shared
    private let music = NowPlaying.shared
    private let timers = Timers.shared
    private let pomodoro = PomodoroModel.shared

    func setup() {
        panel = NotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                           backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isMovable = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true

        let host = FirstMouseHostingView(rootView: IslandView(state: state))
        host.sizingOptions = []
        panel.contentView = host
        layout()
        panel.orderFrontRegardless()

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.layout() } }
            .store(in: &bag)

        subscribeEvents()
        subscribeFocus()

        // Не закрываем пункты меню и значки: проверяем свободное место у чёлки
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.checkMenus() } }
            .store(in: &bag)
        settings.$wingsMode.removeDuplicates()
            .sink { [weak self] _ in DispatchQueue.main.async { MainActor.assumeIsolated { self?.checkMenus(); self?.checkExtras() } } }
            .store(in: &bag)
        let mt = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.checkMenus()
                self.extrasTick += 1
                if self.extrasTick % 3 == 0 { self.checkExtras() }
            }
        }
        RunLoop.main.add(mt, forMode: .common)
        menuTimer = mt

        HotKey.onPress = { [weak self] in MainActor.assumeIsolated { self?.summon() } }
        settings.$hotkey.removeDuplicates()
            .sink { [weak self] k in
                MainActor.assumeIsolated {
                    if !HotKey.register(k) { self?.toast("keyboard", Lf("%@ is taken by another app", k.title)) }
                }
            }
            .store(in: &bag)

        // Полноэкранные программы: остров можно прятать
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.activeSpaceDidChangeNotification)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.checkFullScreen() } }
            .store(in: &bag)
        settings.$fullScreen.removeDuplicates()
            .sink { [weak self] _ in DispatchQueue.main.async { MainActor.assumeIsolated { self?.checkFullScreen() } } }
            .store(in: &bag)
        let ft = Timer(timeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.checkFullScreen() } }
        RunLoop.main.add(ft, forMode: .common)
        fullScreenTimer = ft

        let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(t, forMode: .common)
        poller = t
    }

    // MARK: События модулей → короткие сообщения в острове

    private func subscribeEvents() {
        Battery.shared.events
            .sink { [weak self] e in
                MainActor.assumeIsolated {
                    guard let self, self.settings.showBattery else { return }
                    switch e {
                    case .plugged(let l): self.toast("battery.100percent.bolt", Lf("Charging · %d%%", l))
                    case .unplugged(let l): self.toast("battery.75percent", Lf("On battery · %d%%", l))
                    case .low(let l): self.toast("battery.25percent", Lf("Low battery · %d%%", l))
                    case .full: break
                    }
                }
            }
            .store(in: &bag)

        timers.finishedEvent
            .sink { [weak self] item in
                MainActor.assumeIsolated {
                    self?.toast("timer", Lf("%@ — done", item.title))
                    self?.pin(for: 5)
                }
            }
            .store(in: &bag)

        pomodoro.phaseFinished
            .sink { [weak self] phase in
                MainActor.assumeIsolated {
                    self?.toast(phase == .rest ? "cup.and.saucer.fill" : "brain.head.profile",
                                phase == .rest ? L("Time for a break") : L("Back to focus"))
                    self?.pin(for: 4)
                }
            }
            .store(in: &bag)

        VoiceCommands.shared.fired
            .sink { [weak self] cmd in
                MainActor.assumeIsolated {
                    switch cmd {
                    case .next: self?.toast("forward.fill", L("Next track"))
                    case .previous: self?.toast("backward.fill", L("Previous track"))
                    case .toggle: self?.toast(NowPlaying.shared.playing ? "play.fill" : "pause.fill",
                                              NowPlaying.shared.playing ? L("Play") : L("Pause"))
                    case .play: self?.toast("play.fill", L("Play"))
                    case .pause: self?.toast("pause.fill", L("Pause"))
                    }
                }
            }
            .store(in: &bag)


        assistant.onToast = { [weak self] icon, text in self?.toast(icon, text) }
        state.flash = { [weak self] icon, text in self?.toast(icon, text) }

        ClipboardStore.shared.copied
            .sink { [weak self] item in
                MainActor.assumeIsolated {
                    guard let self, self.settings.clipboardToast, !self.state.expanded else { return }
                    if item.kind == .image {
                        self.toast(item.isScreenshot ? "camera.viewfinder" : "photo",
                                   item.isScreenshot ? L("Screenshot saved to Clipboard") : L("Image copied"))
                    } else {
                        let t = (item.text ?? "").replacingOccurrences(of: "\n", with: " ")
                        self.toast("doc.on.clipboard", Lf("Copied: “%@”", t.count > 28 ? String(t.prefix(28)) + "…" : t))
                    }
                }
            }
            .store(in: &bag)

        DownloadsWatcher.shared.finishedEvent
            .sink { [weak self] it in
                MainActor.assumeIsolated { self?.toast("arrow.down.circle.fill", Lf("Downloaded: %@", it.name)) }
            }
            .store(in: &bag)

        NotificationWatcher.shared.posted
            .sink { [weak self] n in
                MainActor.assumeIsolated {
                    let who = n.appName.map { $0 + ": " } ?? ""
                    self?.toast("bell.fill", who + n.title)
                }
            }
            .store(in: &bag)
        assistant.onDismiss = { [weak self] in self?.dismiss() }

        // Любое изменение содержимого может поменять размер — SwiftUI перемеряет сам,
        // а нам нужно только обновить «крылья» свёрнутого вида.
        Publishers.MergeMany(
            music.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            timers.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            pomodoro.$active.map { _ in () }.eraseToAnyPublisher(),
            DownloadsWatcher.shared.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            Devices.shared.$micInUse.map { _ in () }.eraseToAnyPublisher(),
            Devices.shared.$cameraInUse.map { _ in () }.eraseToAnyPublisher(),
            settings.objectWillChange.map { _ in () }.eraseToAnyPublisher()
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] in MainActor.assumeIsolated { self?.updateWings() } }
        .store(in: &bag)
    }

    private func updateWings() {
        let downloading = DownloadsWatcher.shared.items.contains { !$0.finished }
        let devices = Devices.shared.micInUse || Devices.shared.cameraInUse
        let w = (settings.showMusic && music.hasTrack && music.playing) || timers.active || pomodoro.active || downloading || devices
        if w != state.wings {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) { state.wings = w }
        }
    }

    func toast(_ icon: String, _ text: String) {
        toastWork?.cancel()
        withAnimation(.spring(response: 0.4, dampingFraction: 0.78)) { state.toast = Toast(icon: icon, text: text) }
        let w = DispatchWorkItem { [weak self] in
            withAnimation(.spring(response: 0.4, dampingFraction: 0.86)) { self?.state.toast = nil }
        }
        toastWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6, execute: w)
    }

    private func pin(for seconds: TimeInterval) {
        pinnedUntil = Date().addingTimeInterval(seconds)
        setExpanded(true)
    }

    // MARK: Фокус ввода и клики снаружи

    private func subscribeFocus() {
        NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification, object: panel)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.assistant.focused = false } }
            .store(in: &bag)
        NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification, object: panel)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.assistant.focused = true } }
            .store(in: &bag)

        // Окно не активирует приложение, поэтому macOS не снимает с него фокус при клике
        // в другой программе — ловим такие клики сами (разрешений не требует).
        if let g = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.clickedOutside() } }
        }) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] e in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Клики в других окнах MacIsland (настройки, загрузка языков) — не «снаружи острова»
                guard e.window == nil || e.window === self.panel else { return }
                let p = NSEvent.mouseLocation
                if !self.state.expanded {
                    if self.hotRect().contains(p) {          // режим «раскрывать по клику»
                        self.setExpanded(true)
                        self.engaged = true
                    }
                } else if self.islandRect().contains(p) {
                    self.engaged = true                      // нажал внутри — остров держится
                } else {
                    self.clickedOutside()                    // нажал мимо — закрываем полностью
                }
            }
            return e
        }) { monitors.append(l) }
    }

    private func clickedOutside() {
        guard state.expanded else { return }
        engaged = false
        pinnedUntil = nil
        assistant.focused = false
        if panel.isKeyWindow { panel.resignKey() }
        if !Dictation.shared.listening { setExpanded(false) }
    }

    // MARK: Свободное место у чёлки

    /// Нужно места с каждой стороны: боковая часть + «ушко» + небольшой зазор.
    private var wingNeed: CGFloat { IslandState.wing + 6 + 6 + 4 }

    private func checkMenus() {
        switch settings.wingsMode {
        case .always: menusOnRight = false; setFree(left: true, right: !extrasNear)
        case .never: setFree(left: false, right: false)
        case .auto:
            // Без «Универсального доступа» не знаем, где кончается меню, — левую часть прячем на всякий случай
            guard AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication else {
                setFree(left: false, right: nil); return
            }
            let mid = targetScreen().frame.midX
            let edge = mid - state.notch.width / 2 - wingNeed
            let notchMaxX = mid + state.notch.width / 2
            let name = app.localizedName ?? "?"
            MenuBarSpace.menusMaxX(pid: app.processIdentifier) { [weak self] maxX in
                guard let self else { return }
                let m = maxX ?? 0
                let free = m <= edge
                let onRight = m > notchMaxX
                if free != self.state.leftFree || onRight != self.menusOnRight {
                    NotificationWatcher.shared.log("menus: \(name) maxX=\(Int(m)) → left \(free ? "free" : "busy"), right \(onRight ? "busy" : "free")")
                }
                self.menusOnRight = onRight
                self.setFree(left: free, right: !onRight && !self.extrasNear)
            }
        }
    }

    private func checkExtras() {
        switch settings.wingsMode {
        case .always: extrasNear = false; setFree(left: nil, right: true)
        case .never: setFree(left: false, right: false)
        case .auto:
            guard AXIsProcessTrusted() else { extrasNear = false; setFree(left: nil, right: !menusOnRight); return }
            let notchMaxX = targetScreen().frame.midX + state.notch.width / 2
            MenuBarSpace.extrasMinX(fromX: notchMaxX - 2) { [weak self] minX in
                guard let self else { return }
                let near = minX.map { $0 < notchMaxX + self.wingNeed } ?? false
                if near != self.extrasNear {
                    NotificationWatcher.shared.log("extras: minX=\(Int(minX ?? -1)) → \(near ? "near notch" : "far")")
                }
                self.extrasNear = near
                self.setFree(left: nil, right: !near && !self.menusOnRight)
            }
        }
    }

    private func setFree(left: Bool?, right: Bool?) {
        let l = left ?? state.leftFree, r = right ?? state.rightFree
        guard l != state.leftFree || r != state.rightFree else { return }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            state.leftFree = l
            state.rightFree = r
        }
    }

    // MARK: Геометрия

    private func targetScreen() -> NSScreen {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private func layout() {
        let s = targetScreen()
        let f = s.frame
        var w: CGFloat = 185
        var h = max(24, f.maxY - s.visibleFrame.maxY)
        if s.safeAreaInsets.top > 0, let l = s.auxiliaryTopLeftArea, let r = s.auxiliaryTopRightArea {
            w = f.width - l.width - r.width
            h = s.safeAreaInsets.top
        }
        state.notch = CGSize(width: w, height: h)
        let pw: CGFloat = 700, ph: CGFloat = 820
        panel.setFrame(NSRect(x: f.midX - pw / 2, y: f.maxY - ph, width: pw, height: ph), display: true)
    }

    private func islandRect() -> NSRect {
        let f = panel.frame
        let e = state.size
        return NSRect(x: f.midX - e.width / 2 + state.compactOffset, y: f.maxY - e.height, width: e.width, height: e.height)
    }

    private func hotRect() -> NSRect {
        let f = panel.frame
        let c = state.collapsedSize
        return NSRect(x: f.midX - c.width / 2 + state.compactOffset - 4, y: f.maxY - c.height - 4, width: c.width + 8, height: c.height + 5)
    }

    // MARK: Наведение

    private func poll() {
        let p = NSEvent.mouseLocation
        let f = panel.frame
        let now = Date()
        let pinned = pinnedUntil.map { now < $0 } ?? false

        if !state.expanded {
            let hot = hotRect().contains(p) && !inFullScreen
            if pinned || (hot && settings.expandOnHover) {
                setExpanded(true)
            } else {
                // Без наведения раскрываемся по клику — для этого окно должно ловить мышь над чёлкой
                panel.ignoresMouseEvents = !(hot && !settings.expandOnHover)
            }
        } else {
            let e = state.expandedSize
            let area = NSRect(x: f.midX - e.width / 2 - 16, y: f.maxY - e.height - 16,
                              width: e.width + 32, height: e.height + 17)
            if area.contains(p) {
                outsideSince = nil
                pinnedUntil = nil
            } else if engaged || Dictation.shared.listening || Translator.shared.translatingInIsland {
                outsideSince = nil
            } else if !pinned {
                if outsideSince == nil { outsideSince = now }
                if now.timeIntervalSince(outsideSince!) > 0.35 { setExpanded(false) }
            }
        }
    }

    // MARK: Полноэкранный режим

    private func checkFullScreen() {
        let fs = settings.fullScreen == .hide && FullScreenDetector.isFullScreen(on: targetScreen())
        guard fs != inFullScreen else { return }
        inFullScreen = fs
        NotificationWatcher.shared.log("fullscreen: \(fs ? "hide island" : "show island")")
        updateVisibility()
    }

    /// В полноэкранной программе остров спрятан, но появляется, если его вызвали сочетанием клавиш.
    private func updateVisibility() {
        let hide = inFullScreen && !state.expanded
        let a: CGFloat = hide ? 0 : 1
        guard panel.alphaValue != a else { return }
        NSAnimationContext.runAnimationGroup { c in
            c.duration = 0.2
            panel.animator().alphaValue = a
        }
    }

    private func summon() {
        engaged = true
        pinnedUntil = nil
        setExpanded(true)
        panel.makeKeyAndOrderFront(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.assistant.requestFocus() }
    }

    private func dismiss() {
        engaged = false
        assistant.focused = false
        if panel.isKeyWindow { panel.resignKey() }
        setExpanded(false)
    }

    private func setExpanded(_ v: Bool) {
        guard state.expanded != v else { return }
        outsideSince = nil
        if !v {
            engaged = false
            if panel.isKeyWindow { panel.resignKey() }
            state.showTimerPicker = false
            state.showClipboard = false
            state.widget = nil
        }
        // Датчики, которые нужны только раскрытому острову
        SystemMonitor.shared.setActive(v && settings.showSystem)
        if v { Weather.shared.refresh(); AppIndex.shared.refreshIfNeeded() }
        panel.ignoresMouseEvents = !v
        withAnimation(.spring(response: 0.42, dampingFraction: v ? 0.76 : 0.88)) { state.expanded = v }
        updateVisibility()
        if !v {
            // После сворачивания перерисовываем окно целиком, чтобы от раскрытого вида не оставалось «следа»
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self, !self.state.expanded else { return }
                self.state.renderEpoch &+= 1
                self.panel.contentView?.needsDisplay = true
                self.panel.display()
            }
        }
    }
}

// MARK: - Глобальная горячая клавиша (по умолчанию ⌥Space)

enum HotKey {
    nonisolated(unsafe) static var onPress: (() -> Void)?
    nonisolated(unsafe) private static var ref: EventHotKeyRef?
    nonisolated(unsafe) private static var installed = false

    /// Регистрирует сочетание (старое снимается). Возвращает false, если оно уже занято другой программой.
    @discardableResult
    static func register(_ choice: HotKeyChoice) -> Bool {
        if !installed {
            installed = true
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                DispatchQueue.main.async { HotKey.onPress?() }
                return noErr
            }, 1, &spec, nil, nil)
        }
        if let ref { UnregisterEventHotKey(ref); self.ref = nil }
        let mods: Int
        switch choice {
        case .optSpace: mods = optionKey
        case .ctrlOptSpace: mods = controlKey | optionKey
        case .optShiftSpace: mods = optionKey | shiftKey
        case .cmdShiftSpace: mods = cmdKey | shiftKey
        }
        let id = EventHotKeyID(signature: OSType(0x4D49_534C), id: 1)
        return RegisterEventHotKey(UInt32(kVK_Space), UInt32(mods), id, GetApplicationEventTarget(), 0, &ref) == noErr
    }
}

// MARK: - Полноэкранный режим

enum FullScreenDetector {
    @_silgen_name("CGSMainConnectionID") private static func mainConnection() -> Int32
    @_silgen_name("CGSCopyManagedDisplaySpaces") private static func displaySpaces(_ cid: Int32) -> CFArray

    /// Открыта ли на этом экране программа на весь экран (текущий рабочий стол — полноэкранный).
    static func isFullScreen(on screen: NSScreen) -> Bool {
        guard let list = displaySpaces(mainConnection()) as? [[String: Any]] else { return false }
        var uuid = ""
        if let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
           let u = CGDisplayCreateUUIDFromDisplayID(n)?.takeRetainedValue() {
            uuid = CFUUIDCreateString(nil, u) as String? ?? ""
        }
        // «Main» — когда в настройках выключено «Отдельные рабочие столы на каждом мониторе»
        let d = list.first { ($0["Display Identifier"] as? String) == uuid }
            ?? list.first { ($0["Display Identifier"] as? String) == "Main" }
        let cur = d?["Current Space"] as? [String: Any]
        return (cur?["type"] as? Int) == 4
    }
}
