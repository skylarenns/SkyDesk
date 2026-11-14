import SwiftUI
import AppKit

@main
struct SkyDeskHostApp: App {
    @StateObject private var host = HostModel()
    var body: some Scene {
        WindowGroup("SkyDesk Host") {
            HostView(host: host)
                .task { await host.loadPairing() }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in host.shutdown() }
                .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)) { _ in host.sleep() }
                .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in host.wake() }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    host.refreshPermissions(); host.refreshNetworkAddresses()
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
                    host.refreshInputGeometry()
                }
                .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in host.refreshNetworkAddresses() }
        }
        .defaultSize(width: 520, height: 640)
        .windowResizability(.contentSize)
    }
}

private struct HostView: View {
    @ObservedObject var host: HostModel
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

    private enum Phase { case connected, waiting, standby, off, locked }
    private var phase: Phase {
        if host.pairingLocked { return .locked }
        if host.clientConnected { return .connected }
        if host.listening { return host.sharing ? .waiting : .standby }
        return .off
    }

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
    private var headline: String {
        switch phase {
        case .connected: return "iPad connected"
        case .waiting: return "Sharing is on"
        case .standby: return "Ready for your iPad"
        case .off: return "Sharing is off"
        case .locked: return "Password locked"
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
            Text("Your iPad remembers it, so you only type it once. Dashes and spaces don't matter; capital letters do.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
                    Picker("Bitrate", selection: $host.bitrateMbps) {
                        ForEach([15, 25, 40, 60, 80], id: \.self) { Text("\($0) Mbps").tag($0) }
                    }
                }
                Toggle("Allow keyboard, trackpad and touch input", isOn: $host.allowInput)
                Toggle("Sync clipboard text with the iPad automatically", isOn: $host.allowClipboard)
                Toggle("Allow file transfers (incoming files go to Downloads)", isOn: $host.allowFiles)
                Toggle("Low-latency rate control (experimental)", isOn: $host.lowLatencyRateControl)
                Text("Changes apply the next time the iPad connects.").font(.caption).foregroundStyle(.secondary)
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
