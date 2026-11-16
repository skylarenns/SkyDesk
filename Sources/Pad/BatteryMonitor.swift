import UIKit

/// The iPad's charge in whole percent, as exact as the system will say.
///
/// `UIDevice.batteryLevel` is handed out in 5 % steps on the iPad (user report 2026-11-16: the toolbar figure
/// "rounds"). The power-source list behind it (IOKit's IOPS calls, which iPadOS has but does not publish for apps)
/// carries the charge to 1 %. It is looked up at run time, so if a later iPadOS takes it away or refuses it, the
/// toolbar quietly falls back to UIDevice's figure. `source` says which one the figure came from (for the log).
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
        if let exact = PowerSources.currentPercent() {
            value = exact; source = "iops"
        } else if UIDevice.current.batteryLevel >= 0 {
            value = Int((UIDevice.current.batteryLevel * 100).rounded()); source = "uidevice"
        } else {
            value = nil; source = "none"
        }
        if percent != value { percent = value }
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
