import AppKit
import Combine
import Network
import ScreenCaptureKit

@MainActor
final class HostModel: ObservableObject {
    @Published var status = "Sharing is off"
    @Published var running = false
    @Published var busy = false
    @Published var displays: [SCDisplay] = []
    @Published var displayID: UInt32 = 0
    @Published var longestEdge = 2560
    @Published var useiPadDesktop = true
    @Published var fps = 120
    @Published var bitrateMbps = 25
    @Published var allowInput = true
    @Published var allowClipboard = true
    @Published var lowLatencyRateControl = false
    @Published var pairingText = ""
    @Published var pairingLocked = false
    @Published var metrics = "No client connected"
    @Published var lanAddresses = LANAddressDiscovery.current()
    @Published var screenAllowed = CGPreflightScreenCaptureAccess()
    @Published var inputAllowed = AXIsProcessTrusted()
    let input = InputInjector()
    private var key: PairingKey?
    private var listener: NWListener?
    private var channels: [UUID: SecureChannel] = [:]
    private var control: SecureChannel?
    private var video: SecureChannel?
    private var sessionID: UUID?
    private var generation = UUID()
    private var capture: DisplayCapture?
    private var clientDisplay: ClientDisplay?
    private var clientFeatures = 0
    /// Channels run here, not on main, so frame acknowledgements and pings never wait behind UI or input work.
    private let transportQueue = DispatchQueue(label: "skydesk.host.transport", qos: .userInteractive)
    private let fastPath = ControlFastPath()
    private var virtualDisplay: SkyDeskVirtualDisplay?
    private var focusMonitor: RemoteFocusMonitor?
    private var cursorMonitor: CursorMonitor?
    private lazy var displayController: MacDisplayController = {
        let blanker = MacDisplayController()
        blanker.onChange = { [weak self] blanked in self?.control?.send(.macDisplayBlanked(blanked)) }
        blanker.onLayoutChange = { [weak self] in self?.refreshInputGeometry() }
        return blanker
    }()
    private var timer: Timer?
    private var lastHeartbeat = Date()
    private var lastMetrics = Date()
    private var startingCapture = false

