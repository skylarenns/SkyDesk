import SwiftUI
import AppKit

@main
struct SkyDeskHostApp: App {
    @StateObject private var host = HostModel()
    var body: some Scene {
        WindowGroup("SkyDesk Host") {
            HostView(host: host)
                .task { await host.loadPairing() }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in host.stop() }
                .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)) { _ in host.stop() }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    host.refreshPermissions(); host.refreshNetworkAddresses()
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
                    host.refreshInputGeometry()
                }
                .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in host.refreshNetworkAddresses() }
        }
        .defaultSize(width: 620, height: 690)
        .windowResizability(.contentSize)
    }
}

private struct HostView: View {
    @ObservedObject var host: HostModel
    @State private var revealKey = false
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                Image(systemName: "rectangle.inset.filled.and.person.filled").font(.system(size: 32)).foregroundStyle(.teal)
                VStack(alignment: .leading) {
                    Text("SkyDesk").font(.largeTitle.bold())
                    Text("Your Mac. On your iPad.").foregroundStyle(.secondary)
                }
                Spacer()
                Label(host.running ? "Sharing on" : "Private", systemImage: host.running ? "dot.radiowaves.left.and.right" : "lock.shield")
                    .foregroundStyle(host.running ? .green : .secondary)
            }
            GroupBox("Permissions") {
                HStack {
                    Label("Screen Recording", systemImage: host.screenAllowed ? "checkmark.circle.fill" : "circle")
                    Spacer(); Button("Allow…") { host.requestScreen() }.disabled(host.screenAllowed)
                }.padding(4)
                HStack {
                    Label("Accessibility", systemImage: host.inputAllowed ? "checkmark.circle.fill" : "circle")
                    Spacer(); Button("Allow…") { host.requestInput() }.disabled(host.inputAllowed)
                }.padding(4)
            }
            GroupBox("Display & performance") {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Desktop", selection: $host.useiPadDesktop) {
                        Text("iPad Retina · separate desktop").tag(true)
                        Text("Mirror Mac display").tag(false)
                    }
                    if host.useiPadDesktop {
                        Text("Matches the connected iPad's pixels at 2× Retina scale. Move Mac windows onto the SkyDesk display to use them on iPad.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    } else {
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
                        Text("1920 · fast").tag(1920); Text("2560 · balanced").tag(2560)
                        Text("Native · up to 4096").tag(4096)
                    }
                    }
                    HStack {
                        Picker("FPS target", selection: $host.fps) { Text("30").tag(30); Text("60").tag(60); Text("120").tag(120) }
                        Picker("Bitrate", selection: $host.bitrateMbps) {
                            ForEach([15, 25, 40, 60, 80], id: \.self) { Text("\($0) Mbps").tag($0) }
                        }
                    }
                    Toggle("Allow keyboard, trackpad, and touch input", isOn: $host.allowInput)
                    Toggle("Allow text clipboard transfers", isOn: $host.allowClipboard)
                    Toggle("Use low-latency rate control (compare performance)", isOn: $host.lowLatencyRateControl)
                    Text("120 FPS requires a 120 Hz source display. Retina preserves aspect ratio; resolution cap trades sharpness for speed.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.padding(6)
            }.disabled(host.running || host.busy)
            GroupBox("Pair your iPad") {
                VStack(alignment: .leading, spacing: 10) {
                    if host.lanAddresses.isEmpty {
                        Text("No LAN IPv4 address. Connect your Mac to Wi-Fi or Ethernet, or select this Mac in SkyDesk on iPad.")
                            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    } else {
                        ForEach(host.lanAddresses) { address in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(address.address).font(.system(.title3, design: .monospaced)).textSelection(.enabled)
                                        .accessibilityLabel("Mac address: \(address.address)")
                                    Text(address.connectionName).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Copy address") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(address.address, forType: .string)
                                }.accessibilityLabel("Copy address \(address.address)")
                            }
                        }
                        Text("Updates automatically · TCP port \(String(DeskNetwork.port))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Divider()
                    Text("Connect on the same LAN. Enter the address above or select this Mac in SkyDesk on iPad, then paste this key. Anyone with the key can connect while sharing is on.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        if revealKey { Text(host.pairingText).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                        else { Text("256-bit pairing key stored in Keychain").foregroundStyle(.secondary) }
                        Spacer()
                        Button(revealKey ? "Hide" : "Reveal") { revealKey.toggle() }
                    }
                    HStack {
                        if host.pairingLocked {
                            Button("Unlock pairing key…") { Task { await host.loadPairing(allowInteraction: true) } }
                                .disabled(host.busy)
                        }
                        if host.busy { ProgressView().controlSize(.small) }
                        Button("Copy key") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(host.pairingText, forType: .string)
                        }.disabled(host.pairingText.isEmpty)
                        Button("Replace key") { host.rotateKey() }.disabled(host.running || host.busy || host.pairingText.isEmpty)
                        Spacer()
                    }
                }.padding(6)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(host.status).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Text(host.metrics).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            HStack {
                Text("LAN streaming · HEVC · encrypted transport").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(host.running ? "Stop Sharing" : "Start Sharing") {
                    if host.running { host.stop() } else { Task { await host.start() } }
                }.buttonStyle(.borderedProminent).tint(host.running ? .red : .teal).disabled(host.busy || host.pairingText.isEmpty)
            }
        }.padding(24).frame(width: 620)
    }
}
