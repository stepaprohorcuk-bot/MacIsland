import AppKit
import ServiceManagement

/// «Открывать при входе» через системный механизм (Настройки → Основные → Объекты входа).
@MainActor
final class LoginItem: ObservableObject {
    static let shared = LoginItem()

    @Published private(set) var enabled = false
    @Published private(set) var needsApproval = false

    init() { refresh() }

    func refresh() {
        let st = SMAppService.mainApp.status
        enabled = st == .enabled
        needsApproval = st == .requiresApproval
    }

    func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("MacIsland login item error: \(error)")
        }
        refresh()
        if on && needsApproval { SMAppService.openSystemSettingsLoginItems() }
    }

    func toggle() { set(!enabled) }

    /// При первом запуске из «Программ» включаем автозапуск сами.
    func enableOnFirstLaunch() {
        let key = "didAutoEnableLogin"
        let path = Bundle.main.bundlePath
        let installed = path.hasPrefix("/Applications/") || path.hasPrefix(NSHomeDirectory() + "/Applications/")
        guard installed, !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        set(true)
    }
}
