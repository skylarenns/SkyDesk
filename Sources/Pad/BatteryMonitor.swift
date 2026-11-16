import UIKit

/// The iPad's charge in whole percent, as exact as the system will say.
///
/// `UIDevice.batteryLevel` is handed out in 5 % steps on the iPad (user report 2026-11-16: the toolbar figure
/// "rounds"). Build 55 switched to the power-source list (IOKit's IOPS calls), assuming it carried 1 %: it does
/// not. The iPad logged only 75, 80, 85 and 90 from it over 40 minutes, so iPadOS rounds it for apps too.
/// Build 59 first tries the battery controller's own entry in the I/O registry (AppleSmartBattery), which
/// older iPadOS let apps read unrounded; if the sandbox refuses it, the figure comes from IOPS, then UIDevice.
/// `source` says which one the figure came from, and `diagnosis` what each source reported (for the log).
@MainActor final class BatteryMonitor: ObservableObject {
    static let shared = BatteryMonitor()
    @Published private(set) var percent: Int?
    @Published private(set) var charging = false
    private(set) var source = "none"
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var users = 0

    private init() {}
    /// Reading starts with the first user and stops with the last.
    func start() {
        users += 1
        guard users == 1 else { return }
        UIDevice.current.isBatteryMonitoringEnabled = true
        let center = NotificationCenter.default
        for name in [UIDevice.batteryLevelDidChangeNotification, UIDevice.batteryStateDidChangeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        // UIDevice only announces its own 5 % steps, so the exact figure is read again every 20 s as well.
        let timer = Timer(timeInterval: 20, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common); self.timer = timer
        refresh()
    }
    func stop() {
        users = max(0, users - 1)
        guard users == 0 else { return }
        timer?.invalidate(); timer = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }; observers = []
    }
    func refresh() {
        let state = UIDevice.current.batteryState
        let isCharging = state == .charging || state == .full
        if charging != isCharging { charging = isCharging }
        let value: Int?
        if let exact = BatteryRegistry.percent() {
            value = exact; source = "registry"
        } else if let exact = PowerSources.currentPercent() {
            value = exact; source = "iops"
        } else if UIDevice.current.batteryLevel >= 0 {
            value = Int((UIDevice.current.batteryLevel * 100).rounded()); source = "uidevice"
        } else {
            value = nil; source = "none"
        }
        if percent != value { percent = value }
    }
}

/// The battery controller's entry in the I/O registry, read at run time (IOKit is not in the iPadOS SDK).
private enum BatteryRegistry {
    private typealias Matching = @convention(c) (UnsafePointer<CChar>) -> Unmanaged<CFMutableDictionary>?
    private typealias GetService = @convention(c) (mach_port_t, CFDictionary) -> mach_port_t
    private typealias Property = @convention(c) (mach_port_t, CFString, CFAllocator?, UInt32) -> Unmanaged<CFTypeRef>?
    private typealias Release = @convention(c) (mach_port_t) -> kern_return_t
    private static let calls: (Matching, GetService, Property, Release)? = {
        guard let library = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW),
              let matching = dlsym(library, "IOServiceMatching"),
              let get = dlsym(library, "IOServiceGetMatchingService"),
              let property = dlsym(library, "IORegistryEntryCreateCFProperty"),
              let release = dlsym(library, "IOObjectRelease") else { return nil }
        return (unsafeBitCast(matching, to: Matching.self), unsafeBitCast(get, to: GetService.self),
                unsafeBitCast(property, to: Property.self), unsafeBitCast(release, to: Release.self))
    }()
    static let keys = ["CurrentCapacity", "MaxCapacity", "AppleRawCurrentCapacity", "AppleRawMaxCapacity", "UISoc"]
    /// The listed numbers, or nil when the entry cannot be found or read.
    static func values() -> [String: Int]? {
        #if targetEnvironment(simulator)
        return nil
        #else
        // IOServiceGetMatchingService consumes the dictionary's one reference, so Swift must not release it as well.
        guard let (matching, get, property, release) = calls, let match = matching("AppleSmartBattery")?.takeUnretainedValue() else { return nil }
        let service = get(0, match)
        guard service != 0 else { return nil }
        defer { _ = release(service) }
        var found: [String: Int] = [:]
        for key in keys {
            if let value = property(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber {
                found[key] = value.intValue
            }
        }
        return found.isEmpty ? nil : found
        #endif
    }
    static func percent() -> Int? {
        guard let values = values() else { return nil }
        if let ui = values["UISoc"], (0...100).contains(ui) { return ui }
        if let current = values["CurrentCapacity"], values["MaxCapacity"] == 100, (0...100).contains(current) { return current }
        if let current = values["AppleRawCurrentCapacity"], let maximum = values["AppleRawMaxCapacity"], maximum > 0, (0...maximum).contains(current) {
            return Int((Double(current) * 100 / Double(maximum)).rounded())
        }
        return nil
    }
}

