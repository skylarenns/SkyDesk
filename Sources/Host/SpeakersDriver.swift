import CoreAudio
import Foundation

/// The "SkyDesk Speakers" output (build 65): a Core Audio driver shipped inside SkyDesk Host and installed into
/// /Library/Audio/Plug-Ins/HAL from the host window (macOS asks for an administrator password).
///
/// With it installed, the Mac's own Sound output menu decides where the Mac's sound plays: SkyDesk Speakers sends
/// it to the iPad, anything else keeps it on the Mac. SkyDesk switches to it when an iPad starts playing and back
/// to the previous output when the iPad stops, goes to the background or disconnects, so the Mac is never left
/// silent; a choice made in the menu during a session is remembered for the next one.
enum SpeakersDriver {
    static let deviceUID = "SkyDeskSpeakers_UID"
    static let installedURL = URL(fileURLWithPath: "/Library/Audio/Plug-Ins/HAL/SkyDesk Speakers.driver")
    static var bundledURL: URL? { Bundle.main.url(forResource: "SkyDesk Speakers", withExtension: "driver") }

    static func version(at url: URL) -> String? {
        (NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist")) as? [String: Any])?["CFBundleVersion"] as? String
    }
    static var installedVersion: String? { version(at: installedURL) }
    static var bundledVersion: String? { bundledURL.flatMap(version(at:)) }
    /// Installed and the same build as the one inside this app.
    static var upToDate: Bool { installedVersion != nil && installedVersion == bundledVersion }

    static let microphoneUID = "SkyDeskMicrophone_UID"
    /// "SkyDesk Microphone" (build 68): the iPad's microphone is played into it and Mac apps record from it.
    static func microphone() -> SoundOutput? {
        device(uid: microphoneUID).map { SoundOutput(id: $0, uid: microphoneUID, name: "SkyDesk Microphone") }
    }
    /// The device, once Core Audio has loaded the driver.
    static func device() -> AudioObjectID? { device(uid: deviceUID) }

    // MARK: Default output

    private static var defaultOutputAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }
    static func defaultOutput() -> AudioObjectID? {
        var device = AudioObjectID(kAudioObjectUnknown)
        var address = defaultOutputAddress
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }
    @discardableResult static func setDefaultOutput(_ device: AudioObjectID) -> Bool {
        var device = device
        var address = defaultOutputAddress
        return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                          UInt32(MemoryLayout<AudioObjectID>.size), &device) == noErr
    }
    static func uid(of device: AudioObjectID) -> String? {
        var uid: Unmanaged<CFString>?
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid) == noErr, let uid else { return nil }
        return uid.takeRetainedValue() as String
    }
    static func device(uid: String) -> AudioObjectID? {
        var uid = uid as CFString
        var device = AudioObjectID(kAudioObjectUnknown)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &uid) { pointer in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                       UInt32(MemoryLayout<CFString>.size), pointer, &size, &device)
        }
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }
    /// Any other output that can be the default, for when the remembered one is gone.
    static func someOtherOutput() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return nil }
        var devices = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices) == noErr else { return nil }
        let speakers = device()
        return devices.first { candidate in
            guard candidate != speakers else { return false }
            var can: UInt32 = 0, canSize = UInt32(MemoryLayout<UInt32>.size)
            var canAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceCanBeDefaultDevice,
                                                        mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectGetPropertyData(candidate, &canAddress, 0, nil, &canSize, &can) == noErr, can != 0 else { return false }
            var streamsAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeOutput,
                                                            mElement: kAudioObjectPropertyElementMain)
            var streamsSize: UInt32 = 0
            return AudioObjectGetPropertyDataSize(candidate, &streamsAddress, 0, nil, &streamsSize) == noErr && streamsSize > 0
        }
    }

    // MARK: Routing memory

    /// Whether SkyDesk Speakers should be chosen when an iPad plays (the user's last choice; on until they pick
    /// another output during a session).
    static var wanted: Bool {
        get { UserDefaults.standard.object(forKey: "speakersWanted") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "speakersWanted") }
    }
    /// The output to go back to, kept across launches in case SkyDesk Host quits while SkyDesk Speakers is chosen.
    static var previousUID: String? {
        get { UserDefaults.standard.string(forKey: "speakersPreviousOutput") }
        set { UserDefaults.standard.set(newValue, forKey: "speakersPreviousOutput") }
    }
    /// Back to the Mac's own output if SkyDesk Speakers is chosen. Returns whether it switched.
    @discardableResult static func routeToMac() -> Bool {
        guard let speakers = device(), defaultOutput() == speakers else { return false }
        let target = previousUID.flatMap { device(uid: $0) }.flatMap { $0 == speakers ? nil : $0 } ?? someOtherOutput()
        guard let target, setDefaultOutput(target) else { return false }
        MetricsLog.shared.append("host  sound output back to " + (uid(of: target) ?? "the Mac's output") + " (SkyDesk Speakers off)")
        return true
    }
    /// SkyDesk Speakers chosen, remembering the output it replaces. Returns whether it switched.
    @discardableResult static func routeToPad() -> Bool {
        guard let speakers = device(), let current = defaultOutput(), current != speakers else { return false }
        previousUID = uid(of: current)
        guard setDefaultOutput(speakers) else { return false }
        MetricsLog.shared.append("host  sound output switched to SkyDesk Speakers (was " + (previousUID ?? "?") + ")")
        return true
    }

    // MARK: Install

    /// Copies the driver into place and restarts Core Audio, behind macOS's administrator prompt.
    /// Runs on a background queue; `done` gets nil on success or the reason it failed.
    static func install(done: @escaping @Sendable (String?) -> Void) {
        guard let source = bundledURL else { done("This copy of SkyDesk Host has no SkyDesk Speakers inside."); return }
        run(script: "rm -rf \(quote(installedURL.path)) && cp -R \(quote(source.path)) \(quote(installedURL.path)) && "
            + "chown -R root:wheel \(quote(installedURL.path)) && killall coreaudiod", done: done)
    }
    static func uninstall(done: @escaping @Sendable (String?) -> Void) {
        routeToMac()
        run(script: "rm -rf \(quote(installedURL.path)) && killall coreaudiod", done: done)
    }
    private static func quote(_ path: String) -> String { "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    private static func run(script: String, done: @escaping @Sendable (String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            let escaped = script.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            process.arguments = ["-e", "do shell script \"\(escaped)\" with administrator privileges"]
            let errors = Pipe()
            process.standardError = errors
            do { try process.run() } catch { done(error.localizedDescription); return }
            process.waitUntilExit()
            let message = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if process.terminationStatus == 0 { done(nil) }
            else if message?.contains("-128") == true { done("Cancelled.") }
            else { done(message?.isEmpty == false ? message : "It didn't install (status \(process.terminationStatus)).") }
        }
    }
}
