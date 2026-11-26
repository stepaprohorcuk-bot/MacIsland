import AppKit
import SwiftUI

/// Разделы настроек — список слева, как в «Системных настройках» Mac.
enum SettingsTab: String, CaseIterable, Identifiable {
    case general, widgets, music, timers, clipboard, notifications, battery, ai, about
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return L("General")
        case .widgets: return L("Widgets")
        case .music: return L("Music & Voice")
        case .timers: return L("Timers & Pomodoro")
        case .clipboard: return L("Clipboard & Translation")
        case .notifications: return L("Notifications")
        case .battery: return L("Battery")
        case .ai: return L("AI")
        case .about: return L("About")
        }
    }
    var symbol: String {
        switch self {
        case .general: return "gearshape.fill"
        case .widgets: return "square.grid.2x2.fill"
        case .music: return "music.note"
        case .timers: return "timer"
        case .clipboard: return "doc.on.clipboard.fill"
        case .notifications: return "bell.badge.fill"
        case .battery: return "battery.100percent"
        case .ai: return "sparkles"
        case .about: return "info.circle.fill"
        }
    }
    var color: Color {
        switch self {
        case .general: return .gray
        case .widgets: return .teal
        case .music: return .pink
        case .timers: return .orange
        case .clipboard: return .blue
        case .notifications: return .red
        case .battery: return .green
        case .ai: return .purple
        case .about: return .gray
        }
    }
}

@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {
    static let shared = SettingsWindow()
    private var window: NSWindow?
    private let tabState = SettingsTabState()

    func show(tab: SettingsTab? = nil) {
        if let tab { tabState.tab = tab }
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 540),
                             styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = Lf("%@ Settings", AppInfo.name)
            w.titlebarAppearsTransparent = true
            w.toolbarStyle = .unified
            w.isReleasedWhenClosed = false
            w.contentViewController = NSHostingController(rootView: SettingsView(tabs: tabState))
            w.setContentSize(NSSize(width: 760, height: 540))
            w.center()
            w.delegate = self
            window = w
        }
        NSApp.setActivationPolicy(.regular)        // окно ведёт себя как обычное (Dock, ⌘Tab)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

@MainActor
final class SettingsTabState: ObservableObject {
    @Published var tab: SettingsTab = .general
}

struct SettingsView: View {
    @ObservedObject var tabs: SettingsTabState

    var body: some View {
        NavigationSplitView {
            List(SettingsTab.allCases, selection: Binding<SettingsTab?>(get: { tabs.tab }, set: { if let t = $0 { tabs.tab = t } })) { t in
                Label {
                    Text(t.title)
                } icon: {
                    Image(systemName: t.symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(t.color.gradient))
                }
                .tag(t)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 240, ideal: 250, max: 300)
            .frame(minWidth: 240)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            detail
                .navigationTitle(tabs.tab.title)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(minWidth: 760, minHeight: 540)
    }

    @ViewBuilder private var detail: some View {
        switch tabs.tab {
        case .general: GeneralSettings()
        case .widgets: WidgetSettings()
        case .music: MusicSettings()
        case .timers: PomodoroSettings()
        case .clipboard: ClipboardSettings()
        case .notifications: NotificationSettings()
        case .battery: BatterySettings()
        case .ai: AISettings()
        case .about: AboutSettings()
        }
    }
}

/// Пояснение под настройкой — мелким серым, как в системных настройках.
struct Hint: View {
    let text: LocalizedStringKey
    init(_ text: LocalizedStringKey) { self.text = text }
    var body: some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

struct GeneralSettings: View {
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var login = LoginItem.shared

