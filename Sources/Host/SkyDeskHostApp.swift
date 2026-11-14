import SwiftUI
import AppKit
import ServiceManagement

/// SkyDesk Host lives in the menu bar (build 31). Its window is optional: closing it leaves sharing running, and
/// a launch at login opens no window at all.
@main
struct SkyDeskHostApp: App {
    @NSApplicationDelegateAdaptor(HostAppDelegate.self) private var delegate
    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(host: delegate.host, login: delegate.login) { delegate.showWindow() }
        } label: {
            MenuBarLabel(host: delegate.host)
        }
    }
}

/// Owns the model for the life of the process, so sleep, wake and quit are handled with or without a window.
@MainActor
final class HostAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let host = HostModel()
    let login = LoginItem()
    private var window: NSWindow?
    private var observers: [NSObjectProtocol] = []
    private var addressTimer: Timer?
    private static let relaunchHiddenKey = "relaunchHiddenAt"

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Self-check for development (SKYDESK_SMOKE_PNG=<file>): builds the window without showing it, saves a picture
        // of it and exits. No pairing, no network port, no displays touched, so it is safe beside a running host.
        if let picture = ProcessInfo.processInfo.environment["SKYDESK_SMOKE_PNG"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.smokeTest(picture) }
            return
        }
        let quiet = Self.launchedAtLogin(loginItemOn: login.enabled) || Self.relaunchedHidden()
        login.enableOnFirstRun()
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.host.sleep() }
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.host.wake() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.host.refreshInputGeometry() }
            })
        // Kept current without a window too: the update server and the pairing card both read this list.
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.host.refreshNetworkAddresses() } }
        RunLoop.main.add(timer, forMode: .common); addressTimer = timer
        // The Mac update relaunches the app: come back the way it was (window open or menu bar only).
        host.willRelaunch = { [weak self] in
            if self?.window?.isVisible != true { UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.relaunchHiddenKey) }
        }
        if !quiet { showWindow() }
        Task {
            await host.loadPairing()
            // Something needs the user (Keychain approval or a permission): never wait for that out of sight.
            if host.pairingLocked || !host.screenAllowed || (host.allowInput && !host.inputAllowed) { showWindow() }
        }
    }
    func applicationWillTerminate(_ notification: Notification) { host.shutdown() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    /// Opening SkyDesk again (Finder, Spotlight, Dock) while it runs in the menu bar shows the window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow(); return true
    }
    func showWindow() {
        // The Dock icon and app menu exist only while the window does.
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        makeWindow()
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        login.refresh()
    }
    private func makeWindow() {
        if window == nil {
            let controller = NSHostingController(rootView: HostView(host: host, login: login))
            controller.sizingOptions = []
            let window = NSWindow(contentViewController: controller)
            window.title = "SkyDesk Host"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.isReleasedWhenClosed = false
            window.contentMinSize = NSSize(width: 520, height: 560)
            window.contentMaxSize = NSSize(width: 520, height: 4_000)
            window.setContentSize(NSSize(width: 520, height: 640))
            window.center()
            window.setFrameAutosaveName("SkyDeskHostWindow")
            window.delegate = self
            self.window = window
        }
    }
    private func smokeTest(_ picture: String) {
        makeWindow()
        guard let window, let view = window.contentView else { exit(3) }
        window.layoutIfNeeded(); view.layoutSubtreeIfNeeded()
        guard let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(4) }
        view.cacheDisplay(in: view.bounds, to: image)
        try? image.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: picture))
        let items = NSApp.windows.filter { $0.className.contains("StatusBar") }.count
        let summary = "headline=\(host.headline) menuBarItems=\(items) content=\(Int(view.bounds.width))x\(Int(view.bounds.height)) "
            + "loginStatus=\(SMAppService.mainApp.status.rawValue) policy=\(NSApp.activationPolicy().rawValue)\n"
        try? summary.write(toFile: picture + ".txt", atomically: true, encoding: .utf8)
        // SKYDESK_SMOKE_AUDIO=1 also reads the Mac's sound for 1.5 s, never silencing it, and reports what arrived.
        guard ProcessInfo.processInfo.environment["SKYDESK_SMOKE_AUDIO"] != nil, #available(macOS 14.2, *) else { exit(0) }
        let tap = SystemAudioTap()
        let counts = SmokeAudioCounts()
        // Off the main thread, as in a real session; a start that never returns is reported instead of hanging.
        DispatchQueue.global(qos: .userInitiated).async {
            var report = summary
            do {
                counts.stage = "creating the tap"
                try tap.start(muted: false)
                counts.stage = "started"
                guard let format = tap.format else { throw DeskError.invalid("no format") }
                let encoder = try OpusEncoder(input: format)
                report += "audio format=\(format.sampleRate) Hz, \(format.channelCount) ch, interleaved=\(format.isInterleaved), float=\(format.commonFormat == .pcmFormatFloat32)\n"
                tap.setHandler { buffer in
                    counts.buffers += 1; counts.frames += Int(buffer.frameLength)
                    counts.peak = max(counts.peak, AudioCaptureWorker.peak(buffer))
                    if let packets = try? encoder.encode(buffer) { counts.packets += packets.count; counts.bytes += packets.reduce(0) { $0 + $1.count } }
                    else { counts.failures += 1 }
                }
                Thread.sleep(forTimeInterval: 1.5)
                tap.stop()
                report += "audio buffers=\(counts.buffers) frames=\(counts.frames) peak=\(counts.peak) packets=\(counts.packets) bytes=\(counts.bytes) failures=\(counts.failures)\n"
            } catch { report += "audio FAILED: \(error.localizedDescription)\n" }
            try? report.write(toFile: picture + ".txt", atomically: true, encoding: .utf8)
            exit(0)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
            try? (summary + "audio BLOCKED while \(counts.stage) (no answer after 6 s)\n").write(toFile: picture + ".txt", atomically: true, encoding: .utf8)
            exit(5)
        }
    }
    func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard self?.window?.isVisible != true else { return }
            NSApp.setActivationPolicy(.accessory)
        }
    }
    /// macOS marks the launch event of a login item; a launch within four minutes of start-up with the login item on
    /// counts too, in case the mark is missing.
    private static func launchedAtLogin(loginItemOn: Bool) -> Bool {
        if let event = NSAppleEventManager.shared().currentAppleEvent, event.eventID == kAEOpenApplication,
           event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem { return true }
        return loginItemOn && ProcessInfo.processInfo.systemUptime < 240
    }
    private static func relaunchedHidden() -> Bool {
        let stamp = UserDefaults.standard.double(forKey: relaunchHiddenKey)
        UserDefaults.standard.removeObject(forKey: relaunchHiddenKey)
        return stamp > 0 && Date().timeIntervalSince1970 - stamp < 120
    }
}

