import SwiftUI
import Network
import UIKit

struct DiscoveredHost: Identifiable {
    let id: String
    let name: String
    let endpoint: NWEndpoint
}

@MainActor
final class ClientModel: ObservableObject {
    @Published var hosts: [DiscoveredHost] = []
    @Published var manualHost = ""
    @Published var selectedHost = ""
    @Published var pairingText = ""
    @Published var status = "Choose your Mac to begin"
    @Published var connecting = false
    @Published var info: StreamInfo?
    @Published var metrics = "Waiting for frames"
    @Published var networkTiming = ""
    @Published var displayTiming = ""
    @Published var timingDetails = ""
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
    @Published var preferCable = UserDefaults.standard.bool(forKey: "preferCable") {
        didSet { UserDefaults.standard.set(preferCable, forKey: "preferCable") }
    }
    @Published var macDisplayBlanked = false
    @Published var changingMacDisplay = false
    @Published var networkSymbol = "network"
    @Published var networkDescription = "Network"
    @Published var lastTapRect: CGRect?
    @Published var remoteCursor: RemoteCursor?
    @Published var notice: String?
    @Published var showStats = true
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
    private var statsTick = 0
    private var awaitingTextFocus = false
    private var keyAccount: String { "pad:" + (manualHost.isEmpty ? selectedHost : manualHost) }