    var body: some View {
        Form {
            Section {
                Picker("Island style", selection: $settings.style) {
                    ForEach(IslandStyle.allCases) { Text($0.title).tag($0) }
                }
                if settings.style == .glass, ProcessInfo.processInfo.operatingSystemVersion.majorVersion < 26 {
                    Hint("Real Liquid Glass needs macOS 26. On this Mac a frosted-glass look is used instead.")
                }
                Toggle("Expand on hover", isOn: $settings.expandOnHover)
                Hint("When off, click the notch to open the island.")
                Picker("Side parts of the island", selection: $settings.wingsMode) {
                    ForEach(WingsMode.allCases) { Text($0.title).tag($0) }
                }
                Hint("Automatic: the cover on the left and the time on the right hide when an app's menus or menu bar icons are next to the notch. Needs Accessibility permission; without it the left part stays hidden.")
                Picker("In full-screen apps", selection: $settings.fullScreen) {
                    ForEach(FullScreenMode.allCases) { Text($0.title).tag($0) }
                }
                Hint("When hidden, the island doesn't cover videos and games. The hotkey still opens it.")
            }
            Section {
                Toggle("Open at login", isOn: Binding(get: { login.enabled }, set: { login.set($0) }))
                Picker("Island hotkey", selection: $settings.hotkey) {
                    ForEach(HotKeyChoice.allCases) { Text($0.title).tag($0) }
                }
                Hint("Opens the island with the cursor in the question field.")
                Toggle("Ask AI", isOn: $settings.showAssistant)
                Hint("When off, the field still works as a calculator and for timers (“5 min”).")
            }
        }
        .formStyle(.grouped)
    }
}

struct WidgetSettings: View {
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var weather = Weather.shared

    var body: some View {
        Form {
            Section {
                Hint("A row of small tiles under the notch. Click a tile to open details; click again to close.")
            }
            Section("Weather") {
                Toggle("Show weather", isOn: $settings.showWeather)
                TextField("City", text: $settings.weatherCity, prompt: Text("For example, Moscow"))
                if !weather.place.isEmpty {
                    LabeledContent("Found", value: "\(weather.place) · \(Weather.deg(weather.temp))")
                } else if let e = weather.error {
                    Text(e).font(.caption).foregroundStyle(.red)
                }
                Hint("Weather comes from Open-Meteo — free and without registration. Only the city name and its coordinates are sent.")
            }
            Section("System") {
                Toggle("CPU, memory and disk", isOn: $settings.showSystem)
                Hint("Updated only while the island is open.")
                Toggle("Microphone and camera indicator", isOn: $settings.showDeviceIndicator)
                Hint("An orange (microphone) or green (camera) dot next to the notch when another app uses them.")
            }
            Section("Other") {
                Toggle("Quick notes and tasks", isOn: $settings.showNotes)
                Toggle("Downloads", isOn: $settings.showDownloads)
                Hint("Shows progress, speed and time left for downloads in Safari, Chrome, Yandex Browser, Edge, Arc and Firefox. macOS will ask for access to the Downloads folder once.")
                Toggle("Quick launch", isOn: $settings.quickLaunch)
                Hint("Type an app name in the island's field — matching apps appear above it. “Open Telegram” + Enter launches it.")
            }
        }
        .formStyle(.grouped)
    }
}

struct MusicSettings: View {
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var voice = VoiceCommands.shared

