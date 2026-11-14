import SwiftUI
import Network
import UIKit

struct DiscoveredHost: Identifiable {
    let id: String
    let name: String
    let endpoint: NWEndpoint
}

/// One way of reaching a Mac with a credential ready to use.
struct ConnectTarget {
    let endpoint: NWEndpoint
    /// What the user sees: the Mac's name or address.
    let label: String
    /// The address typed or remembered, if any (Bonjour-only targets have none until connected).
    let address: String?
    let serviceName: String?
    let key: PairingKey
    /// Only for nearby (Bonjour) Macs: try a USB/Ethernet route first.
    var cableFirst = false
}

/// Asks several addresses at once whether SkyDesk answers there: a plain TCP connection to its port, closed at
/// once. Nothing is sent, so no password or key is involved. Main thread only.
final class AddressProbe {
    private var connections: [NWConnection] = []
    private var race = AddressRace(count: 0)
    private var reported: Set<Int> = []
    private var completion: ((Int?) -> Void)?
    func start(_ endpoints: [NWEndpoint], timeout: TimeInterval = 2.5, completion: @escaping (Int?) -> Void) {
        self.completion = completion
        race = AddressRace(count: endpoints.count)
        for (index, endpoint) in endpoints.enumerated() {
            let tcp = NWProtocolTCP.Options(); tcp.connectionTimeout = Int(timeout.rounded(.up))
            let connection = NWConnection(to: endpoint, using: NWParameters(tls: nil, tcp: tcp))
            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready: self?.report(index, answered: true)
                case .failed, .waiting: self?.report(index, answered: false)
                default: break
                }
            }
            connections.append(connection)
            connection.start(queue: .main)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in self?.finish(self?.race.best) }
    }
    private func report(_ index: Int, answered: Bool) {
        guard completion != nil, reported.insert(index).inserted else { return }
        switch answered ? race.answered(index) : race.failed(index) {
        case .wait: break
        case .waitBriefly: DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in self?.finish(self?.race.best) }
        case .choose(let choice): finish(choice)
        }
    }
    private func finish(_ choice: Int?) {
        guard let completion else { return }
        cancel()
        completion(choice)
    }
    func cancel() {
        completion = nil
        connections.forEach { $0.stateUpdateHandler = nil; $0.cancel() }
        connections = []
    }
}

/// Only touched on the video queue.
private final class VideoGate {
    var paused = false
    var needKeyframe = false
}

