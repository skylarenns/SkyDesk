import AppKit
import Combine
import Network
import ScreenCaptureKit
import IOKit.pwr_mgt

@MainActor
final class HostModel: ObservableObject {
    @Published var status = "Starting…"
    /// The user-facing switch. With `autoAccept` on, a paired iPad turns it on by connecting.
    @Published var sharing = false
    /// The secure listener is up (sharing on, or waiting for the paired iPad to turn it on).
    @Published var listening = false
    @Published var clientConnected = false
    @Published var autoAccept = UserDefaults.standard.object(forKey: "autoAccept") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoAccept, forKey: "autoAccept"); updateListener() }
    }
    @Published var busy = false
    @Published var displays: [SCDisplay] = []
    // "Display & quality" choices are kept between launches (build 38): the host now starts at login and restarts
    // itself after updates, and used to come back with the defaults every time.
    @Published var displayID = UInt32(clamping: UserDefaults.standard.integer(forKey: "displayID")) {
        didSet { UserDefaults.standard.set(Int(displayID), forKey: "displayID") }
    }
    @Published var longestEdge = HostModel.saved("longestEdge", among: [1920, 2560, 4096], default: 2560) {
        didSet { UserDefaults.standard.set(longestEdge, forKey: "longestEdge") }
    }
    @Published var useiPadDesktop = UserDefaults.standard.object(forKey: "useiPadDesktop") as? Bool ?? true {
        didSet { UserDefaults.standard.set(useiPadDesktop, forKey: "useiPadDesktop") }
    }
    @Published var fps = HostModel.saved("fps", among: [30, 60, 120], default: 120) {
        didSet { UserDefaults.standard.set(fps, forKey: "fps") }
    }
    @Published var bitrateMbps = HostModel.saved("bitrateMbps", among: [15, 25, 40, 60, 80], default: 25) {
        didSet { UserDefaults.standard.set(bitrateMbps, forKey: "bitrateMbps") }
    }
    @Published var allowInput = UserDefaults.standard.object(forKey: "allowInput") as? Bool ?? true {
        didSet { UserDefaults.standard.set(allowInput, forKey: "allowInput") }
    }
    /// A saved number is only used if it is still one of the choices offered.
    private static func saved(_ key: String, among choices: [Int], default fallback: Int) -> Int {
        let value = UserDefaults.standard.integer(forKey: key)
        return choices.contains(value) ? value : fallback
    }
    @Published var allowClipboard = UserDefaults.standard.object(forKey: "allowClipboard") as? Bool ?? true {
        didSet { UserDefaults.standard.set(allowClipboard, forKey: "allowClipboard") }
    }
    @Published var allowFiles = UserDefaults.standard.object(forKey: "allowFiles") as? Bool ?? true {
        didSet { UserDefaults.standard.set(allowFiles, forKey: "allowFiles") }
    }
    /// Send the Mac's sound to the iPad (build 34). The Mac's speakers go quiet only while the iPad is playing it.
    @Published var allowAudio = UserDefaults.standard.object(forKey: "allowAudio") as? Bool ?? true {
        didSet { UserDefaults.standard.set(allowAudio, forKey: "allowAudio") }
    }
    private var audioChannel: SecureChannel?
    private var audio: HostAudio?
    // MARK: Video over UDP (build 38)
    private let router = VideoRouter()
    private var datagramListener: NWListener?
    private let datagramQueue = DispatchQueue(label: "skydesk.host.datagram", qos: .userInteractive)
    /// UDP flows that have connected; one of them becomes the session's video path when it says hello.
    private var datagramFlows: [ObjectIdentifier: VideoDatagramSender] = [:]
    // MARK: Paired iPads (build 37)
    /// iPads with their own key, most recently seen first.
    @Published private(set) var devices = PairedDeviceList.load(from: .standard)
    /// Off = only iPads already paired can connect; the password opens nothing. Needs at least one paired iPad.
    @Published var allowPasswordPairing = UserDefaults.standard.object(forKey: "allowPasswordPairing") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(allowPasswordPairing, forKey: "allowPasswordPairing")
            if oldValue != allowPasswordPairing { rebuildListener() }
        }
    }
    /// Keep the Mac from going to sleep on its own while it is ready for the iPad (for use away from home).
    /// Stay in iPad only mode when the iPad goes away, so it gets its desktop back at once (KeptDesktop.swift).
    /// Minutes; 0 = off, KeptDesktop.forever = until someone uses the Mac.
    @Published var keepPadDesktopMinutes = (UserDefaults.standard.object(forKey: "keepPadDesktopMinutes") as? Int)
        .flatMap({ KeptDesktop.choices.contains($0) ? $0 : nil }) ?? KeptDesktop.defaultMinutes {
        didSet {
            UserDefaults.standard.set(keepPadDesktopMinutes, forKey: "keepPadDesktopMinutes")
            if keepPadDesktopMinutes == 0 { releaseKeptDesktop(reason: "keeping the iPad desktop was switched off") }
            else if keptDesktop != nil { startKeptDesktopLimit() }
        }
    }
    private var keptDesktopLimit: DispatchWorkItem?
    /// A kept desktop is given up after the chosen time, so a Mac left alone gets its display back.
    private func startKeptDesktopLimit() {
        keptDesktopLimit?.cancel(); keptDesktopLimit = nil
        guard let seconds = KeptDesktop.limit(minutes: keepPadDesktopMinutes) else { return }
        let minutes = keepPadDesktopMinutes
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.releaseKeptDesktop(reason: "no iPad came back within \(minutes) min") }
        }
        keptDesktopLimit = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }
    /// True while the iPad-only desktop is being kept with no iPad connected.
    @Published private(set) var desktopKept = false
    @Published var keepAwake = UserDefaults.standard.bool(forKey: "keepAwake") {
        didSet { UserDefaults.standard.set(keepAwake, forKey: "keepAwake"); updateAwake() }
    }
    private var awakeAssertion: IOPMAssertionID = 0
    private var deviceKeys: [UUID: PairingKey] = [:]
    private var listenerStale = false
    /// The paired iPad in the current session, if it said who it is.
    private var currentDevice: UUID?
    /// Identifies this Mac to its paired iPads across all its addresses.
    private let hostID: UUID = {
        if let text = UserDefaults.standard.string(forKey: "hostID"), let id = UUID(uuidString: text) { return id }
        let id = UUID(); UserDefaults.standard.set(id.uuidString, forKey: "hostID"); return id
    }()
    /// Newest first; finished transfers stay listed until the next session.
    @Published var transfers: [FileTransferEngine.Progress] = []
    @Published var filesReady = false
    /// Build number of the staged update, if one is waiting in ~/Library/Application Support/SkyDesk/Updates/ready.
    @Published var stagedBuild: Int?
    @Published var updating = false
    let ownBuild = Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "") ?? 0
    static let updateFolder = UpdateCertificates.support.appendingPathComponent("Updates/\(UpdateInfo.folderName)", isDirectory: true)
    private var clientBuild: Int?
    private var offeredBuild: Int?
    private var updateServer: UpdateServer?
    private var lastSessionEnd = Date()
    /// The iPad's build at its last connection, or the staged build once that was fully downloaded by the iPad.
    private var knownPadBuild = UserDefaults.standard.integer(forKey: "knownPadBuild") {
        didSet { UserDefaults.standard.set(knownPadBuild, forKey: "knownPadBuild") }
    }
    @Published var lowLatencyRateControl = UserDefaults.standard.bool(forKey: "lowLatencyRateControl") {
        didSet { UserDefaults.standard.set(lowLatencyRateControl, forKey: "lowLatencyRateControl") }
    }
    /// Ask the encoder for its fastest mode (build 39): about 5 ms less delay in ordinary desktop use.
    @Published var fastEncoding = UserDefaults.standard.object(forKey: "fastEncoding") as? Bool ?? true {
        didSet { UserDefaults.standard.set(fastEncoding, forKey: "fastEncoding") }
    }
    /// Lower the bitrate when the network falls behind, back up to the Bitrate setting when it recovers (build 33).
    @Published var adaptiveBitrate = UserDefaults.standard.object(forKey: "adaptiveBitrate") as? Bool ?? true {
        didSet { UserDefaults.standard.set(adaptiveBitrate, forKey: "adaptiveBitrate") }
    }
    private var bitrateController: BitrateController?
    private var bitrateTimer: Timer?
    private var lastBitrateSample = monotonicNanos()
    @Published var password = ""
    @Published var pairingLocked = false
    @Published var metrics = "No client connected"
    @Published var lanAddresses = LANAddressDiscovery.current()
    @Published var screenAllowed = CGPreflightScreenCaptureAccess()
    @Published var inputAllowed = AXIsProcessTrusted()
    let input = InputInjector()
    /// Called just before the app quits to install a Mac update and reopen.
    var willRelaunch: (() -> Void)?
    enum Phase { case connected, waiting, standby, off, locked }
    var phase: Phase {
        if pairingLocked { return .locked }
        if clientConnected { return .connected }
        if listening { return sharing ? .waiting : .standby }
        return .off
    }
    var headline: String {
        switch phase {
        case .connected: return "iPad connected"
        case .waiting: return "Sharing is on"
        case .standby: return "Ready for your iPad"
        case .off: return "Sharing is off"
        case .locked: return "Password locked"
        }
    }
    private static let passwordAccount = "host-password"
    private var key: PairingKey?
    private var listener: NWListener?
    private var listenerRetry: DispatchWorkItem?
    private var asleep = false
    private var channels: [UUID: SecureChannel] = [:]
    private var control: SecureChannel?
    private var video: SecureChannel?
    private var sessionID: UUID?
    private var generation = UUID()
    private var listenerGeneration = UUID()
    private var capture: DisplayCapture?
    private var clientDisplay: ClientDisplay?
    private var clientFeatures = 0
    /// Channels run here, not on main, so frame acknowledgements and pings never wait behind UI or input work.
    private let transportQueue = DispatchQueue(label: "skydesk.host.transport", qos: .userInteractive)
    private let fastPath = ControlFastPath()
    private var virtualDisplay: SkyDeskVirtualDisplay?
    /// What `virtualDisplay` was built for.
    private var sessionShape: KeptDesktop.Shape?
    /// The iPad-only desktop of an iPad that left, still the Mac's only display, waiting for it to return.
    private var keptDesktop: (display: SkyDeskVirtualDisplay, shape: KeptDesktop.Shape)?
    private var focusMonitor: RemoteFocusMonitor?
    private var cursorMonitor: CursorMonitor?
    private var files: SecureChannel?
    private var fileEngine: FileTransferEngine?
    /// Lets the transport queue hand file packets straight to the engine, without a trip through the main thread.
    private let fileRoute = FileRoute()
    private var clipboard: ClipboardSync?
    private var clipboardTimer: Timer?
    static let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
    private lazy var displayController: MacDisplayController = {
        let blanker = MacDisplayController()
        blanker.onChange = { [weak self] blanked in
            self?.control?.send(.macDisplayBlanked(blanked))
            // Someone used the Mac, or the arrangement changed: a kept desktop has nothing left to wait on.
            if !blanked { self?.keptDesktopEnded() }
        }
        blanker.onLayoutChange = { [weak self] in self?.refreshInputGeometry() }
        return blanker
    }()
    private var timer: Timer?
    private var lastHeartbeat = Date()
    private var lastMetrics = Date()
    private var startingCapture = false

    /// Loads (or on first run creates) the pairing password, then starts listening if allowed.
    /// The pre-password 64-hex key stays untouched in the Keychain under its old account.
    func loadPairing(allowInteraction: Bool = false) async {
        guard !busy, key == nil else { return }
        busy = true
        let account = Self.passwordAccount
        let paired = devices.devices
        let result = await Task.detached(priority: .userInitiated) { () -> Result<(String, PairingKey, [UUID: PairingKey]), Error> in
            do {
                var text = try PairingStore.loadText(account: account, allowInteraction: allowInteraction)
                if text == nil {
                    let created = try PairingPassword.generate()
                    try PairingStore.saveText(created, account: account, allowInteraction: allowInteraction)
                    text = created
                }
                var keys: [UUID: PairingKey] = [:]
                for device in paired {
                    if let key = (try? PairingStore.load(account: device.keychainAccount, allowInteraction: allowInteraction)) ?? nil { keys[device.id] = key }
                }
                return .success((text!, try PairingPassword.deriveKey(text!), keys))
            } catch { return .failure(error) }
        }.value
        busy = false
        switch result {
        case .success(let (text, key, keys)):
            deviceKeys = keys
            self.key = key; password = text; pairingLocked = false
            startTimer(); updateListener()
        case .failure:
            pairingLocked = true
            status = "Keychain approval is needed. Choose Unlock, then respond to macOS."
        }
    }
    /// Replaces the password. The paired iPad must type the new one once.
    func setPassword(_ text: String) async -> String? {
        guard !busy, !clientConnected else { return "Disconnect the iPad first." }
        do { try PairingPassword.validate(text) } catch { return error.localizedDescription }
        busy = true; defer { busy = false }
        let account = Self.passwordAccount
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let result = await Task.detached(priority: .userInitiated) { () -> Result<PairingKey, Error> in
            do { try PairingStore.saveText(clean, account: account); return .success(try PairingPassword.deriveKey(clean)) }
            catch { return .failure(error) }
        }.value
        switch result {
        case .success(let key):
            self.key = key; password = clean
            restartListener()
            return nil
        case .failure(let error): return error.localizedDescription
        }
    }
    func randomPassword() async -> String? {
        guard let generated = try? PairingPassword.generate() else { return "Could not generate a password." }
        return await setPassword(generated)
    }
    func refreshNetworkAddresses() {
        let current = LANAddressDiscovery.current()
        if current != lanAddresses { lanAddresses = current }
    }
    func refreshPermissions() { screenAllowed = CGPreflightScreenCaptureAccess(); inputAllowed = AXIsProcessTrusted() }
    func requestScreen() {
        CGRequestScreenCaptureAccess(); refreshPermissions()
        if !screenAllowed { openPrivacy("Privacy_ScreenCapture") }
    }
    func requestInput() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        inputAllowed = AXIsProcessTrustedWithOptions(options)
    }
    private func openPrivacy(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") { NSWorkspace.shared.open(url) }
    }
    func refreshDisplays() async {
        refreshPermissions()
        guard screenAllowed else { status = "Allow Screen Recording, then refresh displays. You may need to reopen SkyDesk."; return }
        do {
            displays = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true).displays
            // In iPad only mode the list holds nothing but the iPad's display; the saved choice is still the right one.
            if !displayController.isEnabled, !displays.contains(where: { $0.displayID == displayID }) { displayID = displays.first?.displayID ?? 0 }
        } catch { status = error.localizedDescription }
    }
    func startSharing() {
        sharing = true
        updateListener()
    }
    func stopSharing() {
        sharing = false
        disconnect()
        updateListener()
    }
    /// Quit or sleep: end the session and close the port. Sharing preferences are kept for wake.
    func shutdown() {
        disconnect()
        closeListener()
    }
    func sleep() { asleep = true; shutdown() }
    func wake() { asleep = false; updateListener() }
    private var wantsListener: Bool { key != nil && !asleep && (sharing || autoAccept) }
    /// Everything the listener accepts: each paired iPad's own key, and the password unless that is switched off.
    /// With no paired iPad the password always works, so the Mac can never be left with no way in.
    private var listenerCredentials: [PairingCredential] {
        let own = devices.devices.compactMap { device in deviceKeys[device.id].map { PairingCredential.device(device.id, key: $0) } }
        guard let key else { return own }
        return (allowPasswordPairing || own.isEmpty ? [.password(key)] : []) + own
    }
    var passwordPairingActive: Bool { allowPasswordPairing || devices.devices.allSatisfy { deviceKeys[$0.id] == nil } }
    /// A change to who may connect: the port reopens with the new set. A running session is not interrupted.
    private func rebuildListener() {
        guard listener != nil else { return }
        closeListener(); updateListener()
    }
    /// Removes one paired iPad. It can only come back by pairing with the password again (if that is allowed).
    func removeDevice(_ id: UUID) {
        guard let removed = devices.remove(id) else { return }
        devices.save(to: .standard)
        deviceKeys[id] = nil
        let account = removed.keychainAccount
        Task.detached(priority: .utility) { PairingStore.delete(account: account) }
        MetricsLog.shared.append("host  paired iPad removed")
        if currentDevice == id, clientConnected { disconnect(); status = "\(removed.name) was removed and disconnected." }
        rebuildListener()
    }
    private func issueDeviceKey(_ request: DeviceKeyRequest) {
        guard let fresh = try? PairingKey() else { return }
        let dropped = devices.record(request.device, name: request.name, at: Date())
        devices.save(to: .standard)
        dropped.forEach { deviceKeys[$0.id] = nil }
        deviceKeys[request.device] = fresh
        currentDevice = request.device
        let account = PairedDevice(id: request.device, name: "", added: Date(), lastSeen: Date()).keychainAccount
        let stale = dropped.map(\.keychainAccount)
        let session = sessionID
        Task {
            let saved = await Task.detached(priority: .userInitiated) { () -> Bool in
                stale.forEach { PairingStore.delete(account: $0) }
                return (try? PairingStore.save(fresh, account: account)) != nil
            }.value
            guard saved else {
                // Not stored, so not usable after a restart: forget it rather than hand out a key that will stop working.
                deviceKeys[request.device] = nil; _ = devices.remove(request.device); devices.save(to: .standard)
                MetricsLog.shared.append("host  could not store a key for the iPad; it keeps using the password")
                return
            }
            // The new key is accepted from the next time the port reopens (when this session ends).
            listenerStale = true
            if sessionID == session { control?.send(.deviceKey(DeviceKeyGrant(device: request.device, host: hostID, key: fresh.data))) }
            MetricsLog.shared.append("host  issued this iPad its own key")
        }
    }
    private func updateAwake() {
        let wanted = keepAwake && listening
        if wanted, awakeAssertion == 0 {
            var id: IOPMAssertionID = 0
            if IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                           "SkyDesk is ready for the iPad" as CFString, &id) == kIOReturnSuccess { awakeAssertion = id }
        } else if !wanted, awakeAssertion != 0 {
            IOPMAssertionRelease(awakeAssertion); awakeAssertion = 0
        }
    }
    private func updateListener() {
        if wantsListener { openListener() } else { closeListener() }
        refreshStatus()
    }
    private func restartListener() {
        disconnect(); closeListener(); updateListener()
    }
    private func closeListener() {
        listenerGeneration = UUID()
        listenerRetry?.cancel(); listenerRetry = nil
        listener?.cancel(); listener = nil
        datagramListener?.cancel(); datagramListener = nil
        listening = false
        updateAwake()
    }
    /// The UDP twin of the listener: same port number, same credentials. If it cannot open, video simply stays on TCP.
    private func openDatagramListener() {
        guard datagramListener == nil, let port = NWEndpoint.Port(rawValue: DeskNetwork.datagramPort),
              let listener = try? NWListener(using: DeskNetwork.datagramParameters(credentials: listenerCredentials), on: port) else { return }
        listener.newConnectionHandler = { [weak self, weak listener] connection in
            MainActor.assumeIsolated {
                guard let self, let listener, self.datagramListener === listener else { connection.cancel(); return }
                self.acceptDatagram(connection)
            }
        }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard case .failed(let error) = state else { return }
            MainActor.assumeIsolated {
                guard let self, let listener, self.datagramListener === listener else { return }
                self.datagramListener = nil
                MetricsLog.shared.append("host  UDP port unavailable (\(error.localizedDescription)); video stays on TCP")
            }
        }
        datagramListener = listener
        listener.start(queue: .main)
    }
    private func acceptDatagram(_ connection: NWConnection) {
        guard datagramFlows.count < 6 else { connection.cancel(); return }
        let sender = VideoDatagramSender(connection: connection, queue: datagramQueue)
        let id = ObjectIdentifier(sender)
        let router = router
        sender.bitrate = { router.bitrate }
        sender.onHello = { router.accepts($0) }
        sender.onActive = { [weak sender] in if let sender { router.activate(sender) } }
        sender.onStopped = { [weak self, weak sender] reason, unsent in
            if let sender { router.stopped(sender, reason: reason, unsent: unsent) }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.datagramFlows[id] = nil } }
        }
        datagramFlows[id] = sender
        sender.start()
    }
    private func openListener() {
        guard listener == nil, key != nil else { return }
        do {
            listenerStale = false
            let listener = try NWListener(using: DeskNetwork.parameters(credentials: listenerCredentials), on: NWEndpoint.Port(rawValue: DeskNetwork.port)!)
            listener.service = NWListener.Service(name: Host.current().localizedName ?? "SkyDesk Mac", type: DeskNetwork.serviceType)
            let token = UUID(); listenerGeneration = token
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    guard let self, self.listenerGeneration == token else { connection.cancel(); return }
                    self.accept(connection)
                }
            }
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self, self.listenerGeneration == token else { return }
                    switch state {
                    case .ready: self.listening = true; self.refreshStatus(); self.updateAwake()
                    case .failed(let error):
                        // Usually the port is briefly busy after a relaunch: try again shortly.
                        self.closeListener(); self.status = "Couldn't open the network port (\(error.localizedDescription)). Retrying…"
                        let retry = DispatchWorkItem { [weak self] in self?.updateListener() }
                        self.listenerRetry = retry
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: retry)
                    default: break
                    }
                }
            }
            self.listener = listener
            listener.start(queue: .main)
            openDatagramListener()
        } catch { status = error.localizedDescription }
    }
    private func startTimer() {
        guard timer == nil else { return }
        lastMetrics = Date()
        timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }
    func refreshStatus() {
        if pairingLocked || key == nil { return }
        if clientConnected { return }
        if asleep { status = "Paused while the Mac sleeps"; return }
        if !listening { status = wantsListener ? "Starting…" : "Off. Your iPad can't connect."; return }
        status = !sharing ? "Off. Your iPad can turn it on by connecting."
            : desktopKept ? "Waiting for your iPad. Its desktop is kept; press a key on the Mac to get the Mac's display back." : "Waiting for your iPad"
    }
    /// Gives up a kept desktop: the Mac's displays come back and the iPad's display is removed.
    private func releaseKeptDesktop(reason: String) {
        guard keptDesktop != nil else { return }
        displayController.restore(reason: reason)
        keptDesktopEnded()
    }
    /// The Mac's displays are back (or on their way); remove the iPad's display that was being kept.
    private func keptDesktopEnded() {
        guard let kept = keptDesktop else { return }
        keptDesktop = nil; desktopKept = false
        keptDesktopLimit?.cancel(); keptDesktopLimit = nil
        MetricsLog.shared.append("host  kept iPad desktop given up; the Mac's displays are back")
        let display = kept.display
        Task { display.invalidate() }
        refreshStatus()
    }
    /// A virtual display a cancelled session start no longer needs, unless it is the kept one.
    private func discard(_ display: SkyDeskVirtualDisplay) {
        if keptDesktop?.display !== display, virtualDisplay !== display { display.invalidate() }
    }
    private func disconnect(_ end: KeptDesktop.SessionEnd = .hostEnded) {
        generation = UUID()
        ContinuityLink.resume()
        let padOnly = displayController.isSettled && (keptDesktop != nil || (virtualDisplay != nil && sessionShape != nil))
        let keep = KeptDesktop.shouldKeep(setting: keepPadDesktopMinutes != 0, padOnly: padOnly, end: end,
                                          macUpdateWaiting: updateWhenPadDrops || macUpdateDue)
        if keep {
            if let display = virtualDisplay, let shape = sessionShape {
                keptDesktop = (display, shape); desktopKept = true; virtualDisplay = nil
                startKeptDesktopLimit()
                MetricsLog.shared.append("host  iPad left; its desktop stays the Mac's only display until it returns or someone uses the Mac")
                DisplayLog.write("kept: session ended with iPad only on; nothing restored")
            }
        } else {
            displayController.restore(reason: "session ended")
            keptDesktopEnded()
        }
        sessionShape = nil
        let current = channels.values
        channels.removeAll(); control = nil; video = nil; sessionID = nil; clientDisplay = nil; clientFeatures = 0
        fastPath.bind(control: nil); fastPath.bind(window: nil)
        focusMonitor?.stop(); focusMonitor = nil
        cursorMonitor?.stop(); cursorMonitor = nil
        clipboardTimer?.invalidate(); clipboardTimer = nil; clipboard = nil
        bitrateTimer?.invalidate(); bitrateTimer = nil; bitrateController = nil
        fastPath.bind(frameAcknowledged: nil)
        router.end()
        datagramFlows.values.forEach { $0.close() }
        audio?.stop(); audio = nil; audioChannel = nil
        fileRoute.set(nil, engine: nil)
        fileEngine?.close(reason: "The iPad disconnected."); fileEngine = nil; files = nil; filesReady = false
        current.forEach { $0.close() }
        input.onPointerHeld = nil
        input.releaseAll()
        let old = capture; capture = nil
        let oldDisplay = virtualDisplay; virtualDisplay = nil
        Task { await old?.stop(); oldDisplay?.invalidate() }
        startingCapture = false
        metrics = "No client connected"
        if clientConnected { lastSessionEnd = Date() }
        if updateWhenPadDrops {
            updateWhenPadDrops = false
            MetricsLog.shared.append("host  iPad that asked for the update disconnected; updating the Mac now")
            DispatchQueue.main.async { [weak self] in self?.updateAfterDrop(attempt: 0) }
        }
        clientBuild = nil; offeredBuild = nil
        clientConnected = false
        currentDevice = nil
        // A key issued during the session starts working now.
        if listenerStale { rebuildListener() }
        refreshStatus()
    }
    private func accept(_ connection: NWConnection) {
        // Control, video and files, plus room for the iPad's "which address answers?" probes (build 33).
        guard channels.count < 8 else { connection.cancel(); return }
        let channel = SecureChannel(connection: connection, queue: transportQueue, maxPendingBytes: 18 * 1024 * 1024)
        channels[channel.id] = channel
        channel.onPacket = { [weak self, weak channel, fastPath, fileRoute] packet in
            guard let channel else { return }
            if let engine = fileRoute.engine(for: channel.id) { engine.handle(packet); return }
            var pongSent = false
            if let message = try? packet.controlMessage() {
                switch fastPath.handle(message, channel: channel.id, reply: { channel.send($0) }) {
                case .handled: return
                case .pongSent: pongSent = true
                case .pass: break
                }
            }
            // Everything else keeps its arrival order on the main actor.
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.receive(packet, from: channel, pongSent: pongSent) }
            }
        }
        channel.onClose = { [weak self, weak channel] reason in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, let channel, self.channels.removeValue(forKey: channel.id) != nil else { return }
                    // A connection that was never accepted into a session and did not simply close: record it.
                    // (The iPad's own "which address answers?" probes close cleanly, with no reason, and are not counted.)
                    if self.control !== channel, self.video !== channel, self.files !== channel, self.audioChannel !== channel, let reason {
                        self.noteRefused(channel.connection, reason: reason == PairingPassword.mismatchMessage ? "wrong key or an unsupported key exchange" : reason)
                    }
                    if self.control === channel || self.video === channel {
                        self.disconnect(.padLeft)
                        if let reason { self.status = reason }
                    } else if self.audioChannel === channel {
                        // Losing only the sound channel puts the sound back on the Mac, nothing else.
                        self.audio?.stop(); self.audio = nil; self.audioChannel = nil
                    } else if self.files === channel {
                        // Losing only the file channel ends transfers, not the session.
                        self.fileRoute.set(nil, engine: nil)
                        self.fileEngine?.close(reason: reason ?? "File connection closed."); self.fileEngine = nil
                        self.files = nil; self.filesReady = false
                    }
                }
            }
        }
        channel.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self, weak channel] in
            guard let self, let channel, self.channels[channel.id] != nil else { return }
            if self.control !== channel && self.video !== channel && self.files !== channel && self.audioChannel !== channel {
                channel.close(reason: "Session handshake timed out.")
            }
            else if self.control == nil || self.video == nil { self.disconnect(.padLeft) }
        }
    }
    private func receive(_ packet: WirePacket, from channel: SecureChannel, pongSent: Bool = false) {
        guard channels[channel.id] != nil else { return }
        do {
            let message = try packet.controlMessage()
            if channel === audioChannel {
                guard case .audioPlaying(let playing) = message else { throw DeskError.invalid("Unexpected message on the sound channel.") }
                audio?.setPadPlaying(playing)
                return
            }
            if control !== channel && video !== channel {
                guard case .hello(let hello) = message else { throw DeskError.invalid("Missing session handshake.") }
                guard sessionID == nil || sessionID == hello.session else { throw DeskError.invalid("Another iPad is connected.") }
                // Reaching here means TLS completed with the pairing password: only the paired iPad gets this far.
                if !sharing {
                    guard autoAccept else { throw DeskError.invalid("Sharing is off on the Mac.") }
                    sharing = true
                    MetricsLog.shared.append("host  sharing turned on automatically by the paired iPad")
                }
                switch hello.role {
                case .control:
                    guard control == nil else { throw DeskError.invalid("Control channel already connected.") }
                    if let display = hello.display { try display.validate() }
                    clientDisplay = hello.display
                    clientFeatures = hello.features ?? 0
                    clientBuild = hello.appBuild
                    if let build = hello.appBuild {
                        knownPadBuild = build
                        MetricsLog.shared.append("host  iPad connected (build \(build))")
                    }
                    if let device = hello.device, devices.contains(device), deviceKeys[device] != nil {
                        devices.record(device, name: hello.deviceName, at: Date()); devices.save(to: .standard)
                        currentDevice = device
                    }
                    control = channel
                    acceptedFrom[Self.address(of: channel.connection)] = Date()
                    fastPath.bind(control: channel.id)
                case .video:
                    guard video == nil else { throw DeskError.invalid("Video channel already connected.") }
                    video = channel
                case .files:
                    guard sessionID == hello.session, control != nil, files == nil, allowFiles,
                          clientFeatures & StreamFeature.fileTransfer != 0 else { throw DeskError.invalid("File transfer is not available.") }
                    openFiles(on: channel)
                    return
                case .audio:
                    guard sessionID == hello.session, control != nil, audioChannel == nil, allowAudio, HostAudio.supported,
                          clientFeatures & StreamFeature.audio != 0 else { throw DeskError.invalid("Sound is not available.") }
                    let sound = HostAudio(channel: channel)
                    sound.onStatus = { [weak self] in self?.control?.send(.failure($0)) }
                    audioChannel = channel; audio = sound
                    if capture?.isPaused != true { sound.start() } else { sound.setPaused(true); sound.start() }
                    return
                }
                sessionID = hello.session
                lastHeartbeat = Date()
                if control != nil && video != nil { beginCapture() }
                return
            }
            guard channel === control else { throw DeskError.invalid("Client commands require the control channel.") }
            switch message {
            case .ping(let value): lastHeartbeat = Date(); if !pongSent { control?.send(.pong(value)) }
            case .frameAck(let sequence): capture?.window.acknowledge(sequence)
            case .input(let event):
                guard event.isValid else { throw DeskError.invalid("Invalid input event.") }
                if allowInput, capture != nil {
                    input.handle(event)
                    if event.kind == .up { focusMonitor?.checkAfterClick() }
                }
            case .text(let text):
                guard text.utf8.count <= 8192 else { throw DeskError.invalid("Text input exceeds 8 KiB.") }
                if allowInput, capture != nil { input.insertText(text); focusMonitor?.checkAfterClick() }
            case .setMacDisplayBlanked(let enabled):
                guard allowInput, capture != nil, let virtualDisplay else {
                    control?.send(.failure("iPad only is available with a separate desktop and remote input enabled."))
                    return
                }
                let session = sessionID
                Task { @MainActor in
                    guard sessionID == session, capture != nil, self.virtualDisplay === virtualDisplay else { return }
                    do {
                        if enabled { try await displayController.enable(excluding: virtualDisplay.displayID) }
                        else { displayController.restore(reason: "iPad button") }
                        if sessionID == session { control?.send(.macDisplayBlanked(displayController.isEnabled)) }
                    } catch { if sessionID == session { control?.send(.failure(error.localizedDescription)) } }
                }
            case .releaseInput: input.releaseAll()
            case .pauseVideo(let paused):
                guard clientFeatures & StreamFeature.pauseVideo != 0 else { throw DeskError.invalid("Unexpected pause request.") }
                // The iPad went to the background: nothing it holds may stay pressed on the Mac.
                if paused { input.releaseAll() }
                capture?.setPaused(paused)
                bitrateController?.startGrace(1.5)
                audio?.setPaused(paused)
                MetricsLog.shared.append(paused ? "host  iPad in background: input released, video paused" : "host  iPad back: video resumed with keyframe")
                status = paused ? "iPad is in the background · video paused" : (capture.map { "\($0.info.width) × \($0.info.height) · streaming to iPad" } ?? status)
            case .clipboard(let text):
                let limit = clipboard != nil ? ClipboardSync.maxBytes : 8192
                guard text.utf8.count <= limit else { throw DeskError.invalid("Clipboard text is too large.") }
                guard allowClipboard else { return }
                if var sync = clipboard {
                    if sync.incoming(text) {
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
                        sync.wroteRemote(changeCount: NSPasteboard.general.changeCount)
                    }
                    clipboard = sync
                } else { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
            case .scrollMomentum(let vx, let vy):
                guard clientFeatures & StreamFeature.scrollMomentum != 0, vx.isFinite, vy.isFinite else { throw DeskError.invalid("Invalid scroll.") }
                if allowInput, capture != nil { input.startMomentum(velocity: CGPoint(x: vx, y: vy)) }
            case .deviceKeyRequest(let request):
                guard clientFeatures & StreamFeature.deviceKeys != 0 else { throw DeskError.invalid("Unexpected key request.") }
                // With password pairing off, an iPad may only renew its own key, never add another device.
                guard passwordPairingActive || request.device == currentDevice else { return }
                issueDeviceKey(request)
            case .datagramVideoStopped:
                guard clientFeatures & StreamFeature.datagramVideo != 0 else { throw DeskError.invalid("Unexpected transport message.") }
                router.giveUp()
            case .gesture(let gesture):
                guard clientFeatures & StreamFeature.gestures != 0, gesture.isValid else { throw DeskError.invalid("Invalid gesture.") }
                if allowInput, capture != nil { input.handle(gesture) }
            case .updateRequest:
                guard clientFeatures & StreamFeature.remoteUpdate != 0 else { throw DeskError.invalid("Unexpected update request.") }
                // The user chose to update: the Mac follows the moment this iPad disconnects (user request 2026-11-13).
                // An iPad that waits for `updateDownload` may still leave its prompt unanswered, so for those the
                // Mac only follows once iPadOS has fetched the app (2026-11-15: the Mac went to 43 alone).
                updateWhenPadDrops = clientFeatures & StreamFeature.updateSignals == 0
                verifyStagedHost()
                serveUpdate()
            case .updateCertificateRequest:
                guard clientFeatures & StreamFeature.remoteUpdate != 0 else { throw DeskError.invalid("Unexpected update request.") }
                sendCertificate()
            case .setLocalCursor(let enabled):
                guard clientFeatures & StreamFeature.liveCursorToggle != 0, let capture else { return }
                setLocalCursor(enabled && allowInput, capture: capture)
            case .clipboardRequest:
                if allowClipboard {
                    let text = NSPasteboard.general.string(forType: .string) ?? ""
                    if text.utf8.count <= 8192 { control?.send(.clipboard(text)) }
                    else { control?.send(.failure("Mac clipboard exceeds the 8 KiB text limit.")) }
                } else { control?.send(.failure("Clipboard sharing is disabled on the Mac.")) }
            default: throw DeskError.invalid("Unexpected control message.")
            }
        } catch { channel.close(reason: error.localizedDescription) }
    }
    private func beginCapture() {
        guard !startingCapture, capture == nil, let video, let control, let sessionID else { return }
        startingCapture = true
        let token = generation
        clientConnected = true
        status = "Connecting to your iPad…"
        Task { [self, video, control] in
            do {
                await refreshDisplays()
                guard generation == token, self.sessionID == sessionID else { return }
                guard screenAllowed else {
                    throw DeskError.invalid("SkyDesk on the Mac needs Screen Recording permission. On the Mac: open SkyDesk Host and click Allow.")
                }
                if allowInput && !inputAllowed {
                    throw DeskError.invalid("SkyDesk on the Mac needs Accessibility permission for your touches and keys. On the Mac: open SkyDesk Host and click Allow.")
                }
                var selectedDisplay = displays.first(where: { $0.displayID == displayID })
                var resumedKept = false
                if !useiPadDesktop { releaseKeptDesktop(reason: "mirroring the Mac display instead") }
                let sessionFPS = min(fps, (clientDisplay?.maximumFPS ?? fps) >= 120 ? 120 : (clientDisplay?.maximumFPS ?? fps) >= 60 ? 60 : 30)
                if useiPadDesktop {
                    guard let clientDisplay else { throw DeskError.invalid("Update SkyDesk on iPad to create its Retina desktop, or choose Mirror Mac display.") }
                    let shape = KeptDesktop.Shape(width: Int(clientDisplay.width), height: Int(clientDisplay.height), fps: sessionFPS)
                    let virtual: SkyDeskVirtualDisplay
                    if let kept = keptDesktop, KeptDesktop.canReuse(kept: kept.shape, wanted: shape, padOnly: displayController.isSettled) {
                        // The desktop this iPad left is still the Mac's only display: carry on with it as it is.
                        virtual = kept.display; keptDesktop = nil; desktopKept = false; resumedKept = true
                        keptDesktopLimit?.cancel(); keptDesktopLimit = nil
                        virtualDisplay = virtual; sessionShape = shape
                        MetricsLog.shared.append("host  iPad returned to its kept desktop; no display switch needed")
                    } else {
                        releaseKeptDesktop(reason: "the connecting iPad needs a different desktop")
                        virtual = try SkyDeskVirtualDisplay(pixelWidth: UInt32(clientDisplay.width),
                                                            height: UInt32(clientDisplay.height), refreshRate: Double(sessionFPS))
                        virtualDisplay = virtual; sessionShape = shape
                        try await Task.sleep(nanoseconds: 100_000_000)
                        guard generation == token, self.sessionID == sessionID else { discard(virtual); return }
                        try virtual.activate()
                    }
                    for _ in 0..<20 {
                        let available = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true).displays
                        guard generation == token, self.sessionID == sessionID else { discard(virtual); return }
                        if let match = available.first(where: { $0.displayID == virtual.displayID }) { selectedDisplay = match; break }
                        try await Task.sleep(nanoseconds: 100_000_000)
                    }
                    guard selectedDisplay?.displayID == virtual.displayID,
                          let mode = CGDisplayCopyDisplayMode(virtual.displayID),
                          mode.pixelWidth == clientDisplay.width, mode.pixelHeight == clientDisplay.height,
                          mode.width * 2 == mode.pixelWidth, mode.height * 2 == mode.pixelHeight else {
                        throw DeskError.invalid("macOS did not provide the requested Retina display mode.")
                    }
                }
                guard let display = selectedDisplay else { throw DeskError.invalid("Select an available Mac display.") }
                @MainActor func makePipeline(chroma444: Bool) throws -> DisplayCapture {
                    try DisplayCapture(display: display, longestEdge: useiPadDesktop ? 4096 : longestEdge, fps: sessionFPS,
                        bitrate: bitrateMbps * 1_000_000, inputEnabled: allowInput, lowLatencyRateControl: lowLatencyRateControl,
                        nativeDesktop: useiPadDesktop, clientFeatures: clientFeatures, hostName: Host.current().localizedName,
                        clipboard: allowClipboard, files: allowFiles, audio: allowAudio && HostAudio.supported, chroma444: chroma444,
                        preferSpeed: fastEncoding)
                }
                // The iPad asked for full colour detail: use it if this Mac's encoder has it, otherwise carry on as before.
                let wants444 = clientFeatures & StreamFeature.chroma444 != 0
                let pipeline: DisplayCapture
                if wants444, let full = try? makePipeline(chroma444: true) {
                    pipeline = full
                    MetricsLog.shared.append("host  video in full colour detail (4:4:4)")
                } else {
                    if wants444 { MetricsLog.shared.append("host  4:4:4 is not available on this Mac's encoder; using 4:2:0") }
                    pipeline = try makePipeline(chroma444: false)
                }
                // UDP only for the session that agreed to it; the router starts every session on TCP.
                let datagrams = (pipeline.info.features ?? 0) & StreamFeature.datagramVideo != 0 && datagramListener != nil
                router.onPathChange = { usingUDP, reason in
                    MetricsLog.shared.append(usingUDP ? "host  video now over UDP" : "host  video back on TCP" + (reason.map { ": \($0)" } ?? ""))
                }
                router.begin(session: datagrams ? sessionID : nil, tcp: video, bitrate: pipeline.info.bitrate)
                let router = router
                fastPath.bind(frameAcknowledged: { router.acknowledge($0) })
                pipeline.onFrame = { frame in router.send(frame) }
                pipeline.onFailure = { [weak self] reason in
                    Task { @MainActor in
                        guard let self, self.generation == token, self.sessionID == sessionID else { return }
                        self.disconnect(); self.status = reason
                    }
                }
                capture = pipeline
                fastPath.bind(window: pipeline.window)
                input.displayBounds = CGDisplayBounds(display.displayID)
                var welcome = pipeline.info
                if (welcome.features ?? 0) & StreamFeature.deviceKeys != 0 { welcome.hostID = hostID }
                control.send(.welcome(welcome))
                // iPad only is already on, so the iPad shows it that way and does not ask for the switch again.
                if resumedKept { control.send(.macDisplayBlanked(true)) }
                if let suite = control.negotiatedSuite {
                    MetricsLog.shared.append("host  connection secured with " + (suite == DeskNetwork.forwardSecretSuite ? "forward secrecy" : "the pre-37 key exchange"))
                }
                ContinuityLink.suspend()
                try await pipeline.start()
                guard generation == token, self.sessionID == sessionID else { await pipeline.stop(); return }
                if allowInput, clientDisplay != nil {
                    let monitor = RemoteFocusMonitor(bounds: input.displayBounds)
                    monitor.onFocus = { [weak self, weak control] focus in
                        Task { @MainActor in
                            guard let self, self.generation == token, self.sessionID == sessionID else { return }
                            control?.send(.textFocus(focus))
                        }
                    }
                    focusMonitor = monitor; monitor.start()
                }
                let agreed = pipeline.info.features ?? 0
                if agreed & StreamFeature.localCursor != 0 { startCursorMonitor() }
                if agreed & StreamFeature.pointerHeldSignal != 0 {
                    input.onPointerHeld = { [weak self, weak control] held in
                        guard let self, self.generation == token, self.sessionID == sessionID else { return }
                        control?.send(.pointerHeld(held))
                    }
                }
                if agreed & StreamFeature.clipboardSync != 0 { startClipboardSync() }
                if agreed & StreamFeature.remoteUpdate != 0 { offeredBuild = nil; offerUpdateIfNeeded() }
                if adaptiveBitrate { startBitrateControl(maximum: pipeline.info.bitrate) }
                status = "Streaming to iPad · \(pipeline.info.width) × \(pipeline.info.height) · \(sessionFPS) FPS"
                startingCapture = false
            } catch {
                guard generation == token, self.sessionID == sessionID else { return }
                // Tell the iPad why before closing, so it can show the reason instead of a bare disconnect.
                let reason = error.localizedDescription
                control.send(.failure(reason))
                startingCapture = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    guard let self, self.generation == token, self.sessionID == sessionID else { return }
                    self.disconnect(); self.status = reason
                }
            }
        }
    }
    /// Connections that never became part of a session, for the log: a wrong key, or a handshake never finished.
    private var refusedAttempts: [Date] = []
    private var lastRefusalNote = Date.distantPast
    /// When each address last started a real session.
    private var acceptedFrom: [String: Date] = [:]
    private static func address(of connection: NWConnection) -> String {
        if case .hostPort(let host, _) = connection.endpoint { return "\(host)".components(separatedBy: "%").first ?? "unknown address" }
        return "unknown address"
    }
    private func noteRefused(_ connection: NWConnection, reason: String) {
        let from = Self.address(of: connection), at = Date()
        // The iPad's own "which address answers?" probe opens a connection and closes it without a handshake, which
        // looks the same from here as a wrong key (build 41 logged it as one). Wait a moment: an address that
        // goes on to start a session was only asking.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self else { return }
            if let accepted = self.acceptedFrom[from], abs(accepted.timeIntervalSince(at)) < 5 { return }
            let now = Date()
            self.refusedAttempts = self.refusedAttempts.filter { now.timeIntervalSince($0) < 60 } + [at]
            guard now.timeIntervalSince(self.lastRefusalNote) >= 10 else { return }
            self.lastRefusalNote = now
            MetricsLog.shared.append("host  refused a connection from \(from) (\(reason)); \(self.refusedAttempts.count) refused in the last minute")
        }
    }

    // MARK: Adaptive bitrate

    private func startBitrateControl(maximum: Int) {
        var controller = BitrateController(maximum: maximum)
        controller.startGrace(1.5)
        bitrateController = controller
        lastBitrateSample = monotonicNanos()
        _ = capture?.window.drainTransit()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.adjustBitrate() } }
        RunLoop.main.add(timer, forMode: .common); bitrateTimer = timer
    }
    private func adjustBitrate() {
        guard let capture, var controller = bitrateController else { return }
        let now = monotonicNanos()
        let seconds = Double(now &- lastBitrateSample) / 1_000_000_000
        lastBitrateSample = now
        let transit = capture.window.drainTransit()
        guard !capture.isPaused else { return }
        let before = controller.target
        let changed = controller.update(.init(seconds: seconds, transitMS: transit.meanMS, acknowledged: transit.count,
                                              backlogBytes: video?.backlogBytes ?? 0, deliveredBytes: transit.bytes,
                                              roundTripMS: fastPath.roundTripMS(), resentShare: router.resentShare))
        router.measure()
        bitrateController = controller
        guard let changed else { return }
        capture.setBitrate(changed)
        router.bitrate = changed
        // Every real cut is logged with its cause; the climb back only when it reaches the setting again.
        if Double(changed) < Double(before) * 0.95 {
            MetricsLog.shared.append(String(format: "host  bitrate %.1f → %.1f Mbps (%@)", Double(before) / 1e6, Double(changed) / 1e6, controller.reason))
        } else if changed == controller.maximum {
            MetricsLog.shared.append(String(format: "host  bitrate back to %.1f Mbps", Double(changed) / 1e6))
        }
    }

    // MARK: Pointer, clipboard and files

    private func startCursorMonitor() {
        guard cursorMonitor == nil, let control else { return }
        let cursors = CursorMonitor(desktop: input.displayBounds.size)
        cursors.onCursor = { [weak control] in control?.send(.cursor($0)) }
        cursorMonitor = cursors; cursors.start()
    }
    /// The iPad switched its own pointer on or off: hide or show the Mac pointer in the video to match.
    private func setLocalCursor(_ enabled: Bool, capture: DisplayCapture) {
        if enabled { startCursorMonitor() } else { cursorMonitor?.stop(); cursorMonitor = nil }
        let session = sessionID
        Task {
            do { try await capture.setShowsCursor(!enabled) }
            catch { if sessionID == session { control?.send(.failure("Couldn't switch the pointer: \(error.localizedDescription)")) } }
        }
        MetricsLog.shared.append("host  iPad pointer " + (enabled ? "on (Mac pointer hidden in video)" : "off (Mac pointer in video)"))
    }
    /// Polls the change counter only; the text is read when it moves (and wasn't our own write).
    private func startClipboardSync() {
        clipboard = ClipboardSync(changeCount: NSPasteboard.general.changeCount)
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.checkClipboard() } }
        RunLoop.main.add(timer, forMode: .common); clipboardTimer = timer
    }
    private func checkClipboard() {
        guard var sync = clipboard, allowClipboard, let control else { return }
        let pasteboard = NSPasteboard.general
        if sync.localChanged(changeCount: pasteboard.changeCount), let text = sync.outgoing(pasteboard.string(forType: .string)) {
            control.send(.clipboard(text))
        }
        clipboard = sync
    }
    private func openFiles(on channel: SecureChannel) {
        let engine = FileTransferEngine(directory: Self.downloads, queue: DispatchQueue(label: "skydesk.host.files", qos: .utility))
        engine.sendMessage = { [weak channel] in channel?.send($0) }
        engine.sendPacket = { [weak channel] packet, done in
            guard let channel else { done(false); return }
            channel.send(packet, completion: done)
        }
        engine.onProgress = { [weak self] progress in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.record(progress) } }
        }
        files = channel; fileEngine = engine; filesReady = true
        fileRoute.set(channel.id, engine: engine)
    }
    private func record(_ progress: FileTransferEngine.Progress) {
        if let index = transfers.firstIndex(where: { $0.id == progress.id }) { transfers[index] = progress }
        else { transfers.insert(progress, at: 0); if transfers.count > 20 { transfers.removeLast() } }
        if case .saved(let name) = progress.state, !progress.outgoing {
            MetricsLog.shared.append("host  received file from iPad: \(progress.size) bytes")
            NSWorkspace.shared.noteFileSystemChanged(Self.downloads.appendingPathComponent(name).path)
        }
    }
    /// Files dropped on the window or chosen in the open panel go to the iPad's SkyDesk folder.
    func sendFiles(_ urls: [URL]) {
        guard let fileEngine, filesReady else { status = "Connect your iPad (with the latest SkyDesk) to send files."; return }
        for url in urls { fileEngine.send(fileAt: url) }
    }
    // MARK: Wireless updates

    private var updateTicks = 0
    private func checkForUpdate() {
        updateTicks += 1
        guard updateTicks % 5 == 1 else { return }
        let info = UpdateInfo.load(from: Self.updateFolder)
        stagedBuild = info.map(\.build).flatMap { $0 > ownBuild || $0 > knownPadBuild ? $0 : nil }
        offerUpdateIfNeeded()
        // The Mac cannot replace itself while iPad only is on, so a waiting update ends a kept desktop first.
        if autoUpdateMacReady, keptDesktop != nil { releaseKeptDesktop(reason: "a Mac update is waiting") }
        else if autoUpdateMacReady { updateMacNow() }
    }
    private var stagedHostApp: URL? {
        let url = Self.updateFolder.appendingPathComponent(UpdateInfo.hostAppName)
        guard let info = UpdateInfo.load(from: Self.updateFolder), info.build > ownBuild,
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }
    var macUpdateAvailable: Bool { stagedHostApp != nil }
    /// iPad first, then the Mac: the Mac waits until the iPad has the staged build (or the update has no iPad part),
    /// and only replaces itself with no iPad connected, no iPad-only mode, and 10 s after the last session.
    private var autoUpdateMacReady: Bool {
        !clientConnected && !updating && Date().timeIntervalSince(lastSessionEnd) > 10 && macUpdateDue
    }
    /// A newer Mac build is staged and no iPad still has to take its part first.
    private var macUpdateDue: Bool {
        guard stagedHostApp != nil, let info = UpdateInfo.load(from: Self.updateFolder) else { return false }
        let hasPadPart = FileManager.default.fileExists(atPath: Self.updateFolder.appendingPathComponent(UpdateInfo.ipaName).path)
        return !hasPadPart || knownPadBuild >= info.build
    }
    private var updateWhenPadDrops = false
    /// The staged build the running update server describes; a different staged build gets a fresh server.
    private var updateServerBuild = 0
    /// Right after the iPad drops; only waits (up to 30 s) while the iPad-only display restore finishes.
    private func updateAfterDrop(attempt: Int) {
        guard stagedHostApp != nil, !clientConnected, !updating else { return }
        if Self.displayRestoreRunning() {
            if attempt < 60 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.updateAfterDrop(attempt: attempt + 1) } }
            return
        }
        updateMacNow()
    }
    /// Staged host app path → build that passed the signature check.
    private var verifiedStaged: (path: String, build: Int)?
    private func verifyStagedHost() {
        guard let staged = stagedHostApp, let build = UpdateInfo.load(from: Self.updateFolder)?.build,
              verifiedStaged?.path != staged.path || verifiedStaged?.build != build else { return }
        Task {
            let ok = await Task.detached(priority: .utility) { SelfUpdater.verify(staged) }.value
            if ok { verifiedStaged = (staged.path, build) }
            else { MetricsLog.shared.append("host  staged Mac update failed its signature check; not installing it") }
        }
    }
    func updateMacNow() {
        guard let staged = stagedHostApp, !clientConnected, !updating else { return }
        releaseKeptDesktop(reason: "updating the Mac")
        guard !Self.displayRestoreRunning() else { status = "Waiting for the Mac's displays to be restored before updating."; return }
        let build = UpdateInfo.load(from: Self.updateFolder)?.build ?? 0
        if !(verifiedStaged?.path == staged.path && verifiedStaged?.build == build) {
            guard SelfUpdater.verify(staged) else { status = "The Mac update failed its signature check, so it wasn't installed."; return }
        }
        updating = true
        status = "Updating SkyDesk… it will reopen in a few seconds."
        MetricsLog.shared.append("host  self-update to staged build starting")
        do {
            try SelfUpdater.replace(with: staged)
            willRelaunch?()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
        } catch { updating = false; status = "Update failed: \(error.localizedDescription)" }
    }
    private static func displayRestoreRunning() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep"); process.arguments = ["-f", "SkyDeskRestore"]
        process.standardOutput = FileHandle.nullDevice
        do { try process.run(); process.waitUntilExit() } catch { return true }
        return process.terminationStatus == 0
    }
    private func offerUpdateIfNeeded() {
        guard clientFeatures & StreamFeature.remoteUpdate != 0, capture != nil, let control,
              let info = UpdateInfo.load(from: Self.updateFolder), info.build > (clientBuild ?? 0), offeredBuild != info.build,
              FileManager.default.fileExists(atPath: Self.updateFolder.appendingPathComponent(UpdateInfo.ipaName).path) else { return }
        offeredBuild = info.build
        control.send(.updateAvailable(info.build))
    }
    /// Starts (or reuses) the HTTPS server and tells the iPad where the manifest is.
    private func serveUpdate() {
        guard let info = UpdateInfo.load(from: Self.updateFolder) else { control?.send(.failure("No update is waiting on the Mac.")); return }
        let ipa = Self.updateFolder.appendingPathComponent(UpdateInfo.ipaName)
        // The address the iPad already reaches this Mac on.
        var host: String?
        if let local = control?.connection.currentPath?.localEndpoint, case .hostPort(let h, _) = local, case .ipv4(let ip) = h {
            host = "\(ip)".components(separatedBy: "%").first
        }
        guard let host else { control?.send(.failure("Wireless updates need a Wi-Fi (IPv4) connection.")); return }
        // The update certificate only covers private addresses; on any other (some VPNs) the iPad would be sent
        // to a server it can never trust and go round in circles asking for the certificate.
        guard UpdateCertificates.allowed(host) else {
            control?.send(.failure("Updates can't be installed over this connection (\(host) is not a private network address). Connect over your home network to update."))
            return
        }
        let addresses = Array(Set([host] + lanAddresses.map(\.address)))
        let session = sessionID
        // A second tap reuses the running server (opening the port twice failed with "address already in use").
        if let server = updateServer, !server.stopped, server.host == host, updateServerBuild == info.build {
            control?.send(.updateReady(UpdateServer.url(host: host, port: UpdatePort.https, token: server.token, file: "manifest.plist").absoluteString))
            return
        }
        let previous = updateServer
        previous?.stop(); updateServer = nil
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<SecIdentity, Error> in
                Result { try UpdateCertificates.identity(for: addresses) }
            }.value
            // Give a stopped server's port a moment to be released.
            if previous != nil { try? await Task.sleep(nanoseconds: 800_000_000) }
            guard sessionID == session else { return }
            do {
                let identity = try result.get()
                let server = try UpdateServer(identity: identity, manifest: { url in
                    try UpdateManifest.plist(ipaURL: url, bundleID: "com.skylar.skydesk.pad", version: "0.1.0 (\(info.build))", title: "SkyDesk")
                }, ipa: ipa, baseHost: host)
                server.onLog = { MetricsLog.shared.append("host  " + $0) }
                // A finished download is not an install: the iPad's build is only trusted from its next hello
                // (build 21 marked 22 as installed after a download iPadOS never installed, 2026-11-13).
                server.onIPAServed = { [weak self] in
                    MetricsLog.shared.append("host  iPad downloaded build \(info.build); waiting for it to report that build")
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.noteUpdateDownload(finished: true) } }
                }
                server.onIPAStarted = { [weak self] in
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.noteUpdateDownload(finished: false) } }
                }
                updateServer = server; updateServerBuild = info.build
                let manifest = UpdateServer.url(host: host, port: UpdatePort.https, token: server.token, file: "manifest.plist")
                server.start { [weak self] error in
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            guard let self, self.sessionID == session else { return }
                            if let error { self.control?.send(.failure("The Mac couldn't start the update server: \(error.localizedDescription)")) }
                            else { self.control?.send(.updateReady(manifest.absoluteString)) }
                        }
                    }
                }
                // The download link is only needed for a few minutes.
                DispatchQueue.main.asyncAfter(deadline: .now() + 900) { [weak self, weak server] in
                    if let server, self?.updateServer === server { server.stop(); self?.updateServer = nil }
                }
            } catch { control?.send(.failure(error.localizedDescription)) }
        }
    }
    /// Tells the iPad that iPadOS is fetching the update, so it knows the prompt was answered and can step aside.
    /// Not tied to the session that asked: the iPad may have reconnected while its prompt was up.
    private func noteUpdateDownload(finished: Bool) {
        guard clientConnected, clientFeatures & StreamFeature.updateSignals != 0 else { return }
        updateWhenPadDrops = true
        control?.send(.updateDownload(finished))
    }
    private func sendCertificate() {
        guard let fileEngine, filesReady else { control?.send(.failure("Reconnect to get the update certificate (file transfer is off or still starting).")); return }
        let name = Host.current().localizedName ?? "your Mac"
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<URL, Error> in
                Result {
                    let profile = try UpdateManifest.profile(caDER: try UpdateCertificates.caDER(), macName: name)
                    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let file = folder.appendingPathComponent("SkyDesk Updates.mobileconfig")
                    try profile.write(to: file)
                    return file
                }
            }.value
            switch result {
            case .success(let file): fileEngine.send(fileAt: file)
            case .failure(let error): control?.send(.failure(error.localizedDescription))
            }
        }
    }
    func refreshInputGeometry() {
        guard capture != nil else { return }
        let id = virtualDisplay?.displayID ?? displayID
        let bounds = CGDisplayBounds(id)
        guard bounds.width > 0, bounds.height > 0 else { return }
        input.displayBounds = bounds
        focusMonitor?.updateBounds(bounds)
    }
    private func tick() {
        refreshPermissions()
        checkForUpdate()
        if allowInput && !inputAllowed && capture != nil { input.releaseAll(); displayController.restore(reason: "remote input permission lost") }
        if control != nil && Date().timeIntervalSince(lastHeartbeat) > 5 { disconnect(.padLeft); status = "Client timed out; remote keys released."; return }
        guard let capture else { return }
        ContinuityLink.suspend()
        let stats = capture.statistics()
        let now = Date(); let elapsed = max(0.001, now.timeIntervalSince(lastMetrics)); lastMetrics = now
        metrics = String(format: "%.0f capture / %.0f encoded FPS · %.0f skipped/s · %.1f ms encode · %.1f ms feedback · %d in-flight limit",
                         Double(stats.captured) / elapsed, Double(stats.frames) / elapsed, Double(stats.skipped) / elapsed, stats.encodeMS,
                         capture.window.feedbackMilliseconds, capture.window.currentLimit)
        if router.usingUDP {
            metrics += " · video over UDP" + (router.resentShare.map { $0 >= 0.005 ? String(format: " (%.1f%% sent twice)", $0 * 100) : "" } ?? "")
                + (router.parityOn ? " + parity" : "")
        }
        if let controller = bitrateController, controller.target < controller.maximum {
            metrics += String(format: " · bitrate limited to %.1f Mbps by the network", Double(controller.target) / 1e6)
        }
        MetricsLog.shared.append(String(format: "host  %@ · %.1f Mbps encoded", metrics, Double(stats.bytes) * 8 / elapsed / 1_000_000)
                                 + (audio?.statisticsText().map { " · " + $0 } ?? ""))
        if let age = capture.window.oldestAge(), age > 5_000_000_000 { disconnect(.padLeft); status = "Video stalled; reconnect the iPad." }
    }
}

/// Which channel carries files, readable from the transport queue.
final class FileRoute: @unchecked Sendable {
    private let lock = NSLock()
    private var channelID: UUID?
    private var current: FileTransferEngine?
    func set(_ id: UUID?, engine: FileTransferEngine?) { lock.withLock { channelID = id; current = engine } }
    func engine(for id: UUID) -> FileTransferEngine? { lock.withLock { channelID == id ? current : nil } }
}
