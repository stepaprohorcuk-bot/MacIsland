import AppKit
import AudioToolbox
import Combine
import CoreAudio
import CoreMediaIO
import Darwin

/// Загрузка процессора, память и диск. Опрос раз в 2 с и только пока остров раскрыт —
/// чтобы мониторинг сам не нагружал Mac. Температуру macOS сторонним программам не отдаёт.
@MainActor
final class SystemMonitor: ObservableObject {
    static let shared = SystemMonitor()

    @Published private(set) var cpu: Double = 0              // 0…1
    @Published private(set) var ramUsed: Double = 0          // байты
    @Published private(set) var ramTotal = Double(ProcessInfo.processInfo.physicalMemory)
    @Published private(set) var diskFree: Double = 0
    @Published private(set) var diskTotal: Double = 0

    private var prev: (busy: UInt64, total: UInt64)?
    private var timer: Timer?

    var ramFraction: Double { ramTotal > 0 ? ramUsed / ramTotal : 0 }

    func setActive(_ on: Bool) {
        if on, timer == nil {
            sample()
            let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.sample() } }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        } else if !on {
            timer?.invalidate(); timer = nil
        }
    }

    private func sample() {
        // Процессор: доля «занятых» тиков с прошлого замера
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count) }
        }
        if r == KERN_SUCCESS {
            let user = UInt64(info.cpu_ticks.0), sys = UInt64(info.cpu_ticks.1), idle = UInt64(info.cpu_ticks.2), nice = UInt64(info.cpu_ticks.3)
            let busy = user + sys + nice, total = busy + idle
            if let p = prev, total > p.total { cpu = Double(busy - p.busy) / Double(total - p.total) }
            prev = (busy, total)
        }

        // Память: как «Использовано памяти» в Мониторинге системы
        var vm = vm_statistics64()
        var vmCount = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let vr = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &vmCount) }
        }
        if vr == KERN_SUCCESS {
            let page = Double(vm_kernel_page_size)
            let app = Double(vm.internal_page_count) - Double(vm.purgeable_count)
            ramUsed = (app + Double(vm.wire_count) + Double(vm.compressor_page_count)) * page
        }

        if let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]) {
            diskFree = Double(v.volumeAvailableCapacityForImportantUsage ?? 0)
            diskTotal = Double(v.volumeTotalCapacity ?? 0)
        }
    }

    static func gb(_ bytes: Double) -> String { String(format: "%.1f", bytes / 1_073_741_824) }
}

// MARK: - Звук, Wi‑Fi, микрофон и камера

@MainActor
final class Devices: ObservableObject {
    static let shared = Devices()

    @Published private(set) var micInUse = false
    @Published private(set) var cameraInUse = false

    private var fast: Timer?

    func start() {
        // Микрофон и камера — раз в секунду (дёшево), чтобы показать индикатор у чёлки
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.checkInputs() } }
        RunLoop.main.add(t, forMode: .common)
        fast = t
    }

    private func checkInputs() {
        guard AppSettings.shared.showDeviceIndicator else { micInUse = false; cameraInUse = false; return }
        // Свой микрофон (голосовые команды, диктовка) не считаем
        let ours = VoiceCommands.shared.status == .listening || Dictation.shared.listening
        let mic = Self.isRunningSomewhere(Self.defaultDevice(output: false))
        let newMic = mic && !ours
        if newMic != micInUse { micInUse = newMic }
        let cam = Self.cameraRunning()
        if cam != cameraInUse { cameraInUse = cam }
    }

    // MARK: CoreAudio

    nonisolated private static func defaultDevice(output: Bool) -> AudioObjectID {
        var id = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: output ? kAudioHardwarePropertyDefaultOutputDevice : kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return id
    }

    nonisolated private static func isRunningSomewhere(_ id: AudioObjectID) -> Bool {
        guard id != 0 else { return false }
        var v: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &v) == noErr && v != 0
    }

    // MARK: Камера (CoreMediaIO)

    nonisolated private static func cameraRunning() -> Bool {
        var addr = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
                                             mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                             mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(CMIOObjectID(kCMIOObjectSystemObject), &addr, 0, nil, &size) == noErr, size > 0 else { return false }
        var ids = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &addr, 0, nil, size, &used, &ids) == noErr else { return false }
        for id in ids {
            var a = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
                                              mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeWildcard),
                                              mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementWildcard))
            var on: UInt32 = 0
            var u: UInt32 = 0
            if CMIOObjectGetPropertyData(id, &a, 0, nil, UInt32(MemoryLayout<UInt32>.size), &u, &on) == noErr, on != 0 { return true }
        }
        return false
    }
}
