import Combine
import Foundation
import IOKit.ps

/// Батарея MacBook: уровень, зарядка, события «подключили / отключили / мало заряда».
@MainActor
final class Battery: ObservableObject {
    static let shared = Battery()

    enum Event { case plugged(Int), unplugged(Int), low(Int), full }

    @Published private(set) var level = 100
    @Published private(set) var charging = false
    @Published private(set) var pluggedIn = false
    @Published private(set) var hasBattery = false
    let events = PassthroughSubject<Event, Never>()

    private var source: CFRunLoopSource?
    private var warned: Set<Int> = []
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        read(initial: true)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        source = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            let me = Unmanaged<Battery>.fromOpaque(ctx).takeUnretainedValue()
            DispatchQueue.main.async { MainActor.assumeIsolated { me.read(initial: false) } }
        }, ctx)?.takeRetainedValue()
        if let source { CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode) }
    }

    private func read(initial: Bool) {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
                  (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }
            let cur = d[kIOPSCurrentCapacityKey] as? Int ?? 0
            let max = d[kIOPSMaxCapacityKey] as? Int ?? 100
            let newLevel = max > 0 ? Int((Double(cur) / Double(max) * 100).rounded()) : cur
            let newPlugged = (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            let newCharging = d[kIOPSIsChargingKey] as? Bool ?? false
            let wasPlugged = pluggedIn

            hasBattery = true
            level = newLevel
            charging = newCharging
            pluggedIn = newPlugged

            guard !initial else { return }
            if newPlugged && !wasPlugged { events.send(.plugged(newLevel)); warned.removeAll() }
            if !newPlugged && wasPlugged { events.send(.unplugged(newLevel)) }
            if !newPlugged {
                for t in [20, 10, 5] where newLevel <= t && !warned.contains(t) {
                    warned.insert(t)
                    events.send(.low(newLevel))
                    break
                }
            }
            return
        }
    }

    var symbol: String {
        if charging || (pluggedIn && level < 100) { return "battery.100percent.bolt" }
        switch level {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
}
