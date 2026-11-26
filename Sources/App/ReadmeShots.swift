import AppKit
import SwiftUI

/// `MacIsland --readme-shots <папка>` — картинки для README: остров на «обоях» с подставными данными.
/// Запускать с MACISLAND_SUPPORT_DIR и отдельным bundle id (см. scripts/readme-shots.sh),
/// чтобы не трогать настоящие заметки, буфер обмена и настройки.
@MainActor
enum ReadmeShots {
    static func run(to dir: String) {
        let out = URL(fileURLWithPath: dir, isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        let settings = AppSettings.shared
        settings.style = .black
        settings.showMusic = true
        settings.showWeather = true
        settings.showSystem = true
        settings.showNotes = true
        settings.showAssistant = true
        settings.notificationsEnabled = true
        settings.wingsMode = .always

        settings.weatherCity = "Lisbon"
        Weather.shared.debugSet(place: "Lisbon", temp: 21, code: 1, high: 24, low: 16)
        SystemMonitor.shared.setActive(true)
        NotesStore.shared.add("Buy oat milk")
        NotesStore.shared.add("Send the slides to Alex")
        NotesStore.shared.add("Book a table for Friday")

        let np = NowPlaying.shared
        np.debugSet(title: "Midnight Drive", artist: "Neon Coast", playing: true, position: 84, duration: 214)
        np.debugSetArtwork(cover(colors: [NSColor(red: 0.98, green: 0.36, blue: 0.55, alpha: 1),
                                          NSColor(red: 0.42, green: 0.25, blue: 0.95, alpha: 1)]))

        let state = IslandState()
        state.notch = CGSize(width: 200, height: 32)

        // 1. Компактный остров: обложка слева, время справа
        state.expanded = false
        state.wings = true
        shot(state, name: "compact", height: 80, to: out)

        // 2. Сообщение под чёлкой
        state.toast = Toast(icon: "battery.100percent.bolt", text: Lf("Charging · %d%%", 78))
        shot(state, name: "toast", height: 100, to: out)
        state.toast = nil

        // 3. Раскрытый: музыка + плитки
        state.expanded = true
        shot(state, name: "expanded", height: 420, to: out)

        // 4. Мониторинг системы
        state.widget = .system
        shot(state, name: "system", height: 520, to: out)
        state.widget = .weather
        shot(state, name: "weather", height: 520, to: out)
        state.widget = .notes
        shot(state, name: "notes", height: 520, to: out)
        state.widget = nil

        // 5. Видео и музыка одновременно
        let chrome = NSWorkspace.shared.icon(forFile: "/Applications/Google Chrome.app")
        let music = NSWorkspace.shared.icon(forFile: "/System/Applications/Music.app")
        np.debugSetPlayers([
            Player(id: 1, bundle: "com.google.Chrome", appName: "Google Chrome", appIcon: chrome, isVideo: true,
                   title: "How the Dynamic Island works", artist: "YouTube", playing: false, rate: 0,
                   duration: 900, elapsed: 312, stamp: Date(),
                   artwork: cover(colors: [NSColor(red: 0.1, green: 0.75, blue: 0.85, alpha: 1),
                                           NSColor(red: 0.1, green: 0.2, blue: 0.55, alpha: 1)])),
            Player(id: 2, bundle: "com.apple.Music", appName: "Music", appIcon: music, isVideo: false,
                   title: "Midnight Drive", artist: "Neon Coast", playing: true, rate: 1,
                   duration: 214, elapsed: 84, stamp: Date(), artwork: np.artwork),
        ])
        shot(state, name: "split", height: 420, to: out)
        np.debugSetPlayers([])

        // 6. Smart Clipboard
        let cb = ClipboardStore.shared
        cb.debugAdd(text: "https://github.com/")
        cb.debugAdd(text: "Meeting notes: ship v0.1 on Friday, collect feedback, then plan plugins.")
        cb.debugAdd(text: "¿A qué hora sale el próximo tren a Oporto?")
        if let id = cb.texts.first?.id {
            Translator.shared.debugSet(result: "What time does the next train to Porto leave?", for: id)
        }
        if let png = fakeScreenshot() { cb.debugAdd(image: png, screenshot: true) }
        state.showClipboard = true
        shot(state, name: "clipboard", height: 760, to: out)
        state.showClipboard = false
        // 7. Pomodoro, таймер и уведомления
        PomodoroModel.shared.debugSet(phase: .focus, progress: 0.35, running: true, completed: 2)
        Timers.shared.start(seconds: 300)
        NotificationWatcher.shared.debugAdd(app: "Mail", title: "Design review", body: "Moved to 3 pm, same room")
        NotificationWatcher.shared.debugAdd(app: "Messages", title: "Alex", body: "Are we still on for 7?")
        shot(state, name: "focus", height: 760, to: out)

        // Значок приложения (1024×1024)
        if let tiff = appIcon().tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
            try? rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent("icon.png"))
        }