@MainActor
final class ClientModel: ObservableObject {
    @Published var hosts: [DiscoveredHost] = []
    @Published private(set) var recents = RecentHostList.load(from: .standard)
    @Published var manualHost = ""
    /// A nearby Mac chosen in the list that still needs a password.
    @Published var selectedHost = ""
    @Published var pairingText = ""
    @Published var status = ""
    @Published var connecting = false
    /// Set while an automatic connection runs (launch or return from background): shows the "Connecting" screen.
    @Published var autoConnectLabel: String?
    @Published var passwordNeeded = false
    @Published var info: StreamInfo?
    /// Twice-a-second statistics live in their own object: publishing them from here re-rendered the whole toolbar,
    /// and an open More menu re-laid out under the pointer ("jumps around", 2026-11-13).
    let stats = StreamStatsModel()
    @Published var showTimingDetails = false
    @Published var textFocus = RemoteTextFocus.none
    @Published var keyboardWanted = false
    @Published var automaticKeyboard = UserDefaults.standard.object(forKey: "automaticKeyboard") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(automaticKeyboard, forKey: "automaticKeyboard")
            if !automaticKeyboard { keyboardWanted = false }
        }
    }
    @Published var sharpenText = UserDefaults.standard.object(forKey: "sharpenText") as? Bool ?? true {
        didSet { UserDefaults.standard.set(sharpenText, forKey: "sharpenText") }
    }
    /// Draw each frame as soon as it arrives when it can still make the next screen refresh (build 35).
    @Published var presentOnArrival = UserDefaults.standard.object(forKey: "presentOnArrival") as? Bool ?? true {
        didSet { UserDefaults.standard.set(presentOnArrival, forKey: "presentOnArrival") }
    }
    @Published var preferCable = UserDefaults.standard.bool(forKey: "preferCable") {
        didSet { UserDefaults.standard.set(preferCable, forKey: "preferCable") }
    }
    /// The iPad draws the pointer itself (no network delay). On by default (user request, build 17); switchable live
    /// when the Mac supports StreamFeature.liveCursorToggle, otherwise from the next connection.
    @Published var localPointer = UserDefaults.standard.object(forKey: "localPointer") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(localPointer, forKey: "localPointer")
            guard oldValue != localPointer, let info else { return }
            if (info.features ?? 0) & StreamFeature.liveCursorToggle != 0 {
                control?.send(.setLocalCursor(localPointer)); localCursorActive = localPointer
            } else { notice = "The pointer setting applies the next time you connect." }
        }
    }
    /// Size of the iPad-drawn pointer relative to the Mac's (a Mac-sized pointer looked tiny on the iPad).
    /// 1 = the Mac's own pointer size ("Medium", the default; user 2026-11-13). New key, so the earlier 2× default is dropped.
    @Published var pointerScale = UserDefaults.standard.object(forKey: "pointerSize") as? Double ?? 1 {
        didSet { UserDefaults.standard.set(pointerScale, forKey: "pointerSize") }
    }
    /// Make the iPad the Mac's only screen as soon as a session starts (user request 2026-11-13), as if the user had
    /// pressed "iPad only". The Mac's own keyboard or trackpad still brings its screen back, as before.
    @Published var startIPadOnly = UserDefaults.standard.object(forKey: "startIPadOnly") as? Bool ?? true {
        didSet { UserDefaults.standard.set(startIPadOnly, forKey: "startIPadOnly") }
    }
    /// What the current session actually does (negotiated at connect, then switched live).
    @Published var localCursorActive = false
    @Published var syncClipboard = UserDefaults.standard.object(forKey: "syncClipboard") as? Bool ?? true {
        didSet { UserDefaults.standard.set(syncClipboard, forKey: "syncClipboard") }
    }
    /// Play the Mac's sound here (build 34). Switchable during a session when the Mac offers sound.
    @Published var playMacSound = UserDefaults.standard.object(forKey: "playMacSound") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(playMacSound, forKey: "playMacSound")
            guard oldValue != playMacSound, info != nil else { return }
            if playMacSound {
                if soundOffered, let target = activeTarget { openAudio(endpoint: target.endpoint, key: target.key, session: token) }
                else { notice = "This Mac isn't sending sound. Update SkyDesk on the Mac, or switch sound on in its Display & quality settings." }
            } else { closeAudio() }
        }
    }
    /// The Mac agreed to send sound in this session.
    var soundOffered: Bool { (info?.features ?? 0) & StreamFeature.audio != 0 }
    private var audioChannel: SecureChannel?
    private var audioPlayer: AudioPlayer?
    /// Newest first.
    @Published var transfers: [FileTransferEngine.Progress] = []
    @Published var filesReady = false
    /// A newer iPad build the Mac can install over Wi-Fi.
    @Published var updateBuild: Int?
    enum UpdateState: Equatable { case idle, preparing, needsCertificate, certificateArrived, installing, failed(String) }
    @Published var updateState = UpdateState.idle
    static let ownBuild = Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "") ?? 0
    private var clipboard: ClipboardSync?
    private var files: SecureChannel?
    private var fileEngine: FileTransferEngine?
    /// Files shared to SkyDesk before a Mac was connected; sent as soon as the file channel opens.
    private var queuedFiles: [URL] = []
    static let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    private static let outbox = FileManager.default.temporaryDirectory.appendingPathComponent("Outbox", isDirectory: true)
    @Published var showStats = UserDefaults.standard.object(forKey: "showStats") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showStats, forKey: "showStats") }
    }
    @Published var macDisplayBlanked = false
    @Published var changingMacDisplay = false
    @Published var networkSymbol = "network"
    @Published var networkDescription = "Network"
    @Published var lastTapRect: CGRect?
    @Published var remoteCursor: RemoteCursor?
    @Published var notice: String?
    @Published var mailbox = FrameMailbox()
    private var browser: NWBrowser?
    private var pathMonitor: NWPathMonitor?
    private var control: SecureChannel?
    private var video: SecureChannel?
    private var token = UUID()
    private var heartbeat: Timer?
    private var pinger: DispatchSourceTimer?
    private var connectedAt = Date()
    private var usingCable = false
    /// The session runs through a VPN tunnel (WireGuard and the like), so the toolbar shows that instead of Wi-Fi.
    private var usingVPN = false
    private var statsTick = 0
    private var awaitingTextFocus = false
    private var activeTarget: ConnectTarget?
    /// Where to reconnect when the app returns to the foreground.
    private var resumeTarget: ConnectTarget?
    private var autoDeadline: Date?
    private var autoDeadlineWork: DispatchWorkItem?
    private var inBackground = false
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var videoQueue: DispatchQueue?
    private var videoGate: VideoGate?
    private var decoder: HEVCDecoder?
    private var launched = false
    private var probe: AddressProbe?

    init() {
        if recents.entries.isEmpty { manualHost = UserDefaults.standard.string(forKey: "lastManualHost") ?? "" }
    }

    // MARK: Launch and discovery

    /// First appearance: start discovery, then try the most recent Mac straight away.
    func launch() {
        browse()
        guard !launched else { return }
        launched = true
        connectToMostRecent()
    }
    /// Tries the newest remembered Mac that has a saved password; does nothing on a first launch.
    private func connectToMostRecent() {
        guard info == nil, !connecting, probe == nil else { return }
        let candidates = automaticTargets
        guard let newest = candidates.first else { return }
        guard candidates.count > 1 else { start(newest, automatic: true); return }
        // Several remembered addresses (home Wi-Fi, a VPN address…): ask them all, use the newest that answers.
        autoConnectLabel = newest.label
        status = "Looking for \(newest.label)…"
        if autoDeadline == nil { armAutoDeadline(label: newest.label) }
        let probe = AddressProbe(); self.probe = probe
        probe.start(candidates.map(\.endpoint)) { [weak self] answered in
            guard let self, self.probe === probe else { return }
            self.probe = nil
            guard self.info == nil, !self.connecting else { return }
            // Nothing answered yet (the Mac may still be waking): keep trying the newest until the deadline.
            self.start(candidates[answered ?? 0], automatic: true)
        }
    }
    /// Remembered Macs with a saved password, newest first.
    private var automaticTargets: [ConnectTarget] {
        recents.entries.filter { credential(for: $0) != nil }.compactMap { target(for: $0) }
    }
    /// After a lost link or a return to the app: the address that just worked may be the wrong one now
    /// (left home, joined the VPN), so with several remembered addresses they are all asked again.
    private func reconnect(to target: ConnectTarget) {
        if automaticTargets.count > 1 { connectToMostRecent() } else { start(target, automatic: true) }
    }
    func browse() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjour(type: DeskNetwork.serviceType, domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in
                guard let self else { return }
                self.hosts = results.compactMap { result in
                    if case .service(let name, let type, let domain, _) = result.endpoint {
                        return DiscoveredHost(id: "\(name).\(type).\(domain)", name: name, endpoint: result.endpoint)
                    }
                    return nil
                }.sorted { $0.name < $1.name }
            }
        }
        browser.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state { Task { @MainActor in self?.status = "Can't search for Macs (\(error.localizedDescription)). Type the address instead." } }
        }
        self.browser = browser; browser.start(queue: .main)
    }

    // MARK: Credentials and targets

    private func credential(for recent: RecentHost) -> PairingKey? {
        (try? PairingStore.load(account: recent.keychainAccount)) ?? nil
    }
    private var lastCredential: PairingKey? { (try? PairingStore.load(account: RecentHostList.lastCredentialAccount)) ?? nil }
    func hasCredential(_ recent: RecentHost) -> Bool { credential(for: recent) != nil || lastCredential != nil }

    private func target(for recent: RecentHost) -> ConnectTarget? {
        guard let key = credential(for: recent) ?? lastCredential, let endpoint = Self.endpoint(recent.address) else { return nil }
        return ConnectTarget(endpoint: endpoint, label: recent.name, address: recent.address, serviceName: recent.serviceName, key: key)
    }
    static func endpoint(_ text: String) -> NWEndpoint? {
        var host = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return nil }
        var port = DeskNetwork.port
        // "10.0.0.5:48772" or "My-Mac.local:48772"; bare IPv6 addresses contain several colons and are left alone.
        if host.filter({ $0 == ":" }).count == 1, let colon = host.lastIndex(of: ":"), let value = UInt16(host[host.index(after: colon)...]) {
            port = value; host = String(host[..<colon])
        }
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return nil }
        return .hostPort(host: NWEndpoint.Host(host), port: nwPort)
    }

    /// One tap on a remembered Mac.
    func connect(recent: RecentHost) {
        guard !connecting, info == nil else { return }
        if var target = target(for: recent) {
            // Prefer the Bonjour name when the Mac is visible nearby: it survives DHCP address changes.
            if let name = recent.serviceName, let nearby = hosts.first(where: { $0.name == name }) {
                target = ConnectTarget(endpoint: nearby.endpoint, label: recent.name, address: recent.address, serviceName: name, key: target.key)
            }
            start(target, automatic: false)
        } else {
            manualHost = recent.address; selectedHost = ""; askForPassword(recent.name)
        }
    }
    /// One tap on a nearby Mac.
    func connect(discovered host: DiscoveredHost) {
        guard !connecting, info == nil else { return }
        let saved = recents.entry(serviceName: host.name).flatMap(credential(for:)) ?? lastCredential
        if let saved {
            var target = ConnectTarget(endpoint: host.endpoint, label: host.name, address: nil, serviceName: host.name, key: saved)
            target.cableFirst = preferCable
            start(target, automatic: false)
        } else {
            selectedHost = host.id; manualHost = ""; askForPassword(host.name)
        }
    }
    private func askForPassword(_ name: String) {
        passwordNeeded = true
        status = "Enter the password shown in SkyDesk on \(name)."
    }
    /// The "Add a Mac" form: address (or a selected nearby Mac) plus the password.
    func connectFromForm() {
        guard !connecting, info == nil else { return }
        let address = manualHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let nearby = address.isEmpty ? hosts.first(where: { $0.id == selectedHost }) : nil
        let endpoint: NWEndpoint
        if let nearby { endpoint = nearby.endpoint }
        else if let typed = Self.endpoint(address) { endpoint = typed }
        else { status = "Type your Mac's address (shown in SkyDesk on the Mac)."; return }
        let label = nearby?.name ?? address
        let typed = pairingText
        if typed.isEmpty {
            guard let saved = lastCredential else { askForPassword(label); return }
            start(ConnectTarget(endpoint: endpoint, label: label, address: nearby == nil ? address : nil,
                                serviceName: nearby?.name, key: saved, cableFirst: nearby != nil && preferCable), automatic: false)
            return
        }
        do { try PairingPassword.validate(typed) } catch { status = error.localizedDescription; passwordNeeded = true; return }
        connecting = true; status = "Checking password…"; notice = nil
        let attempt = UUID(); token = attempt
        Task {
            let derived = await Task.detached(priority: .userInitiated) { try? PairingPassword.deriveKey(typed) }.value
            guard token == attempt else { return }
            connecting = false
            guard let derived else { status = "That password can't be used."; return }
            start(ConnectTarget(endpoint: endpoint, label: label, address: nearby == nil ? address : nil,
                                serviceName: nearby?.name, key: derived, cableFirst: nearby != nil && preferCable), automatic: false)
        }
    }
    func forget(_ recent: RecentHost) {
        var list = recents
        if let removed = list.remove(id: recent.id) { PairingStore.delete(account: removed.keychainAccount) }
        recents = list; list.save(to: .standard)
    }
    /// Leaves the "Connecting" screen for the full connection screen.
    func cancelConnecting() {
        resumeTarget = nil
        endSession(reason: "Connection cancelled.")
    }

    // MARK: Session

    private func start(_ target: ConnectTarget, automatic: Bool) {
        guard info == nil else { return }
        probe?.cancel(); probe = nil
        if connecting { endSession(reason: nil) }
        if automatic {
            autoConnectLabel = target.label
            if autoDeadline == nil { armAutoDeadline(label: target.label) }
        }
        open(target, cableFirst: target.cableFirst)
    }
    /// True on the first launch of a new build (the Mac is usually restarting into its own update right then).
    private static let launchedNewBuild: Bool = {
        let last = UserDefaults.standard.integer(forKey: "lastRunBuild")
        UserDefaults.standard.set(ClientModel.ownBuild, forKey: "lastRunBuild")
        return last != 0 && last != ClientModel.ownBuild
    }()
    private var justUpdated = ClientModel.launchedNewBuild
    private func armAutoDeadline(label: String) {
        let seconds = AutoConnect.deadline(justUpdated: justUpdated)
        justUpdated = false
        let deadline = Date().addingTimeInterval(seconds)
        autoDeadline = deadline
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, self.autoDeadline == deadline, self.info == nil else { return }
                self.endSession(reason: "Couldn't reach \(label) within \(Int(seconds)) seconds. Is SkyDesk open on your Mac?")
            }
        }
        autoDeadlineWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }
    private func clearAutoDeadline() {
        autoDeadlineWork?.cancel(); autoDeadlineWork = nil; autoDeadline = nil; autoConnectLabel = nil
    }

    /// A USB cable between the iPad and the Mac is a sub-millisecond link, so it is tried before Wi-Fi when enabled.
    private func open(_ target: ConnectTarget, cableFirst: Bool) {
        let key = target.key
        let endpoint = target.endpoint
        let cableAttempt = cableFirst && target.serviceName != nil
        let parameters = { cableAttempt ? DeskNetwork.wiredParameters(key: key) : DeskNetwork.parameters(key: key) }
        let session = UUID(); token = session
        activeTarget = target
        // Time the app spent suspended is not a hang: restart the watchdog's clock for the new session
        // (it reported "29211 s" after a night asleep, 2026-11-13 08:40).
        Breadcrumb.heartbeat()
        let display = Self.currentDisplay()
        connecting = true; passwordNeeded = false; status = "Connecting to \(target.label)…"; notice = nil
        UIDevice.current.isBatteryMonitoringEnabled = true
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self, self.token == session else { return }
                if self.usingCable || self.usingVPN { return }
                let wifi = path.usesInterfaceType(.wifi)
                self.networkSymbol = path.status == .satisfied ? (wifi ? "wifi" : "network") : "wifi.slash"
                self.networkDescription = path.status == .satisfied ? (wifi ? "Wi-Fi connected" : "Network connected") : "Network unavailable"
            }
        }
        pathMonitor = monitor; monitor.start(queue: DispatchQueue(label: "skydesk.network-status"))
        let mailbox = FrameMailbox(); self.mailbox = mailbox
        // Off the main thread: frame acknowledgements and RTT pings must not wait behind UI and rendering work.
        let controlQueue = DispatchQueue(label: "skydesk.control", qos: .userInteractive)
        let control = SecureChannel(connection: NWConnection(to: endpoint, using: parameters()), queue: controlQueue,
                                    maxPendingBytes: 256 * 1024, failWhenWaiting: cableAttempt)
        let videoQueue = DispatchQueue(label: "skydesk.decode", qos: .userInteractive)
        let video = SecureChannel(connection: NWConnection(to: endpoint, using: parameters()), queue: videoQueue, failWhenWaiting: cableAttempt)
        self.control = control; self.video = video
        #if targetEnvironment(simulator)
        let decoder = HEVCDecoder(requireHardware: false)
        #else
        let decoder = HEVCDecoder()
        #endif
        let gate = VideoGate()
        self.videoQueue = videoQueue; self.videoGate = gate; self.decoder = decoder
        var features = StreamFeature.idleGapFlags | StreamFeature.pauseVideo | StreamFeature.liveCursorToggle
            | StreamFeature.clipboardSync | StreamFeature.fileTransfer | StreamFeature.scrollMomentum | StreamFeature.remoteUpdate
            | StreamFeature.gestures | StreamFeature.audio
        if localPointer { features |= StreamFeature.localCursor }
        control.onReady = { [weak control] in
            control?.send(.hello(Hello(session: session, role: .control, display: display, features: features, appBuild: Self.ownBuild)))
        }
        video.onReady = { [weak video] in video?.send(.hello(Hello(session: session, role: .video))) }
        let statistics = mailbox.statistics
        control.onPacket = { [weak self, weak control] packet in
            let message: Result<ControlMessage, Error> = Result { try packet.controlMessage() }
            if case .success(.pong(let sent)) = message {
                // Timed on the transport queue so main-thread load is not reported as network delay.
                if !statistics.recordPong(sentAt: sent) { control?.close(reason: "Invalid heartbeat.") }
                return
            }
            DispatchQueue.main.async {
            guard let self, self.token == session else { return }
            Breadcrumb.mark("control:message"); defer { Breadcrumb.mark("control:end") }
            do {
                switch try message.get() {
                case .welcome(let info):
                    try info.validate()
                    self.info = info; self.connecting = false; self.status = "Connected"
                    self.clearAutoDeadline()
                    if let path = control?.connection.currentPath {
                        switch LinkKind.of(interfaces: path.availableInterfaces.map(\.name), wifi: path.usesInterfaceType(.wifi),
                                           cellular: path.usesInterfaceType(.cellular)) {
                        case .vpn:
                            self.usingVPN = true
                            self.networkSymbol = "lock.shield"; self.networkDescription = "VPN connected"
                        case .cable:
                            self.usingCable = true
                            self.networkSymbol = "cable.connector"; self.networkDescription = "USB cable connected"
                        case .wireless: break
                        }
                    }
                    self.remember(target, info: info, path: control?.connection.currentPath)
                    let agreed = info.features ?? 0
                    self.localCursorActive = agreed & StreamFeature.localCursor != 0
                    if agreed & StreamFeature.clipboardSync != 0 {
                        // Baseline = the clipboard as it was when the user left SkyDesk, so something copied in
                        // another app meanwhile is still sent once after reconnecting.
                        let now = UIPasteboard.general.changeCount
                        self.clipboard = ClipboardSync(changeCount: self.pasteboardCountWhenLeft ?? now)
                        self.pasteboardCountWhenLeft = nil
                        self.checkClipboard()
                    }
                    if agreed & StreamFeature.fileTransfer != 0 { self.openFiles(endpoint: endpoint, key: key, session: session) }
                    if agreed & StreamFeature.audio != 0, self.playMacSound { self.openAudio(endpoint: endpoint, key: key, session: session) }
                    UIApplication.shared.isIdleTimerDisabled = true
                    if AutoPadOnly.shouldStart(setting: self.startIPadOnly, supported: info.displayBlankingSupported == true) {
                        // A moment for the new iPad desktop to settle before it becomes the only display.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                            guard let self, self.token == session, self.info != nil, !self.macDisplayBlanked, !self.changingMacDisplay else { return }
                            self.toggleMacDisplay()
                        }
                    }
                    if self.inBackground { self.enterBackground() }
                case .clipboard(let text):
                    if var sync = self.clipboard {
                        // Automatic: copied on the Mac, ready to paste here. Silent, and never sent back.
                        guard text.utf8.count <= ClipboardSync.maxBytes else { throw DeskError.invalid("Clipboard text is too large.") }
                        if self.syncClipboard, sync.incoming(text) { self.writePasteboard(text) }
                        self.clipboard = sync
                    } else {
                        guard text.utf8.count <= 8192 else { throw DeskError.invalid("Clipboard exceeds 8 KiB.") }
                        UIPasteboard.general.string = text; self.notice = "Mac clipboard copied to iPad."
                    }
                case .textFocus(let focus):
                    guard focus.isValid else { throw DeskError.invalid("Invalid text-field position.") }
                    let changedField = focus.id != self.textFocus.id
                    self.textFocus = focus
                    if focus.rect == nil { self.keyboardWanted = false }
                    else if self.automaticKeyboard && (changedField || self.awaitingTextFocus) { self.keyboardWanted = true }
                    self.awaitingTextFocus = false
                case .cursor(let cursor):
                    guard cursor.isValid else { throw DeskError.invalid("Invalid pointer image.") }
                    self.remoteCursor = cursor
                case .macDisplayBlanked(let blanked):
                    self.macDisplayBlanked = blanked; self.changingMacDisplay = false
                case .updateAvailable(let build):
                    if build > Self.ownBuild { self.updateBuild = build }
                case .updateReady(let manifest):
                    self.verifyAndInstall(manifest)
                case .failure(let reason):
                    self.changingMacDisplay = false
                    if self.updateState == .preparing { self.updateState = .failed(reason) }
                    if self.info == nil { self.clearAutoDeadline(); self.status = reason }
                    self.notice = reason
                default: throw DeskError.invalid("Unexpected host message.")
                }
            } catch { self.endSession(reason: error.localizedDescription) }
            }
        }
        video.onPacket = { [weak video, weak control] packet in
            do {
                guard packet.kind == .video else { throw DeskError.invalid("Expected a video frame.") }
                let received = monotonicNanos()
                let frame = try VideoFrame(data: packet.payload)
                // Hidden in the background (no decoding allowed), or waiting for the keyframe after resuming.
                if gate.paused || (gate.needKeyframe && !frame.keyframe) { control?.send(.frameAck(frame.sequence)); return }
                gate.needKeyframe = false
                try decoder.decode(frame) { result in
                    switch result {
                    case .success(let image):
                        let macMS = frame.encodeTime >= frame.captureTime ? Double(frame.encodeTime - frame.captureTime) / 1_000_000 : nil
                        mailbox.put(DecodedImage(pixels: image, sequence: frame.sequence, receivedAt: received, afterIdle: frame.afterIdle, macMS: macMS),
                                    bytes: packet.payload.count, decodeMS: Double(monotonicNanos() - received) / 1_000_000)
                        control?.send(.frameAck(frame.sequence))
                    case .failure(let error): video?.close(reason: error.localizedDescription)
                    }
                }
            } catch { video?.close(reason: error.localizedDescription) }
        }
        let closed: (String?) -> Void = { [weak self] reason in
            Task { @MainActor in
                guard let self, self.token == session else { return }
                let neverConnected = self.info == nil
                let fallBack = cableAttempt && neverConnected
                let wrongPassword = reason == PairingPassword.mismatchMessage
                // An automatic attempt keeps trying until its deadline: Wi-Fi is often still waking up.
                let retryDeadline = self.autoDeadline.flatMap { deadline in
                    neverConnected && !wrongPassword && Date() < deadline.addingTimeInterval(-0.8) ? deadline : nil
                }
                self.endSession(reason: reason ?? "Your Mac ended the session.", keepDeadline: fallBack || retryDeadline != nil)
                if fallBack { self.open(target, cableFirst: false); return }
                if let deadline = retryDeadline {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                        guard let self, self.autoDeadline == deadline, !self.connecting, self.info == nil else { return }
                        self.open(target, cableFirst: false)
                    }
                    return
                }
                if wrongPassword { self.clearAutoDeadline(); self.passwordNeeded = true; self.manualHost = target.address ?? self.manualHost }
            }
        }
        control.onClose = closed; video.onClose = closed
        connectedAt = Date()
        control.start(); video.start()
        let pinger = DispatchSource.makeTimerSource(queue: controlQueue)
        let period = DispatchTimeInterval.milliseconds(1_000 / StreamStatistics.pingsPerSecond)
        pinger.schedule(deadline: .now() + period, repeating: period, leeway: .milliseconds(2))
        var beats = 0
        pinger.setEventHandler { [weak control] in
            control?.send(.ping(monotonicNanos()))
            beats += 1
            if beats % 10 == 0 {
                DispatchQueue.main.async { Breadcrumb.heartbeat() }
                if let stall = Breadcrumb.stalled() {
                    control?.send(.clientStats(String(format: "MAIN THREAD STALLED %.1f s at %@", stall.seconds, stall.stage)))
                }
            }
        }
        self.pinger = pinger; pinger.resume()
        heartbeat = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }
    private func remember(_ target: ConnectTarget, info: StreamInfo, path: NWPath?) {
        var address = target.address
        if let remote = path?.remoteEndpoint, case .hostPort(let host, _) = remote {
            switch host {
            case .ipv4(let ip): address = "\(ip)".components(separatedBy: "%").first
            case .ipv6(let ip): address = "\(ip)"
            case .name(let name, _): address = address ?? name
            @unknown default: break
            }
        }
        guard let address, !address.isEmpty else { return }
        var list = recents
        let (entry, removed) = list.record(address: address, name: info.hostName ?? target.label,
                                          serviceName: target.serviceName, at: Date())
        removed.forEach { PairingStore.delete(account: $0.keychainAccount) }
        recents = list; list.save(to: .standard)
        UserDefaults.standard.set(address, forKey: "lastManualHost")
        do {
            try PairingStore.save(target.key, account: entry.keychainAccount)
            try PairingStore.save(target.key, account: RecentHostList.lastCredentialAccount)
        } catch { notice = "Connected, but the password could not be saved: \(error.localizedDescription)" }
        pairingText = ""; manualHost = ""; selectedHost = ""
    }
    /// User pressed Disconnect: no automatic reconnection afterwards.
    func disconnect(reason: String = "Disconnected") {
        resumeTarget = nil
        endSession(reason: reason)
    }
    private func endSession(reason: String?, keepDeadline: Bool = false) {
        token = UUID()
        if !keepDeadline { probe?.cancel(); probe = nil }
        if !keepDeadline, autoDeadline != nil { clearAutoDeadline() }
        heartbeat?.invalidate(); heartbeat = nil
        pinger?.cancel(); pinger = nil
        control?.close(); video?.close(); control = nil; video = nil
        videoQueue = nil; videoGate = nil; decoder = nil; activeTarget = nil
        clipboard = nil; localCursorActive = false
        fileEngine?.close(reason: "Disconnected from the Mac."); fileEngine = nil
        files?.close(); files = nil; filesReady = false
        closeAudio()
        info = nil; connecting = false
        if let reason { status = reason }
        textFocus = .none; keyboardWanted = false; awaitingTextFocus = false; lastTapRect = nil; remoteCursor = nil
        macDisplayBlanked = false; changingMacDisplay = false; usingCable = false; usingVPN = false
        pathMonitor?.cancel(); pathMonitor = nil
        UIDevice.current.isBatteryMonitoringEnabled = false
        UIApplication.shared.isIdleTimerDisabled = false
        mailbox = FrameMailbox()
        endBackgroundTask()
    }

    // MARK: Background and foreground

    /// iPadOS keeps an app running for about 30 s after it leaves the screen when it asks for a background task.
    /// During that time the link stays up with video paused; after it, the session ends and resumes on return.
    func enterBackground() {
        inBackground = true
        pasteboardCountWhenLeft = UIPasteboard.general.changeCount
        releaseInput()
        // Mid-update, hold nothing: iPadOS installs only once SkyDesk has really stopped, and the background task
        // that keeps a session alive for ~30 s delayed that until the user had already come back (2026-11-13).
        if updateState == .installing {
            closeForUpdateWork?.cancel(); closeForUpdateWork = nil; closingForUpdate = nil
            if info != nil || connecting { disconnect(reason: "Updating SkyDesk…") }
            return
        }
        let canPause = (info?.features ?? 0) & StreamFeature.pauseVideo != 0
        switch SessionLifecycle.onBackground(connected: info != nil, connecting: connecting, hostCanPause: canPause) {
        case .pauseAndHold:
            resumeTarget = activeTarget
            if let gate = videoGate { videoQueue?.async { gate.paused = true } }
            audioPlayer?.setSuspended(true)
            control?.send(.pauseVideo(true))
            beginBackgroundTask()
        case .disconnectAndResumeLater:
            resumeTarget = activeTarget ?? resumeTarget
            endSession(reason: "Paused while SkyDesk was in the background.")
        case .nothing: break
        }
    }
    func enterForeground() {
        guard inBackground else { return }
        inBackground = false
        Breadcrumb.heartbeat()
        endBackgroundTask()
        let age = mailbox.statistics.lastPongAge().map { Double($0) / 1_000_000_000 }
        closeForUpdateWork?.cancel(); closeForUpdateWork = nil; closingForUpdate = nil
        switch SessionLifecycle.onForeground(connected: info != nil, lastReplyAge: age, resumeWanted: resumeTarget != nil,
                                             connecting: connecting) {
        case .resumeVideo:
            resumeTarget = nil
            if let gate = videoGate, let decoder {
                // Ordered on the video queue before any frame sent after the resume request.
                videoQueue?.async { decoder.reset(); gate.needKeyframe = true; gate.paused = false }
            }
            audioPlayer?.setSuspended(false)
            control?.send(.pauseVideo(false))
            checkClipboard()
        case .reconnect:
            let target = activeTarget ?? resumeTarget
            resumeTarget = nil
            endSession(reason: nil)
            if let target { reconnect(to: target) }
        case .connectToMostRecent:
            // Not while the user is part-way through the connection form (e.g. back from copying a password).
            if pairingText.isEmpty, !passwordNeeded, selectedHost.isEmpty { connectToMostRecent() }
        case .nothing: break
        }
    }

    /// Seconds left before SkyDesk steps aside for the update (nil = not counting down).
    @Published var closingForUpdate: Int?
    private var closeForUpdateWork: DispatchWorkItem?
    /// iPadOS only replaces an app once it is no longer on screen, so after starting the install SkyDesk counts
    /// down, disconnects cleanly (the Mac then updates itself) and goes to the Home Screen.
    private func scheduleCloseForUpdate(seconds: Int = 3) {
        closingForUpdate = seconds
        let work = DispatchWorkItem { [weak self] in
            guard let self, let left = self.closingForUpdate else { return }
            if left > 1 { self.scheduleCloseForUpdate(seconds: left - 1); return }
            self.closingForUpdate = nil
            self.releaseInput()
            self.disconnect(reason: "Updating SkyDesk…")
            // Not an exit: the same as pressing Home. iPadOS then installs and the app reopens fresh.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                UIControl().sendAction(Selector(("suspend")), to: UIApplication.shared, for: nil)
            }
        }
        closeForUpdateWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }
    func stayOpenForUpdate() {
        closeForUpdateWork?.cancel(); closeForUpdateWork = nil; closingForUpdate = nil
    }
    private func beginBackgroundTask() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "SkyDesk session") { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Out of background time: end cleanly so the Mac restores itself now, and reconnect on return.
                self.endSession(reason: "Paused while SkyDesk was in the background.")
            }
        }
    }
    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask); backgroundTask = .invalid
    }

    // MARK: Input and controls

    func input(_ event: InputEvent) {
        Breadcrumb.mark("input:\(event.kind.rawValue)"); defer { Breadcrumb.mark("input:end") }
        if info?.inputEnabled == true {
            if event.kind == .up {
                awaitingTextFocus = true
                lastTapRect = CGRect(x: event.x, y: event.y, width: 0, height: min(0.025, 1 - event.y))
            }
            control?.send(.input(event))
        }
    }
    /// The Mac glides on by itself (smoothly, whatever the Wi-Fi does); older Macs just stop, as before.
    func scrollMomentum(_ velocity: CGPoint) {
        guard info?.inputEnabled == true, (info?.features ?? 0) & StreamFeature.scrollMomentum != 0 else { return }
        control?.send(.scrollMomentum(Double(velocity.x), Double(velocity.y)))
    }
    /// Pinch and rotate. Older Macs don't know the message (and would end the session), so it is only sent when agreed.
    func gesture(_ event: GestureEvent) {
        guard info?.inputEnabled == true, (info?.features ?? 0) & StreamFeature.gestures != 0, event.isValid else { return }
        control?.send(.gesture(event))
    }
    /// Three fingers on the screen, as on a Mac trackpad: up = Mission Control, down = the app's windows,
    /// left and right = the next and previous desktop. Sent as the Mac's standard Control-arrow shortcuts.
    func desktopSwipe(_ direction: DesktopSwipe) {
        guard info?.inputEnabled == true else { return }
        switch direction {
        case .up: shortcut(key: 82, modifiers: 2)
        case .down: shortcut(key: 81, modifiers: 2)
        case .left: shortcut(key: 79, modifiers: 2)
        case .right: shortcut(key: 80, modifiers: 2)
        }
    }
    enum DesktopSwipe { case up, down, left, right }
    func sendText(_ text: String) {
        guard info?.inputEnabled == true, info?.textInputEnabled == true,
              !text.isEmpty, text.utf8.count <= 8192 else { return }
        control?.send(.text(text))
    }
    func deleteText() {
        input(InputEvent(kind: .key, keyCode: 42, isDown: true))
        input(InputEvent(kind: .key, keyCode: 42, isDown: false))
    }
    func toggleKeyboard() {
        guard info?.textInputEnabled == true else { notice = "Update SkyDesk Host to use the iPad keyboard."; return }
        keyboardWanted.toggle()
    }
    func toggleMacDisplay() {
        guard info?.displayBlankingSupported == true, !changingMacDisplay else { return }
        changingMacDisplay = true
        control?.send(.setMacDisplayBlanked(!macDisplayBlanked))
    }
    private static func currentDisplay() -> ClientDisplay {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        let screen = scene?.screen ?? UIScreen.main
        let window = scene?.windows.first { $0.isKeyWindow }
        let bounds = window?.bounds ?? screen.bounds
        let scale = screen.nativeScale
        return ClientDisplay(width: max(640, min(4096, Int((bounds.width * scale / 2).rounded()) * 2)),
                             height: max(640, min(4096, Int((bounds.height * scale / 2).rounded()) * 2)),
                             maximumFPS: min(120, max(30, screen.maximumFramesPerSecond)))
    }
    func releaseInput() { control?.send(.releaseInput) }
    /// Brings the Mac's Dock onto this desktop: a short series of pointer moves pushing against the bottom edge,
    /// which the host turns into the downward push macOS looks for.
    func showDock() {
        guard info?.inputEnabled == true else { return }
        for step in 0..<12 {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(step) * 0.03) { [weak self] in
                self?.input(InputEvent(kind: .move, x: 0.5, y: 1))
            }
        }
    }
    func shortcut(key: Int, modifiers: UInt = 0) {
        let modifierKeys: [(UInt, Int)] = [(1, 225), (2, 224), (4, 226), (8, 227)]
        var held: UInt = 0
        for (flag, usage) in modifierKeys where modifiers & flag != 0 {
            held |= flag
            input(InputEvent(kind: .key, keyCode: usage, isDown: true, modifiers: held))
        }
        input(InputEvent(kind: .key, keyCode: key, isDown: true, modifiers: modifiers))
        input(InputEvent(kind: .key, keyCode: key, isDown: false, modifiers: modifiers))
        for (flag, usage) in modifierKeys.reversed() where modifiers & flag != 0 {
            held &= ~flag
            input(InputEvent(kind: .key, keyCode: usage, isDown: false, modifiers: held))
        }
        releaseInput()
    }
    func sendClipboard() {
        guard let text = UIPasteboard.general.string else { notice = "iPad clipboard contains no text."; return }
        guard text.utf8.count <= 8192 else { notice = "Clipboard text exceeds the 8 KiB limit."; return }
        control?.send(.clipboard(text)); notice = "Clipboard sent to Mac."
    }
    func getClipboard() { control?.send(.clipboardRequest) }
    var clipboardSyncing: Bool { clipboard != nil }
    var queuedFileCount: Int { queuedFiles.count }

    // MARK: Wireless updates

    @Published var certificateName = "SkyDesk Updates.mobileconfig"
    func installUpdate() {
        guard updateBuild != nil, (info?.features ?? 0) & StreamFeature.remoteUpdate != 0 else { return }
        updateState = .preparing
        control?.send(.updateRequest)
    }
    func requestUpdateCertificate() {
        updateState = .needsCertificate
        control?.send(.updateCertificateRequest)
    }
    /// Opens the Files app at SkyDesk's folder, where the certificate profile was saved.
    func openFilesFolder() {
        if let url = URL(string: "shareddocuments://" + Self.documents.path) { UIApplication.shared.open(url) }
    }
    /// Checks the Mac's HTTPS certificate is trusted before handing the install to iPadOS: an untrusted server
    /// makes iPadOS fail with a vague "Unable to install" message.
    private func verifyAndInstall(_ manifest: String) {
        guard let manifestURL = URL(string: manifest),
              let ping = URL(string: manifest.replacingOccurrences(of: "manifest.plist", with: "ping")),
              let install = UpdateManifest.installURL(manifest: manifestURL) else { updateState = .failed("The Mac sent a bad update link."); return }
        var request = URLRequest(url: ping); request.timeoutInterval = 6
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if (response as? HTTPURLResponse)?.statusCode == 200 {
                    self.updateState = .installing
                    UIApplication.shared.open(install)
                    self.scheduleCloseForUpdate()
                } else if let error = error as? URLError, [.serverCertificateUntrusted, .serverCertificateHasUnknownRoot,
                          .serverCertificateNotYetValid, .serverCertificateHasBadDate, .secureConnectionFailed].contains(error.code) {
                    self.updateState = .needsCertificate
                } else {
                    self.updateState = .failed(error?.localizedDescription ?? "The Mac's update server didn't answer.")
                }
            }
        }.resume()
    }
    /// Reads the pasteboard only after its change counter moved and only if it holds text, so iPadOS shows its
    /// paste notice (or "Allow Paste?" prompt) once per new copy at most, never on a timer.
    ///
    /// Runs only when SkyDesk comes back on screen (and right after connecting), never on a timer: anything copied
    /// while SkyDesk is in front was copied on the Mac, which sends it itself, and polling read every Universal
    /// Clipboard update from the Mac too, so iPadOS showed "Paste from …MacBook Pro" over and over (2026-11-13).
    ///
    /// Every pasteboard call runs on `pasteboardQueue`, never the main thread: reading text another app copied can
    /// wait on iPadOS's "Allow Paste?" prompt, and doing that on main froze SkyDesk for up to 10.5 s
    /// (build 17, 2026-11-13 00:08, MAIN THREAD STALLED at tick:start). One check at a time.
    func checkClipboard() {
        guard clipboard != nil, syncClipboard, !inBackground, info != nil, !pasteboardBusy else { return }
        pasteboardBusy = true
        let session = token
        pasteboardQueue.async { [weak self] in
            let pasteboard = UIPasteboard.general
            let count = pasteboard.changeCount
            DispatchQueue.main.async {
                guard let self else { return }
                guard self.token == session, var sync = self.clipboard, sync.localChanged(changeCount: count) else {
                    self.pasteboardBusy = false; return
                }
                self.clipboard = sync
                self.pasteboardQueue.async {
                    let text = pasteboard.hasStrings ? pasteboard.string : nil
                    DispatchQueue.main.async {
                        self.pasteboardBusy = false
                        guard self.token == session, var sync = self.clipboard else { return }
                        if let text = sync.outgoing(text) { self.control?.send(.clipboard(text)) }
                        self.clipboard = sync
                    }
                }
            }
        }
    }
    private let pasteboardQueue = DispatchQueue(label: "skydesk.pasteboard", qos: .utility)
    /// The iPad clipboard's change counter when SkyDesk last left the screen (reading the counter never prompts).
    private var pasteboardCountWhenLeft: Int?
    private var pasteboardBusy = false
    /// Text copied on the Mac, written off the main thread; the new change counter is recorded so it isn't sent back.
    private func writePasteboard(_ text: String) {
        let session = token
        pasteboardQueue.async { [weak self] in
            UIPasteboard.general.string = text
            let count = UIPasteboard.general.changeCount
            DispatchQueue.main.async {
                guard let self, self.token == session, var sync = self.clipboard else { return }
                sync.wroteRemote(changeCount: count); self.clipboard = sync
            }
        }
    }

    // MARK: Sound

    /// A fourth connection that only carries the Mac's sound, so it never waits behind video or files.
    private func openAudio(endpoint: NWEndpoint, key: PairingKey, session: UUID) {
        guard audioChannel == nil else { return }
        let queue = DispatchQueue(label: "skydesk.audio.net", qos: .userInteractive)
        let channel = SecureChannel(connection: NWConnection(to: endpoint, using: DeskNetwork.parameters(key: key)), queue: queue,
                                    maxPendingBytes: 64 * 1_024)
        let player = AudioPlayer()
        player.onPlaying = { [weak channel] in channel?.send(.audioPlaying($0)) }
        player.onFailure = { [weak self, weak channel] reason in
            channel?.close()
            DispatchQueue.main.async { self?.notice = reason }
        }
        channel.onReady = { [weak channel] in channel?.send(.hello(Hello(session: session, role: .audio))) }
        channel.onPacket = { [weak channel] packet in
            do {
                if packet.kind == .audio { player.receive(try AudioPacket(packet: packet)); return }
                guard case .audioFormat(let format) = try packet.controlMessage(), format.isValid else { throw DeskError.invalid("Unexpected sound message.") }
                player.configure(format)
            } catch { channel?.close(reason: error.localizedDescription) }
        }
        channel.onClose = { [weak self, weak channel] _ in
            player.stop()
            DispatchQueue.main.async {
                guard let self, let channel, self.audioChannel === channel else { return }
                self.audioChannel = nil; self.audioPlayer = nil
            }
        }
        audioChannel = channel; audioPlayer = player
        if inBackground { player.setSuspended(true) }
        channel.start()
    }
    private func closeAudio() {
        audioPlayer?.stop(); audioPlayer = nil
        audioChannel?.close(); audioChannel = nil
    }

    // MARK: Files

    private func openFiles(endpoint: NWEndpoint, key: PairingKey, session: UUID) {
        let queue = DispatchQueue(label: "skydesk.files", qos: .utility)
        let channel = SecureChannel(connection: NWConnection(to: endpoint, using: DeskNetwork.parameters(key: key)), queue: queue)
        let engine = FileTransferEngine(directory: Self.documents, queue: DispatchQueue(label: "skydesk.files.engine", qos: .utility))
        engine.sendMessage = { [weak channel] in channel?.send($0) }
        engine.sendPacket = { [weak channel] packet, done in
            guard let channel else { done(false); return }
            channel.send(packet, completion: done)
        }
        engine.onProgress = { [weak self] progress in
            DispatchQueue.main.async { self?.record(progress) }
        }
        channel.onReady = { [weak self, weak channel] in
            channel?.send(.hello(Hello(session: session, role: .files)))
            DispatchQueue.main.async {
                guard let self, self.token == session else { return }
                self.filesReady = true
                let waiting = self.queuedFiles; self.queuedFiles = []
                waiting.forEach { self.fileEngine?.send(fileAt: $0) }
            }
        }
        channel.onPacket = { packet in engine.handle(packet) }
        channel.onClose = { [weak self] reason in
            engine.close(reason: reason ?? "File connection closed.")
            DispatchQueue.main.async {
                guard let self, self.token == session else { return }
                self.filesReady = false; self.files = nil; self.fileEngine = nil
            }
        }
        files = channel; fileEngine = engine
        channel.start()
    }
    private func record(_ progress: FileTransferEngine.Progress) {
        if let index = transfers.firstIndex(where: { $0.id == progress.id }) { transfers[index] = progress }
        else { transfers.insert(progress, at: 0); if transfers.count > 20 { transfers.removeLast() } }
        if case .saved(let name) = progress.state, !progress.outgoing {
            if name.hasSuffix(".mobileconfig") { updateState = .certificateArrived; certificateName = name }
            else { notice = "Received \(name). It's in the Files app under On My iPad › SkyDesk." }
        }
        if progress.outgoing, progress.state != .active, let url = outboxURL(progress.name) { try? FileManager.default.removeItem(at: url) }
    }
    private func outboxURL(_ name: String) -> URL? {
        let url = Self.outbox.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
    /// Copies each file into a private outbox first (security-scoped URLs from Files or the share sheet stop being
    /// readable later), then sends it now or as soon as a Mac is connected.
    func sendFiles(_ urls: [URL]) {
        var staged: [URL] = []
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                try FileManager.default.createDirectory(at: Self.outbox, withIntermediateDirectories: true)
                let copy = try FileNames.uniqueURL(for: url.lastPathComponent, in: Self.outbox)
                try FileManager.default.copyItem(at: url, to: copy)
                staged.append(copy)
            } catch { notice = "Couldn't read \(url.lastPathComponent): \(error.localizedDescription)" }
        }
        guard !staged.isEmpty else { return }
        if filesReady, let fileEngine { staged.forEach { fileEngine.send(fileAt: $0) } }
        else if info != nil, fileEngine == nil, (info?.features ?? 0) & StreamFeature.fileTransfer == 0 {
            staged.forEach { try? FileManager.default.removeItem(at: $0) }
            notice = "This Mac needs the SkyDesk update (or has file transfers turned off) to receive files."
        } else {
            queuedFiles += staged
            if info == nil { notice = "Connect to your Mac and \(staged.count == 1 ? "the file" : "the files") will be sent automatically." }
        }
    }
    private func tick() {
        Breadcrumb.mark("tick:start")
        defer { Breadcrumb.mark("tick:end") }
        let silence = mailbox.statistics.lastPongAge().map { Double($0) / 1_000_000_000 } ?? Date().timeIntervalSince(connectedAt)
        if silence > (connecting ? 12 : 5) {
            // Lost while visible: try once more automatically rather than dropping straight to the menu.
            let target = activeTarget
            let wasStreaming = info != nil
            endSession(reason: "Lost the connection to your Mac.")
            if wasStreaming, !inBackground, let target { reconnect(to: target) }
            return
        }
        guard !inBackground else { return }
        let values = mailbox.statistics.snapshot()
        Breadcrumb.mark("tick:text")
        stats.update(headline: StatisticsText.headline(values), network: StatisticsText.network(values),
                     display: StatisticsText.total(values), details: StatisticsText.pipeline(values),
                     corner: StatisticsText.corner(values, build: Self.ownBuild))
        statsTick += 1
        if statsTick % 2 == 0, (info?.features ?? 0) & StreamFeature.clientStatsLog != 0 {
            control?.send(.clientStats(StatisticsText.logLine(values, link: usingCable ? "cable" : usingVPN ? "vpn" : networkSymbol)))
        }
        #if targetEnvironment(simulator)
        stats.metrics = "SIMULATOR (GPU completion only) · " + stats.metrics
        #endif
    }
}