/// "Open at login", through macOS's own login-items list (System Settings › General › Login Items).
@MainActor
final class LoginItem: ObservableObject {
    @Published private(set) var enabled = SMAppService.mainApp.status == .enabled
    @Published private(set) var problem: String?
    /// Only the installed copy may register itself; a development build would register its build folder.
    private var installed: Bool { Bundle.main.bundlePath.hasPrefix("/Applications/") }
    func set(_ on: Bool) {
        guard installed else { problem = "Move SkyDesk Host to the Applications folder to open it at login."; return }
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            problem = nil
        } catch { problem = "Couldn't change the login item: \(error.localizedDescription)" }
        refresh()
        if on, SMAppService.mainApp.status == .requiresApproval {
            problem = "Allow SkyDesk Host in System Settings › General › Login Items."
        }
    }
    func refresh() {
        let value = SMAppService.mainApp.status == .enabled
        if value != enabled { enabled = value }
    }
    /// The user asked for launch at login (2026-11-13), so the first run of this build switches it on once.
    /// Switching it off afterwards sticks.
    func enableOnFirstRun() {
        guard installed, !UserDefaults.standard.bool(forKey: "loginItemOffered") else { return }
        UserDefaults.standard.set(true, forKey: "loginItemOffered")
        if !enabled { set(true) }
    }
}