        // 8. Окно настроек
        settingsShot(.general, name: "settings", to: out)
        settingsShot(.music, name: "settings-music", to: out)

    }

    // MARK: Отрисовка

    private static let width: CGFloat = 720

    private static func shot(_ state: IslandState, name: String, height: CGFloat, to out: URL) {
        let root = ZStack(alignment: .top) {
            Wallpaper()
            MenuBar(notch: state.notch)
            IslandView(state: state)
        }
        .frame(width: width, height: height)
        let host = NSHostingView(rootView: root)
        let w = NSWindow(contentRect: NSRect(x: -4000, y: 0, width: width, height: height),
                         styleMask: [.borderless], backing: .buffered, defer: false)
        w.contentView = host
        w.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(1.4))
        // Обрезаем по высоте острова (+ поля), чтобы не было пустых обоев снизу
        let islandH = state.size.height
        let h = min(height, max(islandH + 48, 72))
        w.setContentSize(NSSize(width: width, height: h))
        host.frame = NSRect(x: 0, y: 0, width: width, height: h)
        host.rootView = ZStack(alignment: .top) {
            Wallpaper()
            MenuBar(notch: state.notch)
            IslandView(state: state)
        }
        .frame(width: width, height: h)
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent(name + ".png"))
        }
        w.orderOut(nil)
    }

    private static func settingsShot(_ tab: SettingsTab, name: String, to out: URL) {
        NSApp.setActivationPolicy(.regular)
        let tabs = SettingsTabState()
        tabs.tab = tab
        let host = NSHostingView(rootView: SettingsView(tabs: tabs))
        let w = NSWindow(contentRect: NSRect(x: -3000, y: 0, width: 760, height: 540),
                         styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.contentView = host
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent(name + ".png"))
        }
        w.orderOut(nil)
    }

    /// Значок: фиолетово-синий квадрат, сверху чёрный «остров» с обложкой и эквалайзером.
    static func appIcon() -> NSImage {
        NSImage(size: NSSize(width: 1024, height: 1024), flipped: true) { _ in
            let body = NSRect(x: 100, y: 100, width: 824, height: 824)
            let shape = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
            NSGraphicsContext.saveGraphicsState()
            shape.addClip()
            NSGradient(colors: [NSColor(red: 0.55, green: 0.36, blue: 1.0, alpha: 1),
                                NSColor(red: 0.20, green: 0.30, blue: 0.85, alpha: 1),
                                NSColor(red: 0.08, green: 0.55, blue: 0.85, alpha: 1)])?.draw(in: body, angle: -60)
            NSColor.white.withAlphaComponent(0.10).setFill()
            NSBezierPath(ovalIn: NSRect(x: 420, y: 520, width: 640, height: 640)).fill()
            NSGraphicsContext.restoreGraphicsState()
            // Остров
            let island = NSRect(x: 232, y: 300, width: 560, height: 170)
            NSColor.black.setFill()
            NSBezierPath(roundedRect: island, xRadius: 85, yRadius: 85).fill()
            // Обложка
            let art = NSRect(x: 282, y: 335, width: 100, height: 100)
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: art, xRadius: 26, yRadius: 26).addClip()
            NSGradient(colors: [NSColor(red: 0.98, green: 0.36, blue: 0.55, alpha: 1),
                                NSColor(red: 0.45, green: 0.28, blue: 0.98, alpha: 1)])?.draw(in: art, angle: -60)
            NSGraphicsContext.restoreGraphicsState()
            // Эквалайзер
            NSColor(red: 0.66, green: 0.56, blue: 1.0, alpha: 1).setFill()
            for (i, h) in [46.0, 84, 60, 96, 52].enumerated() {
                let x = 600 + Double(i) * 30
                NSBezierPath(roundedRect: NSRect(x: x, y: 385 - h / 2, width: 16, height: h), xRadius: 8, yRadius: 8).fill()
            }
            // Подсказка на «раскрытие»: три полоски ниже
            NSColor.white.withAlphaComponent(0.85).setFill()
            NSBezierPath(roundedRect: NSRect(x: 292, y: 560, width: 440, height: 46), xRadius: 23, yRadius: 23).fill()
            NSColor.white.withAlphaComponent(0.45).setFill()
            NSBezierPath(roundedRect: NSRect(x: 292, y: 640, width: 320, height: 46), xRadius: 23, yRadius: 23).fill()
            NSColor.white.withAlphaComponent(0.25).setFill()
            NSBezierPath(roundedRect: NSRect(x: 292, y: 720, width: 380, height: 46), xRadius: 23, yRadius: 23).fill()
            return true
        }
    }

    private static func cover(colors: [NSColor]) -> NSImage {
        NSImage(size: NSSize(width: 300, height: 300), flipped: false) { r in
            NSGradient(colors: colors)?.draw(in: r, angle: -55)
            NSColor.white.withAlphaComponent(0.18).setFill()
            NSBezierPath(ovalIn: NSRect(x: 150, y: 140, width: 210, height: 210)).fill()
            NSColor.black.withAlphaComponent(0.18).setFill()
            NSBezierPath(ovalIn: NSRect(x: -60, y: -80, width: 240, height: 240)).fill()
            return true
        }
    }

    private static func fakeScreenshot() -> Data? {
        let img = NSImage(size: NSSize(width: 640, height: 400), flipped: false) { r in
            NSGradient(colors: [NSColor(red: 0.2, green: 0.3, blue: 0.7, alpha: 1),
                                NSColor(red: 0.55, green: 0.3, blue: 0.75, alpha: 1)])?.draw(in: r, angle: -30)
            NSColor(white: 0.97, alpha: 1).setFill()
            NSBezierPath(roundedRect: NSRect(x: 90, y: 60, width: 460, height: 280), xRadius: 14, yRadius: 14).fill()
            NSColor(white: 0.85, alpha: 1).setFill()
            for i in 0..<5 { NSBezierPath(roundedRect: NSRect(x: 120, y: 260 - i * 38, width: 300 - i * 30, height: 14), xRadius: 7, yRadius: 7).fill() }
            return true
        }
        guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

/// «Обои» за островом.
private struct Wallpaper: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.16, green: 0.12, blue: 0.38), Color(red: 0.05, green: 0.22, blue: 0.36)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Circle().fill(Color(red: 0.62, green: 0.32, blue: 0.95).opacity(0.55)).frame(width: 420).blur(radius: 90).offset(x: -230, y: 60)
            Circle().fill(Color(red: 0.1, green: 0.65, blue: 0.85).opacity(0.45)).frame(width: 380).blur(radius: 90).offset(x: 250, y: 160)
        }
    }
}

/// Строка меню с чёлкой посередине.
private struct MenuBar: View {
    let notch: CGSize
    var body: some View {
        HStack(spacing: 18) {
            Image(systemName: "apple.logo").font(.system(size: 13, weight: .semibold))
            Text("Finder").fontWeight(.bold)
            Text("File"); Text("Edit"); Text("View")
            Spacer()
            Image(systemName: "wifi"); Image(systemName: "battery.75percent")
            Text("Wed 21:40")
        }
        .font(.system(size: 13))
        .foregroundStyle(.white.opacity(0.92))
        .padding(.horizontal, 16)
        .frame(height: notch.height)
        .background(Color.black.opacity(0.22))
    }
}
