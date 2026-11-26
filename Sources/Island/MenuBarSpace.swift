import AppKit
import ApplicationServices

/// Сколько места в строке меню слева и справа от чёлки — чтобы свёрнутый остров не закрывал
/// пункты меню программ и значки справа. Смотрим через «Универсальный доступ» (Accessibility):
///   слева — меню активной программы (AXMenuBar), справа — значки всех программ (AXExtrasMenuBar).
/// Все вызовы — в фоне и с коротким таймаутом: зависшая программа не должна тормозить остров.
enum MenuBarSpace {
    private static let queue = DispatchQueue(label: "macisland.menubar", qos: .utility)

    /// Правый край меню активной программы (глобальная координата x), nil — не удалось узнать.
    static func menusMaxX(pid: pid_t, done: @escaping @MainActor (CGFloat?) -> Void) {
        queue.async {
            let v = menusMaxXSync(pid: pid)
            DispatchQueue.main.async { MainActor.assumeIsolated { done(v) } }
        }
    }

    /// Левый край значков справа от `fromX` (ближайший к чёлке), nil — значков рядом нет.
    static func extrasMinX(fromX: CGFloat, done: @escaping @MainActor (CGFloat?) -> Void) {
        let pids = NSWorkspace.shared.runningApplications.map(\.processIdentifier)
        queue.async {
            var best: CGFloat?
            for pid in pids {
                for f in frames(pid: pid, attribute: "AXExtrasMenuBar") where f.minX >= fromX && f.minY < 50 {
                    best = min(best ?? .greatestFiniteMagnitude, f.minX)
                }
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { done(best) } }
        }
    }

    nonisolated private static func menusMaxXSync(pid: pid_t) -> CGFloat? {
        let fs = frames(pid: pid, attribute: kAXMenuBarAttribute)
        guard !fs.isEmpty else { return nil }
        return fs.map(\.maxX).max()
    }

    nonisolated private static func frames(pid: pid_t, attribute: String) -> [CGRect] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.15)
        var bar: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, attribute as CFString, &bar) == .success, let bar,
              CFGetTypeID(bar) == AXUIElementGetTypeID() else { return [] }
        let barEl = bar as! AXUIElement
        AXUIElementSetMessagingTimeout(barEl, 0.15)
        var kids: CFTypeRef?
        guard AXUIElementCopyAttributeValue(barEl, kAXChildrenAttribute as CFString, &kids) == .success,
              let items = kids as? [AXUIElement] else { return [] }
        var out: [CGRect] = []
        for it in items {
            var pos: CFTypeRef?, size: CFTypeRef?
            AXUIElementCopyAttributeValue(it, kAXPositionAttribute as CFString, &pos)
            AXUIElementCopyAttributeValue(it, kAXSizeAttribute as CFString, &size)
            var p = CGPoint.zero, s = CGSize.zero
            if let pos, CFGetTypeID(pos) == AXValueGetTypeID() { AXValueGetValue(pos as! AXValue, .cgPoint, &p) }
            if let size, CFGetTypeID(size) == AXValueGetTypeID() { AXValueGetValue(size as! AXValue, .cgSize, &s) }
            if s.width > 0 { out.append(CGRect(origin: p, size: s)) }
        }
        return out
    }
}
