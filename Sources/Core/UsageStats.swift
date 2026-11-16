import Foundation

/// Battery drain and processor use over a session (build 57, user request 2026-11-16: "add battery measurement /
/// skydesk open / chip usage logs and stats so i can measure the performance and battery drain").
///
/// Only arithmetic lives here so it can be tested; the apps feed it readings once a second or so.

/// CPU time this process has used so far, in seconds (user + system, all threads).
public enum ProcessCPU {
    public static func seconds() -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        func value(_ time: timeval) -> Double { Double(time.tv_sec) + Double(time.tv_usec) / 1_000_000 }
        return value(usage.ru_utime) + value(usage.ru_stime)
    }
}

/// Process CPU use as a share of one core (100 % = one core fully busy; several busy cores read above 100 %).
public struct CPUMeter {
    private var last: (wall: Double, cpu: Double)?
    private var first: (wall: Double, cpu: Double)?
    public private(set) var recent: Double?
    public init() {}
    public mutating func sample(wall: Double, cpu: Double) {
        if first == nil { first = (wall, cpu) }
        if let last, wall - last.wall > 0.05 { recent = max(0, (cpu - last.cpu) / (wall - last.wall) * 100) }
        last = (wall, cpu)
    }
    /// Average since the first sample.
    public var average: Double? {
        guard let first, let last, last.wall - first.wall > 0.5 else { return nil }
        return max(0, (last.cpu - first.cpu) / (last.wall - first.wall) * 100)
    }
    public mutating func reset() { self = CPUMeter() }
}

/// Battery drain since a starting point. A charging battery says nothing about drain, so the count starts again
/// from the first reading after the charger comes off.
public struct BatteryDrain: Equatable {
    public private(set) var startPercent: Int?
    public private(set) var startTime: Double?
    public private(set) var latestPercent: Int?
    public private(set) var latestTime: Double?
    public init() {}
    public mutating func sample(percent: Int?, charging: Bool, now: Double) {
        guard let percent, !charging else { startPercent = nil; startTime = nil; latestPercent = nil; latestTime = nil; return }
        if startPercent == nil { startPercent = percent; startTime = now }
        latestPercent = percent; latestTime = now
    }
    /// Percentage points used since the start (positive while draining).
    public var used: Int? {
        guard let startPercent, let latestPercent else { return nil }
        return startPercent - latestPercent
    }
    public var minutes: Double? {
        guard let startTime, let latestTime else { return nil }
        return (latestTime - startTime) / 60
    }
    /// Percent per hour, once it can mean something: at least 10 minutes and 2 points, since readings are whole
    /// percent (1 point in 10 minutes alone could be anything from 0.1 to 1.9).
    public var perHour: Double? {
        guard let used, let minutes, minutes >= 10, used >= 2 else { return nil }
        return Double(used) / minutes * 60
    }
    public mutating func reset() { self = BatteryDrain() }
}

public enum UsageText {
    /// For the iPad's per-second log line.
    public static func logFields(open: Double, session: Double?, drain: BatteryDrain, cpu: CPUMeter, thermal: Int, lowPower: Bool) -> String {
        var text = String(format: "open=%.1fm", open / 60)
        if let session { text += String(format: " sess=%.1fm", session / 60) }
        if let used = drain.used, let minutes = drain.minutes {
            text += String(format: " drain=%d%%/%.0fm", used, minutes)
            if let rate = drain.perHour { text += String(format: " rate=%.1f%%/h", rate) }
        } else { text += " drain=charging" }
        text += " cpu=" + (cpu.recent.map { String(format: "%.0f", $0) } ?? "-") + "/" + (cpu.average.map { String(format: "%.0f", $0) } ?? "-")
        text += " therm=\(thermal)" + (lowPower ? " lowpower" : "")
        return text
    }
    /// One line for the statistics box.
    public static func summary(battery: Int?, drain: BatteryDrain, session: Double?, cpu: CPUMeter) -> String {
        var parts: [String] = []
        if let battery { parts.append("Battery \(battery)%") }
        if let used = drain.used, let minutes = drain.minutes {
            parts.append(String(format: "used %d%% in %.0f min", used, minutes) + (drain.perHour.map { String(format: " (%.1f%%/h)", $0) } ?? ""))
        } else if battery != nil { parts.append("charging") }
        if let session { parts.append(String(format: "session %.0f min", session / 60)) }
        if let recent = cpu.recent { parts.append(String(format: "iPad CPU %.0f%%", recent) + (cpu.average.map { String(format: " (avg %.0f%%)", $0) } ?? "")) }
        return parts.joined(separator: " · ")
    }
}