    func loadPairing(allowInteraction: Bool = false) async {
        guard !busy, key == nil else { return }
        busy = true
        let result = await Task.detached(priority: .userInitiated) { () -> Result<PairingKey, Error> in
            do {
                if let saved = try PairingStore.load(account: "host", allowInteraction: allowInteraction) { return .success(saved) }
                let created = try PairingKey()
                try PairingStore.save(created, account: "host", allowInteraction: allowInteraction)
                return .success(created)
            } catch { return .failure(error) }
        }.value
        busy = false
        switch result {
        case .success(let key):
            self.key = key; pairingText = key.text; pairingLocked = false; status = "Sharing is off"
        case .failure:
            pairingLocked = true
            status = "Keychain approval is needed. Choose Unlock pairing key, then respond to macOS."
        }
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
            if !displays.contains(where: { $0.displayID == displayID }) { displayID = displays.first?.displayID ?? 0 }
        } catch { status = error.localizedDescription }
    }
    func rotateKey() {
        guard !running else { return }
        do {
            let replacement = try PairingKey()
            try PairingStore.save(replacement, account: "host")
            key = replacement; pairingText = replacement.text; status = "Pairing key replaced. Pair your iPad again."
        } catch { status = error.localizedDescription }
    }
    func start() async {
        guard !running, !busy, let key else { return }
        busy = true; defer { busy = false }
        await refreshDisplays()
        guard screenAllowed, useiPadDesktop || displays.contains(where: { $0.displayID == displayID }) else { return }
        if allowInput && !inputAllowed { status = "Allow Accessibility or turn off remote input."; return }
        do {
            let listener = try NWListener(using: DeskNetwork.parameters(key: key), on: NWEndpoint.Port(rawValue: DeskNetwork.port)!)
            listener.service = NWListener.Service(name: Host.current().localizedName ?? "SkyDesk Mac", type: DeskNetwork.serviceType)
            let token = UUID(); generation = token
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    guard let self, self.generation == token, self.running else { connection.cancel(); return }
                    self.accept(connection)
                }
            }
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self, self.generation == token else { return }
                    switch state {
                    case .ready: self.status = "Ready for your paired iPad · port \(DeskNetwork.port)"
                    case .failed(let error): self.stop(); self.status = error.localizedDescription
                    default: break
                    }
                }
            }
            self.listener = listener; running = true
            status = "Starting secure listener…"
            listener.start(queue: .main)
            lastMetrics = Date()
            timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
            if let timer { RunLoop.main.add(timer, forMode: .common) }
        } catch { status = error.localizedDescription }
    }
    func stop() {
        generation = UUID()
        timer?.invalidate(); timer = nil
        listener?.cancel(); listener = nil
        running = false
        disconnect()
        status = "Sharing is off"
    }
    private func disconnect() {
        ContinuityLink.resume()
        displayController.restore(reason: "session ended")
        let current = channels.values
        channels.removeAll(); control = nil; video = nil; sessionID = nil; clientDisplay = nil; clientFeatures = 0
        fastPath.bind(control: nil); fastPath.bind(window: nil)
        focusMonitor?.stop(); focusMonitor = nil
        cursorMonitor?.stop(); cursorMonitor = nil
        current.forEach { $0.close() }
        input.releaseAll()
        let old = capture; capture = nil
        let oldDisplay = virtualDisplay; virtualDisplay = nil
        Task { await old?.stop(); oldDisplay?.invalidate() }
        startingCapture = false
        metrics = "No client connected"
        if running { status = "Ready for your paired iPad" }
    }
    private func accept(_ connection: NWConnection) {
        guard channels.count < 4 else { connection.cancel(); return }
        let channel = SecureChannel(connection: connection, queue: transportQueue, maxPendingBytes: 18 * 1024 * 1024)
        channels[channel.id] = channel
        channel.onPacket = { [weak self, weak channel, fastPath] packet in
            guard let channel else { return }
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
                    if self.control === channel || self.video === channel {
                        self.disconnect()
                        if let reason { self.status = reason }
                    }
                }
            }
        }
        channel.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self, weak channel] in
            guard let self, let channel, self.channels[channel.id] != nil else { return }
            if self.control !== channel && self.video !== channel { channel.close(reason: "Session handshake timed out.") }
            else if self.control == nil || self.video == nil { self.disconnect() }
        }
    }
    private func receive(_ packet: WirePacket, from channel: SecureChannel, pongSent: Bool = false) {
        guard channels[channel.id] != nil else { return }
        do {
            let message = try packet.controlMessage()
            if control !== channel && video !== channel {
                guard case .hello(let hello) = message else { throw DeskError.invalid("Missing session handshake.") }
                guard sessionID == nil || sessionID == hello.session else { throw DeskError.invalid("Another iPad is connected.") }
                switch hello.role {
                case .control:
                    guard control == nil else { throw DeskError.invalid("Control channel already connected.") }
                    if let display = hello.display { try display.validate() }
                    clientDisplay = hello.display
                    clientFeatures = hello.features ?? 0
                    control = channel
                    fastPath.bind(control: channel.id)
                case .video:
                    guard video == nil else { throw DeskError.invalid("Video channel already connected.") }
                    video = channel
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
            case .clipboard(let text):
                guard text.utf8.count <= 8192 else { throw DeskError.invalid("Clipboard text exceeds 8 KiB.") }
                if allowClipboard { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
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
        Task { [self, video, control] in
            do {
                var selectedDisplay = displays.first(where: { $0.displayID == displayID })
                let sessionFPS = min(fps, (clientDisplay?.maximumFPS ?? fps) >= 120 ? 120 : (clientDisplay?.maximumFPS ?? fps) >= 60 ? 60 : 30)
                if useiPadDesktop {
                    guard let clientDisplay else { throw DeskError.invalid("Update SkyDesk on iPad to create its Retina desktop, or choose Mirror Mac display.") }
                    let virtual = try SkyDeskVirtualDisplay(pixelWidth: UInt32(clientDisplay.width),
                                                          height: UInt32(clientDisplay.height), refreshRate: Double(sessionFPS))
                    virtualDisplay = virtual
                    try await Task.sleep(nanoseconds: 100_000_000)
                    guard generation == token, self.sessionID == sessionID else { virtual.invalidate(); return }
                    try virtual.activate()
                    for _ in 0..<20 {
                        let available = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true).displays
                        guard generation == token, self.sessionID == sessionID else { virtual.invalidate(); return }
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
                let pipeline = try DisplayCapture(display: display, longestEdge: useiPadDesktop ? 4096 : longestEdge, fps: sessionFPS,
                    bitrate: bitrateMbps * 1_000_000, inputEnabled: allowInput, lowLatencyRateControl: lowLatencyRateControl,
                    nativeDesktop: useiPadDesktop, clientFeatures: clientFeatures)
                pipeline.onFrame = { [weak video] frame in
                    do { video?.send(WirePacket(kind: .video, payload: try frame.encoded())) }
                    catch { video?.close(reason: error.localizedDescription) }
                }
                pipeline.onFailure = { [weak self] reason in
                    Task { @MainActor in
                        guard let self, self.generation == token, self.sessionID == sessionID else { return }
                        self.disconnect(); self.status = reason
                    }
                }
                capture = pipeline
                fastPath.bind(window: pipeline.window)
                input.displayBounds = CGDisplayBounds(display.displayID)
                control.send(.welcome(pipeline.info))
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
                if (pipeline.info.features ?? 0) & StreamFeature.localCursor != 0 {
                    let cursors = CursorMonitor(desktop: input.displayBounds.size)
                    cursors.onCursor = { [weak control] in control?.send(.cursor($0)) }
                    cursorMonitor = cursors; cursors.start()
                }
                status = "\(pipeline.info.displayName) · \(pipeline.info.width) × \(pipeline.info.height) · \(sessionFPS) FPS target"
                startingCapture = false
            } catch {
                guard generation == token, self.sessionID == sessionID else { return }
                disconnect(); status = error.localizedDescription
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
        if allowInput && !inputAllowed { input.releaseAll(); displayController.restore(reason: "remote input permission lost") }
        if control != nil && Date().timeIntervalSince(lastHeartbeat) > 5 { disconnect(); status = "Client timed out; remote keys released."; return }
        guard let capture else { return }
        ContinuityLink.suspend()
        let stats = capture.statistics()
        let now = Date(); let elapsed = max(0.001, now.timeIntervalSince(lastMetrics)); lastMetrics = now
        metrics = String(format: "%.0f capture / %.0f encoded FPS · %.0f skipped/s · %.1f ms encode · %.1f ms feedback · %d in-flight limit",
                         Double(stats.captured) / elapsed, Double(stats.frames) / elapsed, Double(stats.skipped) / elapsed, stats.encodeMS,
                         capture.window.feedbackMilliseconds, capture.window.currentLimit)
        MetricsLog.shared.append(String(format: "host  %@ · %.1f Mbps encoded", metrics, Double(stats.bytes) * 8 / elapsed / 1_000_000))
        if let age = capture.window.oldestAge(), age > 5_000_000_000 { disconnect(); status = "Video stalled; reconnect the iPad." }
    }
}
