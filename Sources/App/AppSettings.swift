import Foundation
import SwiftUI

/// Перевод строки из Localizable.strings (en — базовый, ru — перевод).
func L(_ key: String) -> String { NSLocalizedString(key, comment: "") }
func Lf(_ key: String, _ args: CVarArg...) -> String { String(format: L(key), arguments: args) }

enum AppInfo {
    static let name = "MacIsland"
    static let supportDir: URL = {
        // MACISLAND_SUPPORT_DIR — отдельная папка данных (для снимков README, чтобы не трогать настоящие)
        let d = ProcessInfo.processInfo.environment["MACISLAND_SUPPORT_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()
}

enum IslandStyle: String, CaseIterable, Identifiable {
    case glass, black
    var id: String { rawValue }
    var title: String { self == .glass ? L("Liquid Glass") : L("Black") }
}

/// Боковые части свёрнутого острова (обложка слева, время справа).
enum WingsMode: String, CaseIterable, Identifiable {
    case auto, always, never
    var id: String { rawValue }
    var title: String {
        switch self {
        case .auto: return L("Automatic")
        case .always: return L("Always")
        case .never: return L("Never")
        }
    }
}

/// Горячая клавиша острова: нажать — открыть и спросить, удерживать — голосовая команда.
enum HotKeyChoice: String, CaseIterable, Identifiable {
    case optSpace, ctrlOptSpace, optShiftSpace, cmdShiftSpace
    var id: String { rawValue }
    var title: String {
        switch self {
        case .optSpace: return "⌥ Space"
        case .ctrlOptSpace: return "⌃⌥ Space"
        case .optShiftSpace: return "⌥⇧ Space"
        case .cmdShiftSpace: return "⌘⇧ Space"
        }
    }
}

/// Что делать с островом, когда программа открыта на весь экран.
enum FullScreenMode: String, CaseIterable, Identifiable {
    case show, hide
    var id: String { rawValue }
    var title: String { self == .show ? L("Show the island") : L("Hide the island") }
}

enum AIMode: String, CaseIterable, Identifiable {
    case auto, apple, custom
    var id: String { rawValue }
    var title: String {
        switch self {
        case .auto: return L("Automatic")
        case .apple: return L("Apple Intelligence only")
        case .custom: return L("My API only")
        }
    }
}

/// Все настройки приложения (UserDefaults). Ключ API — отдельно, в Связке ключей.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let d = UserDefaults.standard

    @Published var style: IslandStyle { didSet { d.set(style.rawValue, forKey: "style") } }
    @Published var expandOnHover: Bool { didSet { d.set(expandOnHover, forKey: "expandOnHover") } }
    @Published var wingsMode: WingsMode { didSet { d.set(wingsMode.rawValue, forKey: "wingsMode") } }
    @Published var showMusic: Bool { didSet { d.set(showMusic, forKey: "showMusic") } }
    @Published var showBattery: Bool { didSet { d.set(showBattery, forKey: "showBattery") } }
    @Published var showAssistant: Bool { didSet { d.set(showAssistant, forKey: "showAssistant") } }
    @Published var hotkey: HotKeyChoice { didSet { d.set(hotkey.rawValue, forKey: "hotkey") } }
    @Published var fullScreen: FullScreenMode { didSet { d.set(fullScreen.rawValue, forKey: "fullScreen") } }

    @Published var focusMinutes: Int { didSet { d.set(focusMinutes, forKey: "focusMinutes") } }
    @Published var breakMinutes: Int { didSet { d.set(breakMinutes, forKey: "breakMinutes") } }
    @Published var longBreakMinutes: Int { didSet { d.set(longBreakMinutes, forKey: "longBreakMinutes") } }

    @Published var clipboardEnabled: Bool { didSet { d.set(clipboardEnabled, forKey: "clipboardEnabled") } }
    @Published var clipboardTextLimit: Int { didSet { d.set(clipboardTextLimit, forKey: "clipboardTextLimit") } }
    @Published var clipboardImageLimit: Int { didSet { d.set(clipboardImageLimit, forKey: "clipboardImageLimit") } }
    @Published var clipboardScreenshots: Bool { didSet { d.set(clipboardScreenshots, forKey: "clipboardScreenshots") } }
    @Published var clipboardToast: Bool { didSet { d.set(clipboardToast, forKey: "clipboardToast") } }
    /// Язык перевода: "auto" — язык системы (а текст на языке системы — на английский).
    @Published var translateTarget: String { didSet { d.set(translateTarget, forKey: "translateTarget") } }
    @Published var notificationsEnabled: Bool { didSet { d.set(notificationsEnabled, forKey: "notificationsEnabled") } }

    // Виджеты
    @Published var showWeather: Bool { didSet { d.set(showWeather, forKey: "showWeather") } }
    @Published var weatherCity: String { didSet { d.set(weatherCity, forKey: "weatherCity") } }
    @Published var showSystem: Bool { didSet { d.set(showSystem, forKey: "showSystem") } }
    @Published var showNotes: Bool { didSet { d.set(showNotes, forKey: "showNotes") } }
    @Published var showDownloads: Bool { didSet { d.set(showDownloads, forKey: "showDownloads") } }
    @Published var showDeviceIndicator: Bool { didSet { d.set(showDeviceIndicator, forKey: "showDeviceIndicator") } }
    @Published var quickLaunch: Bool { didSet { d.set(quickLaunch, forKey: "quickLaunch") } }

    @Published var aiMode: AIMode { didSet { d.set(aiMode.rawValue, forKey: "aiMode") } }
    @Published var apiBase: String { didSet { d.set(apiBase, forKey: "apiBase") } }
    @Published var apiModel: String { didSet { d.set(apiModel, forKey: "apiModel") } }

    private init() {
        style = IslandStyle(rawValue: d.string(forKey: "style") ?? "") ?? .glass
        expandOnHover = d.object(forKey: "expandOnHover") as? Bool ?? true
        wingsMode = WingsMode(rawValue: d.string(forKey: "wingsMode") ?? "") ?? .auto
        showMusic = d.object(forKey: "showMusic") as? Bool ?? true
        showBattery = d.object(forKey: "showBattery") as? Bool ?? true
        showAssistant = d.object(forKey: "showAssistant") as? Bool ?? true
        hotkey = HotKeyChoice(rawValue: d.string(forKey: "hotkey") ?? "") ?? .optSpace
        fullScreen = FullScreenMode(rawValue: d.string(forKey: "fullScreen") ?? "") ?? .show
        focusMinutes = d.object(forKey: "focusMinutes") as? Int ?? 25
        breakMinutes = d.object(forKey: "breakMinutes") as? Int ?? 5
        longBreakMinutes = d.object(forKey: "longBreakMinutes") as? Int ?? 15
        clipboardEnabled = d.object(forKey: "clipboardEnabled") as? Bool ?? true
        clipboardTextLimit = d.object(forKey: "clipboardTextLimit") as? Int ?? 10
        clipboardImageLimit = d.object(forKey: "clipboardImageLimit") as? Int ?? 5
        clipboardScreenshots = d.object(forKey: "clipboardScreenshots") as? Bool ?? true
        clipboardToast = d.object(forKey: "clipboardToast") as? Bool ?? true
        translateTarget = d.string(forKey: "translateTarget") ?? "auto"
        notificationsEnabled = d.object(forKey: "notificationsEnabled") as? Bool ?? false
        showWeather = d.object(forKey: "showWeather") as? Bool ?? true
        weatherCity = d.string(forKey: "weatherCity") ?? ""
        showSystem = d.object(forKey: "showSystem") as? Bool ?? true
        showNotes = d.object(forKey: "showNotes") as? Bool ?? true
        showDownloads = d.object(forKey: "showDownloads") as? Bool ?? true
        showDeviceIndicator = d.object(forKey: "showDeviceIndicator") as? Bool ?? true
        quickLaunch = d.object(forKey: "quickLaunch") as? Bool ?? true
        aiMode = AIMode(rawValue: d.string(forKey: "aiMode") ?? "") ?? .auto
        apiBase = d.string(forKey: "apiBase") ?? "https://openrouter.ai/api/v1"
        apiModel = d.string(forKey: "apiModel") ?? "openai/gpt-4o-mini"
    }
}

/// Ключ API пользователя — в Связке ключей этого Mac.
enum APIKey {
    private static var base: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "MacIsland.api",
         kSecAttrAccount as String: "default"]
    }

    static func load() -> String? {
        var q = base
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data, let s = String(data: data, encoding: .utf8), !s.isEmpty else { return nil }
        return s
    }

    static func save(_ key: String) {
        delete()
        var q = base
        q[kSecValueData as String] = Data(key.utf8)
        SecItemAdd(q as CFDictionary, nil)
    }

    static func delete() { SecItemDelete(base as CFDictionary) }
}