    var body: some View {
        Form {
            Section {
                Toggle("Show music in the island", isOn: $settings.showMusic)
                Hint("Works with any player that shows up in Control Center: Apple Music, Spotify, Yandex Music, YouTube in a browser and others.")
            }
            Section("Voice control") {
                Toggle("Voice control for music", isOn: $voice.enabled)
                Hint("Say “next” or “next track”, “back” or “previous track”, “pause” (pauses and resumes), “resume” or “play music” (only resumes), “stop the music” (only pauses). Works for music and videos. Speech is recognised on this Mac, nothing is sent online. macOS shows the orange microphone dot while listening.")
                if voice.status == .denied {
                    Button("Open Privacy settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition")!)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct PomodoroSettings: View {
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var bg = BackgroundStore.shared

    var body: some View {
        Form {
            Section {
                Hint("Type “5 min”, “1:30” or “timer 20” in the island's field, or use the Timer button. Several timers can run at once.")
            }
            Section("Pomodoro") {
                Stepper(value: $settings.focusMinutes, in: 5...120, step: 5) {
                    LabeledContent("Focus", value: Lf("%d min", settings.focusMinutes))
                }
                Stepper(value: $settings.breakMinutes, in: 1...30) {
                    LabeledContent("Break", value: Lf("%d min", settings.breakMinutes))
                }
                Stepper(value: $settings.longBreakMinutes, in: 5...60, step: 5) {
                    LabeledContent("Long break (every 4th)", value: Lf("%d min", settings.longBreakMinutes))
                }
                HStack {
                    Text("Aquarium background")
                    Spacer()
                    Image(nsImage: bg.image).resizable().frame(width: 30, height: 30).clipShape(Circle())
                    Button("Choose…") { bg.choose() }
                    Button("Reset") { bg.reset() }.disabled(!bg.hasCustom)
                }
                Hint("You can also drag a picture onto the aquarium in the island.")
            }
        }
        .formStyle(.grouped)
    }
}

struct ClipboardSettings: View {
    @ObservedObject var settings = AppSettings.shared
    @State private var confirmClear = false

    var body: some View {
        Form {
            Section {
                Toggle("Remember copied text and images", isOn: $settings.clipboardEnabled)
                Hint("History is stored only on this Mac. Passwords from password managers are never saved.")
                Toggle("Add screenshots automatically", isOn: $settings.clipboardScreenshots)
                Hint("New screenshots appear as thumbnails — drag them straight into Telegram, a browser or an editor.")
                Toggle("Show “Copied” in the notch", isOn: $settings.clipboardToast)
            }
            Section("Limits") {
                Stepper(value: $settings.clipboardTextLimit, in: 3...50) {
                    LabeledContent("Text items", value: "\(settings.clipboardTextLimit)")
                }
                Stepper(value: $settings.clipboardImageLimit, in: 1...20) {
                    LabeledContent("Images", value: "\(settings.clipboardImageLimit)")
                }
                Hint("When the limit is reached, the oldest unpinned items are removed.")
                Button("Clear entire history…", role: .destructive) { confirmClear = true }
                    .confirmationDialog(L("Clear the whole clipboard history, including pinned items?"), isPresented: $confirmClear) {
                        Button(L("Clear"), role: .destructive) { ClipboardStore.shared.clear(includingPinned: true) }
                    }
            }
            Section("Translation") {
                Picker("Translate into", selection: $settings.translateTarget) {
                    Text("Automatic").tag("auto")
                    ForEach(Translator.languages, id: \.code) { Text($0.name).tag($0.code) }
                }
                Hint("Automatic: into your system language, and text already in your language — into English. Uses the translator built into macOS; languages download once and then work offline.")
                if !Translator.isAvailable {
                    Hint("Built-in translation needs macOS 15. On this Mac, Google Translate opens in the browser.")
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct NotificationSettings: View {
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var watcher = NotificationWatcher.shared

    var body: some View {
        Form {
            Section {
                Toggle("Show notifications from other apps", isOn: Binding(
                    get: { settings.notificationsEnabled },
                    set: { on in
                        settings.notificationsEnabled = on
                        if on && !watcher.trusted { watcher.requestAccess() }
                    }))
                Hint("macOS has no official way for apps to read other apps' notifications, so MacIsland reads the system banners using Accessibility. It needs your permission and may stop working after a macOS update.")
            }
            Section("Permission") {
                LabeledContent("Accessibility") {
                    Text(watcher.trusted ? L("Allowed") : L("Not allowed"))
                        .foregroundStyle(watcher.trusted ? .green : .secondary)
                }
                if !watcher.trusted {
                    Button("Open Accessibility settings") { watcher.openAccessibilitySettings() }
                    Hint("Turn on MacIsland in the list. If it's already on but still shows “Not allowed”, remove it with “–” and add it again.")
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct BatterySettings: View {
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var battery = Battery.shared

    var body: some View {
        Form {
            Section {
                Toggle("Show battery", isOn: $settings.showBattery)
                Hint("Charge level in the island, alerts when you plug in, unplug or run low.")
            }
            if battery.hasBattery {
                Section {
                    LabeledContent("Charge", value: "\(battery.level)%")
                    LabeledContent("Power", value: battery.charging ? L("Charging") : (battery.pluggedIn ? L("Plugged in") : L("On battery")))
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct AIPreset: Identifiable {
    let id: String
    let base: String
    let model: String
    let keysURL: String?
    static let all = [
        AIPreset(id: "OpenRouter", base: "https://openrouter.ai/api/v1", model: "openai/gpt-4o-mini", keysURL: "https://openrouter.ai/keys"),
        AIPreset(id: "OpenAI", base: "https://api.openai.com/v1", model: "gpt-4o-mini", keysURL: "https://platform.openai.com/api-keys"),
        AIPreset(id: "Groq", base: "https://api.groq.com/openai/v1", model: "llama-3.3-70b-versatile", keysURL: "https://console.groq.com/keys"),
        AIPreset(id: "Ollama", base: "http://localhost:11434/v1", model: "qwen3:8b", keysURL: nil),
    ]
}

struct AISettings: View {
    @ObservedObject var settings = AppSettings.shared
    @State private var draft = ""
    @State private var hasKey = APIKey.load() != nil

    var body: some View {
        Form {
            Section {
                Picker("Who answers", selection: $settings.aiMode) {
                    ForEach(AIMode.allCases) { Text($0.title).tag($0) }
                }
                Hint("Automatic: Apple Intelligence answers when it's on and knows the language of the question; otherwise your API below is used.")
                LabeledContent("Apple Intelligence") {
                    Text(AppleAI.isAvailable ? L("Ready") : L("Not available"))
                        .foregroundStyle(AppleAI.isAvailable ? .green : .secondary)
                }
                if !AppleAI.isAvailable {
                    Text(AppleAI.whyNot("hello")).font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Your API (OpenAI-compatible)") {
                LabeledContent("Preset") {
                    HStack(spacing: 6) {
                        ForEach(AIPreset.all) { p in
                            Button(p.id) { settings.apiBase = p.base; settings.apiModel = p.model }
                                .controlSize(.small)
                        }
                    }
                }
                TextField("Address", text: $settings.apiBase)
                TextField("Model", text: $settings.apiModel)
                LabeledContent("API key") {
                    HStack {
                        SecureField(hasKey ? L("Key saved — paste a new one to replace") : L("Paste key"), text: $draft)
                            .labelsHidden()
                            .frame(minWidth: 240)
                        Button("Save") { APIKey.save(draft.trimmingCharacters(in: .whitespacesAndNewlines)); draft = ""; hasKey = true }
                            .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                        if hasKey { Button("Delete") { APIKey.delete(); hasKey = false } }
                    }
                }
                if let url = AIPreset.all.first(where: { $0.base == settings.apiBase })?.keysURL {
                    Link(L("Get a key"), destination: URL(string: url)!).font(.caption)
                }
                Hint("The key is stored in this Mac's Keychain. Ollama runs models locally and needs no key.")
            }
        }
        .formStyle(.grouped)
    }
}

struct AboutSettings: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 72, height: 72)
            Text(AppInfo.name).font(.title2.bold())
            Text(Lf("Version %@", Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"))
                .foregroundStyle(.secondary)
            Text("A Dynamic Island for the MacBook notch: music, timers, Pomodoro, battery and a quick AI field.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
                .frame(maxWidth: 380)
            Button("Quit \(AppInfo.name)") { NSApp.terminate(nil) }
                .padding(.top, 8)
        }
        .padding(.top, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
