import SwiftUI

@main
struct SkyDeskPadApp: App {
    @StateObject private var client = ClientModel()
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup {
            PadRootView(client: client)
                .task { client.browse() }
                .onChange(of: phase) { _, phase in
                    if phase == .background { client.suspend() }
                    else if phase == .inactive { client.releaseInput() }
                }
        }
    }
}

private struct PadRootView: View {
    @ObservedObject var client: ClientModel
    @State private var showControls = true
    @State private var controlsFrame = CGRect.zero
    var body: some View {
        Group {
            if let info = client.info {
                ZStack(alignment: .top) {
                    Color.black.ignoresSafeArea()
                    RemoteDesktopView(client: client, info: info, controlsFrame: controlsFrame).ignoresSafeArea()
                    VStack(spacing: 8) {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 12) {
                                sessionStatus
                                if showControls { Divider().frame(height: 28); toolbarButtons }
                                disclosureButton
                            }
                            VStack(spacing: 4) {
                                HStack { sessionStatus; Spacer(); disclosureButton }
                                if showControls { HStack(spacing: 12) { toolbarButtons } }
                            }
                        }
                        .buttonStyle(.plain).padding(.horizontal, 12).padding(.vertical, 4)
                        .background(.regularMaterial, in: Capsule())
                        .background(GeometryReader { proxy in
                            Color.clear.preference(key: ControlsFramePreference.self, value: proxy.frame(in: .global))
                        })
                        if client.showStats {
                            VStack(spacing: 4) {
                                Text(client.metrics).font(.system(.callout, design: .monospaced).bold()).monospacedDigit()
                                Text(client.networkTiming).font(.system(.caption, design: .monospaced)).monospacedDigit()
                                Text(client.displayTiming).font(.system(.caption, design: .monospaced)).monospacedDigit()
                                Text(client.timingDetails).font(.system(.caption2, design: .monospaced)).monospacedDigit()
                                if client.showTimingDetails {
                                    Text(StatisticsText.explanation).font(.caption2).multilineTextAlignment(.center)
                                        .frame(maxWidth: 520)
                                }
                            }.padding(10).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12)).allowsHitTesting(false)
                        }
                        if !info.inputEnabled { Text("View only · remote input disabled on Mac").font(.caption).padding(8).background(.thinMaterial, in: Capsule()) }
                    }.padding(.top, 8).fixedSize(horizontal: false, vertical: true).zIndex(10)
                }.persistentSystemOverlays(.hidden).ignoresSafeArea(.keyboard)
                    .onPreferenceChange(ControlsFramePreference.self) { controlsFrame = $0 }
            } else {
                connectionView
            }
        }
        .alert("SkyDesk", isPresented: Binding(get: { client.notice != nil }, set: { if !$0 { client.notice = nil } })) {
            Button("OK") { client.notice = nil }
        } message: { Text(client.notice ?? "") }
        .tint(.teal)
        .statusBarHidden(client.info != nil)
    }
    private var sessionStatus: some View {
        SessionStatusView(networkSymbol: client.networkSymbol, networkDescription: client.networkDescription)
    }
    private var disclosureButton: some View {
        Button { showControls.toggle() } label: {
            Label(showControls ? "Hide" : "Controls", systemImage: showControls ? "chevron.up" : "chevron.down")
                .frame(minWidth: 92, minHeight: 44).contentShape(Rectangle())
        }.accessibilityLabel(showControls ? "Hide controls" : "Show controls")
    }
    @ViewBuilder private var toolbarButtons: some View {
        Button { client.disconnect() } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }
            .accessibilityLabel("Disconnect")
        Menu {
            Button("Escape") { client.shortcut(key: 41) }
            Button("Tab") { client.shortcut(key: 43) }
            Button("Switch Mac app ⌘Tab") { client.shortcut(key: 43, modifiers: 8) }
            Button("Spotlight ⌘Space") { client.shortcut(key: 44, modifiers: 8) }
            Button("Copy ⌘C") { client.shortcut(key: 6, modifiers: 8) }
            Button("Paste ⌘V") { client.shortcut(key: 25, modifiers: 8) }
            Button("Undo ⌘Z") { client.shortcut(key: 29, modifiers: 8) }
            Button("Release all keys") { client.releaseInput() }
        } label: { Label("Keys", systemImage: "command").frame(minHeight: 44) }
        Button { client.toggleKeyboard() } label: {
            Image(systemName: client.keyboardWanted ? "keyboard.chevron.compact.down" : "keyboard")
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }.accessibilityLabel(client.keyboardWanted ? "Hide keyboard" : "Show keyboard")
            .disabled(client.info?.inputEnabled != true)
        Toggle("Auto keyboard", isOn: $client.automaticKeyboard)
            .toggleStyle(.button).buttonStyle(.bordered).frame(minHeight: 44)
            .disabled(client.info?.textInputEnabled != true)
        if client.info?.displayBlankingSupported == true {
            Button { client.toggleMacDisplay() } label: {
                Label(client.macDisplayBlanked ? "Restore Mac" : "iPad only", systemImage: client.macDisplayBlanked ? "display" : "display.slash")
                    .frame(minHeight: 44)
            }.disabled(client.changingMacDisplay)
                .accessibilityHint("Makes iPad the only active display. Local Mac keyboard or trackpad activity restores the original layout.")
        }
        Menu {
            Button("Send iPad clipboard to Mac") { client.sendClipboard() }
            Button("Get Mac clipboard") { client.getClipboard() }
        } label: { Label("Clipboard", systemImage: "document.on.clipboard").frame(minHeight: 44) }
        Menu {
            Toggle("Show FPS, bitrate and latency", isOn: $client.showStats)
            Toggle("Explain the statistics", isOn: $client.showTimingDetails)
            Toggle("Sharpen text", isOn: $client.sharpenText)
            Toggle("Use USB cable when plugged in (next connect)", isOn: $client.preferCable)
        } label: { Image(systemName: "gauge.with.dots.needle.67percent").frame(width: 44, height: 44) }
            .accessibilityLabel("Display settings and statistics")
    }
    private var connectionView: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        Image(systemName: "display.2").font(.system(size: 44)).foregroundStyle(.teal)
                        Text("Your Mac, within reach.").font(.largeTitle.bold())
                        Text("A native desktop stream for your iPad. Connect on the same network, pair once, and keep your Mac's keyboard shortcuts.")
                            .foregroundStyle(.secondary)
                    }.padding(.vertical, 18)
                }
                Section("Nearby Macs") {
                    if client.hosts.isEmpty {
                        Label("Looking for SkyDesk hosts…", systemImage: "dot.radiowaves.left.and.right")
                        Text("Open SkyDesk Host on your Mac and choose Start Sharing.").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(client.hosts) { host in
                        Button { client.manualHost = ""; client.select(host.id) } label: {
                            HStack { Label(host.name, systemImage: "desktopcomputer"); Spacer(); if client.selectedHost == host.id && client.manualHost.isEmpty { Image(systemName: "checkmark.circle.fill") } }
                        }
                    }
                }
                Section {
                    TextField("Mac address, e.g. My-Mac.local", text: $client.manualHost)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    SecureField("Pairing key from SkyDesk Host", text: $client.pairingText)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().font(.system(.body, design: .monospaced))
                } header: { Text("Pair securely") } footer: {
                    Text("Address is optional when a nearby Mac is selected. Paste the 64-character key from your Mac. Saved keys stay in this device's Keychain.")
                }
                Section {
                    HStack {
                        Text(client.status).foregroundStyle(.secondary)
                        Spacer()
                        if client.connecting { ProgressView(); Button("Cancel") { client.disconnect() } }
                        else { Button("Connect") { client.connect() }.buttonStyle(.borderedProminent).disabled(client.pairingText.isEmpty) }
                    }
                }
                Section("Controls") {
                    Label("Keyboard & trackpad: point, click, drag, and scroll", systemImage: "keyboard")
                    Label("Touch: tap to click, drag to move, two fingers to scroll or right-click", systemImage: "hand.draw")
                    Label("Use Keys for shortcuts reserved by iPadOS", systemImage: "command")
                    Label("Clipboard transfers are explicit and text-only", systemImage: "document.on.clipboard")
                    Text("120 FPS is a target. Source refresh rate, network, power mode, and thermal limits determine actual performance. Local display timing excludes capture and network transit.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.navigationTitle("SkyDesk")
        }
    }
}