extension BatteryMonitor {
    /// One line for the log: what every source said just now.
    static func diagnosis() -> String {
        let registry = BatteryRegistry.values().map { $0.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",") } ?? "unavailable"
        let iops = PowerSources.description().map { $0.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",") } ?? "unavailable"
        // The Mac logs at most 512 bytes of one line.
        return String("battery sources: registry[\(registry)] uidevice=\(UIDevice.current.batteryLevel) iops[\(iops)]".utf8.prefix(500)) ?? "battery sources: (unreadable)"
    }
}

/// IOKit's power-source calls, found at run time.
private enum PowerSources {
    private typealias CopyInfo = @convention(c) () -> Unmanaged<CFTypeRef>?
    private typealias CopyList = @convention(c) (CFTypeRef) -> Unmanaged<CFArray>?
    private typealias Describe = @convention(c) (CFTypeRef, CFTypeRef) -> Unmanaged<CFDictionary>?
    private static let calls: (CopyInfo, CopyList, Describe)? = {
        guard let library = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW),
              let info = dlsym(library, "IOPSCopyPowerSourcesInfo"),
              let list = dlsym(library, "IOPSCopyPowerSourcesList"),
              let describe = dlsym(library, "IOPSGetPowerSourceDescription") else { return nil }
        return (unsafeBitCast(info, to: CopyInfo.self), unsafeBitCast(list, to: CopyList.self), unsafeBitCast(describe, to: Describe.self))
    }()
    /// The internal battery's numeric fields, for the log.
    static func description() -> [String: Int]? {
        #if targetEnvironment(simulator)
        return nil
        #else
        guard let (copyInfo, copyList, describe) = calls,
              let blob = copyInfo()?.takeRetainedValue(),
              let sources = copyList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in sources {
            guard let description = describe(blob, source)?.takeUnretainedValue() as? [String: Any],
                  (description["Type"] as? String) == "InternalBattery" else { continue }
            return description.compactMapValues { ($0 as? NSNumber)?.intValue }
        }
        return nil
        #endif
    }
    /// The internal battery's charge, 0–100, or nil when the list is unavailable or has no such battery.
    static func currentPercent() -> Int? {
        #if targetEnvironment(simulator)
        return nil // the simulator would report the Mac's own battery
        #else
        guard let (copyInfo, copyList, describe) = calls,
              let blob = copyInfo()?.takeRetainedValue(),
              let sources = copyList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in sources {
            guard let description = describe(blob, source)?.takeUnretainedValue() as? [String: Any],
                  (description["Type"] as? String) == "InternalBattery",
                  let current = description["Current Capacity"] as? Int else { continue }
            let maximum = description["Max Capacity"] as? Int ?? 100
            guard maximum > 0, (0...maximum).contains(current) else { continue }
            return maximum == 100 ? current : Int((Double(current) * 100 / Double(maximum)).rounded())
        }
        return nil
        #endif
    }
}