private struct MenuBarLabel: View {
    @ObservedObject var host: HostModel
    var body: some View {
        Image(systemName: host.clientConnected ? "ipad.and.arrow.forward" : "ipad.landscape")
            .accessibilityLabel("SkyDesk: \(host.headline)")
    }
}

private struct MenuBarContent: View {
    @ObservedObject var host: HostModel
    @ObservedObject var login: LoginItem
    let openWindow: () -> Void
    var body: some View {
        Text(host.headline)
        switch host.phase {
        case .locked: Button("Unlock…") { openWindow() }
        case .connected: Button("Disconnect iPad") { host.stopSharing() }
        case .waiting: Button("Turn Off Sharing") { host.stopSharing() }
        case .standby, .off: Button("Turn On Sharing") { host.startSharing() }.disabled(host.password.isEmpty)
        }
        Divider()
        Button("Open SkyDesk…") { openWindow() }
        Toggle("Open at Login", isOn: Binding(get: { login.enabled }, set: { login.set($0) }))
        Divider()
        Button("Quit SkyDesk") { NSApp.terminate(nil) }
    }
}

private struct HostView: View {
    @ObservedObject var host: HostModel
    @ObservedObject var login: LoginItem
    @AppStorage("hidePassword") private var hidePassword = false
    @State private var editingPassword = false
    @State private var showSettings = false
    @State private var dropTargeted = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if !host.screenAllowed || (host.allowInput && !host.inputAllowed) { permissions }
                if host.macUpdateAvailable, let build = host.stagedBuild { updateBanner(build) }
                statusCard
                if host.clientConnected { filesCard }
                pairingCard
                devicesCard
                settings
            }.padding(22)
        }
        .frame(width: 520).frame(minHeight: 560)
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter { $0.isFileURL }
            guard !files.isEmpty else { return false }
            host.sendFiles(files); return true
        } isTargeted: { dropTargeted = $0 }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 16).stroke(Color.teal, style: StrokeStyle(lineWidth: 3, dash: [8, 6]))
                    .padding(8).overlay(Label("Drop to send to your iPad", systemImage: "ipad.and.arrow.forward")
                        .font(.title3.bold()).padding(14).background(.regularMaterial, in: Capsule()))
                    .allowsHitTesting(false)
            }
        }
        .tint(.teal)
        .sheet(isPresented: $editingPassword) { PasswordSheet(host: host, isPresented: $editingPassword) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            host.refreshPermissions(); host.refreshNetworkAddresses(); login.refresh()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            AppMark().frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 0) {
                Text("SkyDesk").font(.title.bold())
                Text("Your Mac on your iPad").font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var phase: HostModel.Phase { host.phase }
    private var headline: String { host.headline }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Circle().fill(dotColor).frame(width: 14, height: 14)
                    .overlay(Circle().stroke(dotColor.opacity(0.35), lineWidth: 6))
                VStack(alignment: .leading, spacing: 2) {
                    Text(headline).font(.title2.bold())
                    Text(host.status).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
                Spacer(minLength: 0)
                if host.busy { ProgressView().controlSize(.small) }
            }
            primaryButton
            Toggle(isOn: $host.autoAccept) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Turn on automatically when my iPad connects")
                    Text("Only an iPad with the password below can do this. Works whenever SkyDesk is open.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.toggleStyle(.switch).disabled(host.pairingLocked)
            Toggle(isOn: Binding(get: { login.enabled }, set: { login.set($0) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Open SkyDesk when I log in")
                    Text(login.problem ?? "It waits in the menu bar. Closing this window keeps it running; quit from the menu bar icon.")
                        .font(.caption).foregroundStyle(login.problem == nil ? Color.secondary : Color.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }.toggleStyle(.switch)
            if host.clientConnected {
                Text(host.metrics).font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(.quaternary.opacity(0.5)))
    }
    private var dotColor: Color {
        switch phase {
        case .connected: return .teal
        case .waiting, .standby: return .green
        case .off: return .secondary
        case .locked: return .orange
        }
    }
    @ViewBuilder private var primaryButton: some View {
        switch phase {
        case .locked:
            Button { Task { await host.loadPairing(allowInteraction: true) } } label: {
                Label("Unlock…", systemImage: "lock.open").frame(maxWidth: .infinity).padding(.vertical, 6)
            }.buttonStyle(.borderedProminent).controlSize(.large).disabled(host.busy)
        case .connected:
            Button(role: .destructive) { host.stopSharing() } label: {
                Label("Disconnect iPad", systemImage: "xmark.circle").frame(maxWidth: .infinity).padding(.vertical, 6)
            }.buttonStyle(.bordered).controlSize(.large)
        case .waiting:
            Button { host.stopSharing() } label: {
                Label("Turn Off Sharing", systemImage: "stop.circle").frame(maxWidth: .infinity).padding(.vertical, 6)
            }.buttonStyle(.bordered).controlSize(.large)
        case .standby, .off:
            Button { host.startSharing() } label: {
                Label("Turn On Sharing", systemImage: "play.circle.fill").frame(maxWidth: .infinity).padding(.vertical, 6)
            }.buttonStyle(.borderedProminent).controlSize(.large).disabled(host.password.isEmpty)
        }
    }

    private func updateBanner(_ build: Int) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.down.circle.fill").font(.title2).foregroundStyle(.teal)
            VStack(alignment: .leading, spacing: 2) {
                Text("Update ready (build \(build))").font(.headline)
                Text(host.clientConnected ? "Your iPad will be offered it first. The Mac app updates itself after you disconnect."
                                          : "Installs by itself once your iPad has it, or update the Mac now.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Update Mac Now") { host.updateMacNow() }.disabled(host.clientConnected || host.updating)
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.teal.opacity(0.12)))
    }
    private var filesCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Files", systemImage: "arrow.up.arrow.down.square").font(.headline)
                Spacer()
                Button("Send Files…") { chooseFiles() }.disabled(!host.filesReady)
            }
            Text(host.filesReady ? "Drop files anywhere on this window to send them to your iPad (Files › SkyDesk). Files from the iPad land in Downloads."
                                 : (host.allowFiles ? "Update SkyDesk on the iPad to send files." : "File transfers are off in Display & quality."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(host.transfers.prefix(5)) { item in TransferRow(item: item) }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).stroke(.quaternary))
    }
    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true; panel.canChooseDirectories = false; panel.prompt = "Send to iPad"
        if panel.runModal() == .OK { host.sendFiles(panel.urls) }
    }

    private var pairingCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("On your iPad, open SkyDesk and enter").font(.headline)
            VStack(alignment: .leading, spacing: 4) {
                Text("ADDRESS").font(.caption.bold()).foregroundStyle(.secondary)
                if host.lanAddresses.isEmpty {
                    Text("No network. Connect this Mac to Wi-Fi.").foregroundStyle(.secondary)
                } else {
                    ForEach(host.lanAddresses) { address in
                        HStack {
                            Text(address.address).font(.system(size: 22, weight: .semibold, design: .monospaced)).textSelection(.enabled)
                            Text(address.connectionName).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            copyButton(address.address, label: "Copy address")
                        }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("PASSWORD").font(.caption.bold()).foregroundStyle(.secondary)
                HStack {
                    Text(hidePassword ? "••••••••" : (host.password.isEmpty ? "—" : host.password))
                        .font(.system(size: 22, weight: .semibold, design: .monospaced)).textSelection(.enabled)
                        .accessibilityLabel(hidePassword ? "Password hidden" : "Password \(host.password)")
                    Spacer()
                    Button { hidePassword.toggle() } label: { Image(systemName: hidePassword ? "eye" : "eye.slash") }
                        .help(hidePassword ? "Show password" : "Hide password")
                    copyButton(host.password, label: "Copy password")
                    Button("Change…") { editingPassword = true }.disabled(host.busy || host.clientConnected || host.password.isEmpty)
                }
            }
            if host.lanAddresses.contains(where: { $0.connectionName == LANAddressDiscovery.vpnLabel }) {
                Text("Away from home, with your iPad on the same VPN (WireGuard), type the VPN address.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Text("Your iPad remembers it, so you only type it once. Dashes and spaces don't matter; capital letters do.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).stroke(.quaternary))
    }
    private var devicesCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Paired iPads").font(.headline)
            if host.devices.devices.isEmpty {
                Text("None yet. An iPad gets its own key the first time it connects with the password (SkyDesk build 37 or later on the iPad).")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(host.devices.devices) { device in
                HStack {
                    Image(systemName: "ipad.landscape").foregroundStyle(.teal)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(device.name)
                        Text("Last connected \(device.lastSeen.formatted(.relative(presentation: .named)))").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Remove", role: .destructive) { host.removeDevice(device.id) }
                }
            }
            Toggle(isOn: $host.allowPasswordPairing) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Let new iPads pair with the password")
                    Text(host.allowPasswordPairing
                         ? "Paired iPads keep working if you change the password or switch this off. A removed iPad can pair again while this is on: change the password too if it shouldn't."
                         : "Only the iPads listed above can connect. The password opens nothing.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }.toggleStyle(.switch).disabled(host.devices.devices.isEmpty || host.pairingLocked)
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).stroke(.quaternary))
    }
    private func copyButton(_ text: String, label: String) -> some View {
        Button {
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
        } label: { Image(systemName: "doc.on.doc") }.help(label).accessibilityLabel(label).disabled(text.isEmpty)
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("SkyDesk needs permission before your iPad can connect", systemImage: "exclamationmark.triangle.fill")
                .font(.headline).foregroundStyle(.orange)
            if !host.screenAllowed {
                HStack { Text("Screen Recording: lets SkyDesk send your screen"); Spacer(); Button("Allow…") { host.requestScreen() } }
            }
            if host.allowInput && !host.inputAllowed {
                HStack { Text("Accessibility: lets your iPad click and type"); Spacer(); Button("Allow…") { host.requestInput() } }
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.orange.opacity(0.12)))
    }

    private var settings: some View {
        DisclosureGroup(isExpanded: $showSettings) {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Desktop", selection: $host.useiPadDesktop) {
                    Text("Separate iPad desktop (recommended)").tag(true)
                    Text("Mirror a Mac display").tag(false)
                }
                if !host.useiPadDesktop {
                    HStack {
                        Picker("Display", selection: $host.displayID) {
                            if host.displays.isEmpty { Text("Refresh to choose a display").tag(UInt32(0)) }
                            ForEach(host.displays, id: \.displayID) { display in
                                Text("Display \(display.displayID) · \(display.width) × \(display.height)").tag(display.displayID)
                            }
                        }
                        Button { Task { await host.refreshDisplays() } } label: { Image(systemName: "arrow.clockwise") }
                    }
                    Picker("Resolution cap", selection: $host.longestEdge) {
                        Text("1920 · fast").tag(1920); Text("2560 · balanced").tag(2560); Text("Native · up to 4096").tag(4096)
                    }
                }
                HStack {
                    Picker("Frame rate", selection: $host.fps) { Text("30").tag(30); Text("60").tag(60); Text("120").tag(120) }
                    Picker(host.adaptiveBitrate ? "Bitrate, up to" : "Bitrate", selection: $host.bitrateMbps) {
                        ForEach([15, 25, 40, 60, 80], id: \.self) { Text("\($0) Mbps").tag($0) }
                    }
                }
                Toggle("Lower the bitrate when the network is slow (recommended)", isOn: $host.adaptiveBitrate)
                Toggle("Allow keyboard, trackpad and touch input", isOn: $host.allowInput)
                Toggle("Sync clipboard text with the iPad automatically", isOn: $host.allowClipboard)
                Toggle("Allow file transfers (incoming files go to Downloads)", isOn: $host.allowFiles)
                Toggle("Play this Mac's sound on the iPad", isOn: $host.allowAudio)
                Text("The Mac's own speakers go quiet only while the iPad is playing. macOS asks once for permission to record system audio.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Toggle("Low-latency rate control (experimental)", isOn: $host.lowLatencyRateControl)
                Text("Changes apply the next time the iPad connects.").font(.caption).foregroundStyle(.secondary)
                Toggle("Keep this Mac awake while SkyDesk is ready (it won't sleep on its own)", isOn: $host.keepAwake)
            }.padding(.top, 8).disabled(host.clientConnected || host.busy)
        } label: { Text("Display & quality").font(.headline) }
    }
}

