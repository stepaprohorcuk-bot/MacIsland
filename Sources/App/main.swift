import AppKit
import ServiceManagement
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var island: IslandController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installEditMenu()
        Battery.shared.start()
        NowPlaying.shared.start()
        VoiceCommands.shared.setup()
        ClipboardStore.shared.start()
        NotificationWatcher.shared.start()
        Devices.shared.start()
        DownloadsWatcher.shared.start()
        Weather.shared.start()
        AppIndex.shared.refreshIfNeeded()
        let c = IslandController()
        c.setup()
        island = c
        LoginItem.shared.enableOnFirstLaunch()
    }

    /// Повторный запуск из Finder/Launchpad — открываем настройки (иначе непонятно, что приложение работает).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SettingsWindow.shared.show()
        return true
    }

    /// Без меню «Правка» в приложении-без-Dock не работают ⌘C / ⌘V в полях ввода.
    private func installEditMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: L("Settings…"), action: #selector(openSettings), keyEquivalent: ",")
        appMenu.addItem(withTitle: Lf("Quit %@", AppInfo.name), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: L("Edit"))
        edit.addItem(withTitle: L("Undo"), action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: L("Redo"), action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: L("Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: L("Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: L("Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: L("Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    @objc private func openSettings() { SettingsWindow.shared.show() }
}

/// `MacIsland --snapshot out.png` — офлайн-рендер острова (для проверки вида без экрана).
@MainActor
func renderSnapshot(to path: String) {
    let state = IslandState()
    state.notch = CGSize(width: 185, height: 32)
    var images: [NSImage] = []

    func render(_ height: CGFloat) {
        let view = IslandView(state: state)
            .frame(width: 560, height: height)
            .background(LinearGradient(colors: [Color(red: 0.25, green: 0.2, blue: 0.5), Color(red: 0.1, green: 0.3, blue: 0.4)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing))
        let r = ImageRenderer(content: view)
        r.scale = 2
        if let img = r.nsImage { images.append(img) }
    }

    // 1. Только музыка — самый частый случай
    state.expanded = true
    NowPlaying.shared.debugSet(title: "Good Luck, Babe!", artist: "Chappell Roan", playing: true, position: 84, duration: 214)
    SystemMonitor.shared.setActive(true)
    state.widget = .system
    state.contentHeight = 330
    render(350)
    state.widget = nil
    // 1б. Видео и музыка одновременно — карточка пополам
    let chrome = NSWorkspace.shared.icon(forFile: "/Applications/Google Chrome.app")
    let music = NSWorkspace.shared.icon(forFile: "/System/Applications/Music.app")
    NowPlaying.shared.debugSetPlayers([
        Player(id: 1, bundle: "com.google.Chrome", appName: "Google Chrome", appIcon: chrome, isVideo: true,
               title: "Как устроен Dynamic Island", artist: "YouTube", playing: false, rate: 0,
               duration: 900, elapsed: 312, stamp: Date(), artwork: nil),
        Player(id: 2, bundle: "ru.yandex.desktop.music", appName: "Яндекс Музыка", appIcon: music, isVideo: false,
               title: "Good Luck, Babe!", artist: "Chappell Roan", playing: true, rate: 1,
               duration: 214, elapsed: 84, stamp: Date(), artwork: nil),
    ])
    state.contentHeight = 200
    render(220)
    NowPlaying.shared.debugSetPlayers([])
    // 2. Музыка + Pomodoro + таймер + буфер обмена
    PomodoroModel.shared.debugSet(phase: .focus, progress: 0.35, running: true, completed: 2)
    Timers.shared.start(seconds: 300)
    AppSettings.shared.notificationsEnabled = true
    NotificationWatcher.shared.debugAdd(app: "Telegram", title: "Анна → Luna_Y2k", body: "Туз")
    NotificationWatcher.shared.debugAdd(app: "Почта", title: "Встреча завтра", body: "Не забудь про созвон в 10:00")
    NotificationWatcher.shared.debugAdd(app: "Telegram", title: "Анна → Luna_Y2k", body: "Тебе")
    state.contentHeight = 470
    render(490)
    // 3. Свёрнутый + сообщение
    state.expanded = false
    state.wings = true
    render(60)
    state.toast = Toast(icon: "battery.100percent.bolt", text: Lf("Charging · %d%%", 78))
    render(80)

    let w = images.map(\.size.width).max() ?? 0
    let h = images.map(\.size.height).reduce(0, +)
    let out = NSImage(size: NSSize(width: w, height: h))
    out.lockFocus()
    var y = h
    for img in images { y -= img.size.height; img.draw(at: NSPoint(x: 0, y: y), from: .zero, operation: .copy, fraction: 1) }
    out.unlockFocus()
    if let tiff = out.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
       let png = rep.representation(using: .png, properties: [:]) {
        try? png.write(to: URL(fileURLWithPath: path))
    }
}

MainActor.assumeIsolated {
    let args = CommandLine.arguments
    if args.contains("--login-status") {
        print("login item status:", SMAppService.mainApp.status.rawValue)
        exit(0)
    }
    if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
        renderSnapshot(to: args[i + 1])
        exit(0)
    }
    if let i = args.firstIndex(of: "--readme-shots"), i + 1 < args.count {
        ReadmeShots.run(to: args[i + 1])
        exit(0)
    }
    if let i = args.firstIndex(of: "--settings-snapshot"), i + 2 < args.count {
        // Офлайн-рендер окна настроек: --settings-snapshot out.png ai
        let state = SettingsTabState()
        state.tab = SettingsTab(rawValue: args[i + 2]) ?? .general
        let host = NSHostingView(rootView: SettingsView(tabs: state))
        let w = NSWindow(contentRect: NSRect(x: -3000, y: 0, width: 760, height: 540),
                         styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.contentView = host
        w.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(1.2))
        if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[i + 1]))
        }
        exit(0)
    }
    if let i = args.firstIndex(of: "--aquarium"), i + 1 < args.count {
        // Кадры аквариума: строки — уровень воды, столбцы — моменты вокруг удара капли
        let progresses: [Double] = [0.1, 0.5, 0.95]
        let t0 = 1000.0 * Aquarium.dropPeriod
        let times: [Double] = [-0.3, 0.25, 0.45, 0.55, 0.7, 1.0]
        let grid = VStack(spacing: 6) {
            ForEach(progresses, id: \.self) { p in
                HStack(spacing: 6) {
                    ForEach(times, id: \.self) { dt in
                        Canvas { ctx, sz in
                            Aquarium.draw(in: &ctx, size: sz, t: t0 + dt, progress: p, running: true, sinceToggle: 100,
                                          palette: .focus, backdrop: nil)
                        }
                        .frame(width: 160, height: 160)
                    }
                }
            }
        }
        .padding(8).background(Color.black)
        let r = ImageRenderer(content: grid)
        r.scale = 2
        if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[i + 1]))
        }
        exit(0)
    }
    if let i = args.firstIndex(of: "--parse"), i + 1 < args.count {
        let q = args[i + 1]
        print("timer:", Timers.parse(q).map { "\($0)s" } ?? "-", " calc:", Calculator.evaluate(q).map { Calculator.format($0) } ?? "-",
              " voice:", VoiceCommands.parse(q).map { "\($0)" } ?? "-", " apple:", AppleAI.canAnswer(q))
        AppIndex.shared.buildNow()
        print("  apps:", AppIndex.shared.search(q).map(\.name), " open-cmd:", AppIndex.isOpenCommand(q))
        exit(0)
    }

    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