private struct ControlsFramePreference: PreferenceKey {
    static var defaultValue = CGRect.zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}

private struct SessionStatusView: View {
    let networkSymbol: String
    let networkDescription: String
    @State private var battery = UIDevice.current.batteryLevel
    @State private var charging = UIDevice.current.batteryState == .charging || UIDevice.current.batteryState == .full
    private var batterySymbol: String {
        if charging { return "battery.100percent.bolt" }
        let level = max(0, min(100, Int((battery * 100).rounded())))
        return "battery.\(min(100, ((level + 12) / 25) * 25))percent"
    }
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(context.date, format: .dateTime.hour().minute()).font(.caption.bold())
                    Text(context.date, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day()).font(.caption2)
                }.monospacedDigit()
                Image(systemName: networkSymbol).accessibilityLabel(networkDescription)
                HStack(spacing: 3) {
                    Image(systemName: batterySymbol)
                    Text(battery < 0 ? "—" : "\(Int((battery * 100).rounded()))%")
                        .font(.caption.monospacedDigit())
                }.accessibilityLabel(battery < 0 ? "Battery unavailable" : "Battery \(Int((battery * 100).rounded())) percent")
            }.fixedSize()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.batteryLevelDidChangeNotification)) { _ in
            battery = UIDevice.current.batteryLevel
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.batteryStateDidChangeNotification)) { _ in
            charging = UIDevice.current.batteryState == .charging || UIDevice.current.batteryState == .full
        }
    }
}