@MainActor
final class StreamStatsModel: ObservableObject {
    @Published var metrics = "Waiting for frames"
    @Published var networkTiming = ""
    @Published var displayTiming = ""
    @Published var timingDetails = ""
    @Published var corner = ""
    func update(headline: String, network: String, display: String, details: String, corner: String) {
        if self.corner != corner { self.corner = corner }
        if metrics != headline { metrics = headline }
        if networkTiming != network { networkTiming = network }
        if displayTiming != display { displayTiming = display }
        if timingDetails != details { timingDetails = details }
    }
}

#if targetEnvironment(simulator)
import CoreVideo

/// Simulator-only self-check (SKYDESK_DEMO=1): shows the streaming screen with generated frames, so the drawing
/// path, toolbar and readouts can be looked at without a Mac session. Not compiled into the iPad app.
extension ClientModel {
    func startDemo() {
        let mailbox = FrameMailbox(); self.mailbox = mailbox
        info = StreamInfo(width: 1376, height: 1032, fps: 120, bitrate: 25_000_000, displayName: "Demo", inputEnabled: false)
        let queue = DispatchQueue(label: "skydesk.demo")
        let timer = DispatchSource.makeTimerSource(queue: queue)
        var sequence: UInt64 = 0
        timer.schedule(deadline: .now() + 0.2, repeating: .milliseconds(16))
        timer.setEventHandler {
            sequence += 1
            var buffer: CVPixelBuffer?
            let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true]
            guard CVPixelBufferCreate(nil, 1376, 1032, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attributes as CFDictionary, &buffer) == kCVReturnSuccess,
                  let pixels = buffer else { return }
            CVPixelBufferLockBaseAddress(pixels, [])
            for plane in 0..<2 {
                let base = CVPixelBufferGetBaseAddressOfPlane(pixels, plane)!.assumingMemoryBound(to: UInt8.self)
                let stride = CVPixelBufferGetBytesPerRowOfPlane(pixels, plane), rows = CVPixelBufferGetHeightOfPlane(pixels, plane)
                for row in 0..<rows {
                    // Moving diagonal bands in luma, a slow colour drift in chroma.
                    if plane == 0 { for x in 0..<stride { base[row * stride + x] = UInt8(60 + ((x + row + Int(sequence) * 4) / 64 % 2) * 140) } }
                    else { memset(base + row * stride, Int32(110 + (Int(sequence) / 4 + row / 8) % 40), stride) }
                }
            }
            CVPixelBufferUnlockBaseAddress(pixels, [])
            let now = monotonicNanos()
            _ = mailbox.statistics.recordPong(sentAt: now - 6_000_000, now: now)
            mailbox.put(DecodedImage(pixels: pixels, sequence: sequence, receivedAt: now, macMS: 9), bytes: 26_000, decodeMS: 2)
        }
        timer.resume()
        demoTimer = timer
        demoStats = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let values = mailbox.statistics.snapshot()
                self.stats.update(headline: StatisticsText.headline(values), network: StatisticsText.network(values),
                                  display: StatisticsText.total(values), details: StatisticsText.pipeline(values),
                                  corner: StatisticsText.corner(values, build: Self.ownBuild))
            }
        }
    }
}
nonisolated(unsafe) private var demoTimer: DispatchSourceTimer?
nonisolated(unsafe) private var demoStats: Timer?
#endif