    init() {
        manualHost = UserDefaults.standard.string(forKey: "lastManualHost") ?? ""
        selectedHost = UserDefaults.standard.string(forKey: "lastSelectedHost") ?? ""
        if let saved = try? PairingStore.load(account: keyAccount) { pairingText = saved.text }
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
                if self.selectedHost.isEmpty, let first = self.hosts.first { self.select(first.id) }
            }
        }
        browser.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state { Task { @MainActor in self?.status = "Discovery: \(error.localizedDescription). You can enter the Mac's address." } }
        }
        self.browser = browser; browser.start(queue: .main)
    }
    func select(_ id: String) {
        selectedHost = id
        if let saved = try? PairingStore.load(account: keyAccount) { pairingText = saved.text }
        else { pairingText = "" }
    }
    func connect() { connect(cableFirst: preferCable) }
    /// A USB cable between the iPad and the Mac is a sub-millisecond link, so it is tried before Wi-Fi.
    private func connect(cableFirst: Bool) {
        guard !connecting, info == nil else { return }
        do {
            let key = try PairingKey(text: pairingText)
            var endpoint: NWEndpoint
            let host = manualHost.trimmingCharacters(in: .whitespacesAndNewlines)
            let discovered = hosts.first(where: { $0.id == selectedHost }) ?? (hosts.count == 1 ? hosts.first : nil)
            if !host.isEmpty { endpoint = .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: DeskNetwork.port)!) }
            else if let selected = hosts.first(where: { $0.id == selectedHost }) { endpoint = selected.endpoint }
            else { throw DeskError.invalid("Select a Mac or enter its LAN address.") }
            // The Mac advertises itself on every interface, so its Bonjour name also resolves over the cable.
            let cableAttempt = cableFirst && discovered != nil
            if cableAttempt, let discovered { endpoint = discovered.endpoint }
            let parameters = { cableAttempt ? DeskNetwork.wiredParameters(key: key) : DeskNetwork.parameters(key: key) }
            let session = UUID(); token = session
            let display = Self.currentDisplay()
            connecting = true; status = "Authenticating with your Mac…"; notice = nil
            UIDevice.current.isBatteryMonitoringEnabled = true
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { [weak self] path in
                Task { @MainActor in
                    guard let self, self.token == session else { return }
                    if self.usingCable { return }
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
            // Off unless enabled: the user tried the iPad-drawn pointer (build 12) and preferred the Mac's own.
            let localPointer = UserDefaults.standard.bool(forKey: "localPointer")
            let account = keyAccount
            control.onReady = { [weak control] in
                control?.send(.hello(Hello(session: session, role: .control, display: display, features: StreamFeature.idleGapFlags | (localPointer ? StreamFeature.localCursor : 0))))
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
                        if let path = control?.connection.currentPath, !path.usesInterfaceType(.wifi), !path.usesInterfaceType(.cellular) {
                            self.usingCable = true
                            self.networkSymbol = "cable.connector"; self.networkDescription = "USB cable connected"
                        }
                        UserDefaults.standard.set(self.manualHost, forKey: "lastManualHost")
                        UserDefaults.standard.set(self.selectedHost, forKey: "lastSelectedHost")
                        UIApplication.shared.isIdleTimerDisabled = true
                        do { try PairingStore.save(key, account: account) }
                        catch { self.notice = "Connected, but the pairing key could not be saved: \(error.localizedDescription)" }
                    case .clipboard(let text):
                        guard text.utf8.count <= 8192 else { throw DeskError.invalid("Clipboard exceeds 8 KiB.") }
                        UIPasteboard.general.string = text; self.notice = "Mac clipboard copied to iPad."
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
                    case .failure(let reason): self.changingMacDisplay = false; self.notice = reason
                    default: throw DeskError.invalid("Unexpected host message.")
                    }
                } catch { self.disconnect(reason: error.localizedDescription) }
                }
            }
            video.onPacket = { [weak video, weak control] packet in
                do {
                    guard packet.kind == .video else { throw DeskError.invalid("Expected a video frame.") }
                    let received = monotonicNanos()
                    let frame = try VideoFrame(data: packet.payload)
                    try decoder.decode(frame) { result in
                        switch result {
                        case .success(let image):
                            mailbox.put(DecodedImage(pixels: image, sequence: frame.sequence, receivedAt: received, afterIdle: frame.afterIdle),
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
                    let fallBack = cableAttempt && self.info == nil
                    self.disconnect(reason: reason ?? "Mac disconnected.")
                    if fallBack { self.connect(cableFirst: false) }
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
        } catch { status = error.localizedDescription; connecting = false }
    }
    func disconnect(reason: String = "Disconnected") {
        token = UUID()
        heartbeat?.invalidate(); heartbeat = nil
        pinger?.cancel(); pinger = nil
        control?.close(); video?.close(); control = nil; video = nil
        info = nil; connecting = false; status = reason
        textFocus = .none; keyboardWanted = false; awaitingTextFocus = false; lastTapRect = nil; remoteCursor = nil
        macDisplayBlanked = false; changingMacDisplay = false; usingCable = false
        pathMonitor?.cancel(); pathMonitor = nil
        UIDevice.current.isBatteryMonitoringEnabled = false
        UIApplication.shared.isIdleTimerDisabled = false
        mailbox = FrameMailbox()
    }
    func suspend() {
        if connecting || info != nil { disconnect(reason: "Session ended while SkyDesk was inactive. Reconnect to resume.") }
    }
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
    private func tick() {
        Breadcrumb.mark("tick:start")
        defer { Breadcrumb.mark("tick:end") }
        let silence = mailbox.statistics.lastPongAge().map { Double($0) / 1_000_000_000 } ?? Date().timeIntervalSince(connectedAt)
        if silence > (connecting ? 12 : 5) { disconnect(reason: "Connection timed out. Check the Mac and pairing key."); return }
        let values = mailbox.statistics.snapshot()
        Breadcrumb.mark("tick:text")
        metrics = StatisticsText.headline(values)
        networkTiming = StatisticsText.network(values)
        displayTiming = StatisticsText.display(values)
        timingDetails = StatisticsText.pipeline(values)
        statsTick += 1
        if statsTick % 2 == 0, (info?.features ?? 0) & StreamFeature.clientStatsLog != 0 {
            control?.send(.clientStats(StatisticsText.logLine(values, link: usingCable ? "cable" : networkSymbol)))
        }
        #if targetEnvironment(simulator)
        metrics = "SIMULATOR (GPU completion only) · " + metrics
        #endif
    }
}