private struct PasswordSheet: View {
    @ObservedObject var host: HostModel
    @Binding var isPresented: Bool
    @State private var text = ""
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Change password").font(.title2.bold())
            Text("Your iPad will ask for the new password once. Use at least \(PairingPassword.minimumLength) characters; longer and random is safer.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("New password", text: $text).textFieldStyle(.roundedBorder)
                .font(.system(.title3, design: .monospaced)).onSubmit(save)
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Button("Make a random one") {
                    Task { if let message = await host.randomPassword() { error = message } else { isPresented = false } }
                }
                Spacer()
                Button("Cancel") { isPresented = false }.keyboardShortcut(.cancelAction)
                Button("Save", action: save).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(text.isEmpty || host.busy)
            }
        }.padding(22).frame(width: 420)
    }
    private func save() {
        Task { if let message = await host.setPassword(text) { error = message } else { isPresented = false } }
    }
}

/// The "SD" mark used in the app icon, drawn live so it stays sharp at any size.
struct AppMark: View {
    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            ZStack {
                RoundedRectangle(cornerRadius: side * 0.225, style: .continuous).fill(.black)
                HStack(spacing: -side * 0.02) {
                    Text("S").foregroundStyle(.white)
                    Text("D").foregroundStyle(Color(red: 0, green: 0.9, blue: 0.85))
                }.font(.system(size: side * 0.5, weight: .heavy, design: .rounded))
            }.frame(width: side, height: side)
        }.accessibilityHidden(true)
    }
}

private struct TransferRow: View {
    let item: FileTransferEngine.Progress
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.outgoing ? "arrow.up.circle" : "arrow.down.circle").foregroundStyle(.teal)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name).lineLimit(1).truncationMode(.middle)
                switch item.state {
                case .active:
                    ProgressView(value: item.fraction).controlSize(.small)
                case .saved(let name):
                    Text(item.outgoing ? "Sent to iPad" : "Saved to Downloads as \(name)").font(.caption).foregroundStyle(.secondary)
                case .failed(let reason):
                    Text(reason).font(.caption).foregroundStyle(.red).lineLimit(2)
                }
            }
            Spacer()
            Text(ByteCountFormatter.string(fromByteCount: Int64(item.size), countStyle: .file)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            if case .saved(let name) = item.state, !item.outgoing {
                Button { NSWorkspace.shared.activateFileViewerSelecting([HostModel.downloads.appendingPathComponent(name)]) } label: {
                    Image(systemName: "magnifyingglass")
                }.buttonStyle(.borderless).help("Show in Finder")
            }
        }
    }
}

/// Only for the development self-check; touched on the sound tap's queue, read after it has stopped.
private final class SmokeAudioCounts: @unchecked Sendable {
    var buffers = 0, frames = 0, packets = 0, bytes = 0, failures = 0
    var stage = "not started"
    var peak: Float = 0
}
