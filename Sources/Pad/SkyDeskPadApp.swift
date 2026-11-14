import SwiftUI
import UniformTypeIdentifiers

/// UIKit owns the window (build 31) so the root view controller can keep the app in landscape; SwiftUI draws
/// everything inside it, exactly as before.
///
/// The window and the session's lifecycle hang off scene notifications, not the scene delegate: iPadOS reopens an
/// app with the scene set-up it saved earlier, and a set-up saved by a build before 31 names a delegate that draws
/// nothing here. Build 31 relied on its own delegate and came up black after the update until the app was fully
/// closed (user report 2026-11-13); notifications arrive whichever delegate the saved set-up names.
@main
final class PadAppDelegate: UIResponder, UIApplicationDelegate {
    let client = ClientModel()
    private var windows: [ObjectIdentifier: UIWindow] = [:]
    private var observers: [NSObjectProtocol] = []
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIScene.willConnectNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated { self?.attach(note.object as? UIScene) }
        })
        observers.append(center.addObserver(forName: UIScene.didDisconnectNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let scene = note.object as? UIScene else { return }
                self?.windows[ObjectIdentifier(scene)] = nil
            }
        })
        observers.append(center.addObserver(forName: UIScene.didActivateNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self else { return }
                // A scene that connected before this observer existed still gets its window.
                self.attach(note.object as? UIScene)
                #if targetEnvironment(simulator)
                if ProcessInfo.processInfo.environment["SKYDESK_DEMO"] != nil {
                    if self.client.info == nil { self.client.startDemo() }
                    return
                }
                #endif
                // The first call starts discovery and tries the most recent Mac; later calls only resume.
                self.client.launch()
                self.client.enterForeground()
            }
        })
        // Held keys and buttons are released on the Mac whenever the iPad stops being in front.
        observers.append(center.addObserver(forName: UIScene.willDeactivateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.client.releaseInput() }
        })
        observers.append(center.addObserver(forName: UIScene.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.client.enterBackground() }
        })
        return true
    }
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: "SkyDesk", sessionRole: session.role)
        configuration.delegateClass = PadSceneDelegate.self
        return configuration
    }
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        .landscape
    }
    private func attach(_ scene: UIScene?) {
        guard let scene = scene as? UIWindowScene, windows[ObjectIdentifier(scene)] == nil else { return }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = LandscapeHostingController(rootView: PadRootView(client: client))
        // In front of anything a delegate from an older saved set-up may have put up.
        if !(scene.delegate is PadSceneDelegate) { window.windowLevel = .normal + 1 }
        windows[ObjectIdentifier(scene)] = window
        window.makeKeyAndVisible()
    }
}

/// Only receives files: "Open in SkyDesk" from the share sheet or Files sends them to the Mac.
final class PadSceneDelegate: UIResponder, UIWindowSceneDelegate {
    private var client: ClientModel? { (UIApplication.shared.delegate as? PadAppDelegate)?.client }
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        open(options.urlContexts)
    }
    func scene(_ scene: UIScene, openURLContexts contexts: Set<UIOpenURLContext>) { open(contexts) }
    private func open(_ contexts: Set<UIOpenURLContext>) {
        let files = contexts.map(\.url).filter(\.isFileURL)
        if !files.isEmpty { client?.sendFiles(files) }
    }
}

/// Landscape only (user request, build 31). The supported-orientation answer is enough where iPadOS honours it.
/// If the scene is ever seen in portrait anyway, iPadOS is ignoring that answer, so from then on the controller
/// asks for landscape and holds it with the orientation lock (iPadOS 26+).
final class LandscapeHostingController<Content: View>: UIHostingController<Content> {
    private var sawPortrait = false
    private var lockWanted = false
    private var lastRequest = Date.distantPast
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }
    @available(iOS 26.0, *)
    override var prefersInterfaceOrientationLocked: Bool { lockWanted }
    override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); updateOrientation() }
    override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); updateOrientation() }
    private func updateOrientation() {
        guard let scene = view.window?.windowScene else { return }
        let landscape = scene.effectiveGeometry.interfaceOrientation.isLandscape
        if !landscape {
            sawPortrait = true
            if Date().timeIntervalSince(lastRequest) > 1 {
                lastRequest = Date()
                scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscape)) { _ in }
            }
        }
        let want = sawPortrait && landscape
        guard want != lockWanted else { return }
        lockWanted = want
        if #available(iOS 26.0, *) { setNeedsUpdateOfPrefersInterfaceOrientationLocked() }
    }
}

let aqua = Color(red: 0, green: 0.9, blue: 0.85)

private struct PadRootView: View {
    @ObservedObject var client: ClientModel
    var body: some View {
        Group {
            if let info = client.info {
                StreamView(client: client, info: info)
            } else if let label = client.autoConnectLabel {
                ConnectingView(label: label) { client.cancelConnecting() }
            } else {
                ConnectionView(client: client)
            }
        }
        .alert("SkyDesk", isPresented: Binding(get: { client.notice != nil }, set: { if !$0 { client.notice = nil } })) {
            Button("OK") { client.notice = nil }
        } message: { Text(client.notice ?? "") }
        .tint(.teal)
        .statusBarHidden(client.info != nil)
    }
}

// MARK: - Connecting

private struct ConnectingView: View {
    let label: String
    let cancel: () -> Void
    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            AppMark().frame(width: 96, height: 96)
            Text("Connecting to \(label)…").font(.title2.bold()).multilineTextAlignment(.center)
            ProgressView().controlSize(.large)
            Spacer()
            Button(action: cancel) {
                Text("Choose another Mac").frame(minWidth: 220, minHeight: 50)
            }.buttonStyle(.bordered).padding(.bottom, 40)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(.systemGroupedBackground))
    }
}

// MARK: - Connection screen

private struct ConnectionView: View {
    @ObservedObject var client: ClientModel
    @FocusState private var focus: Field?
    private enum Field { case address, password }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                HStack(spacing: 16) {
                    AppMark().frame(width: 64, height: 64)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("SkyDesk").font(.largeTitle.bold())
                        Text("Use your Mac on this iPad").foregroundStyle(.secondary)
                    }
                }.padding(.top, 24)
                if !client.status.isEmpty {
                    Label(client.status, systemImage: client.passwordNeeded ? "key.fill" : "info.circle")
                        .font(.callout).padding(14).frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 14).fill(client.passwordNeeded ? Color.orange.opacity(0.15) : Color(.secondarySystemGroupedBackground)))
                }
                if !client.recents.entries.isEmpty {
                    section("Recent") {
                        ForEach(client.recents.entries) { recent in
                            let saved = client.hasCredential(recent)
                            HostCard(icon: "desktopcomputer", title: recent.name,
                                     subtitle: recent.name == recent.address ? (saved ? "Password saved" : "Needs password")
                                                                            : recent.address + (saved ? "" : " · needs password"),
                                     busy: client.connecting) { client.connect(recent: recent) }
                                .contextMenu {
                                    Button(role: .destructive) { client.forget(recent) } label: { Label("Forget this Mac", systemImage: "trash") }
                                }
                        }
                    }
                }
                section("Nearby") {
                    if client.hosts.isEmpty {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("Looking for Macs running SkyDesk…").foregroundStyle(.secondary)
                        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemGroupedBackground)))
                    }
                    ForEach(client.hosts) { host in
                        HostCard(icon: "wifi", title: host.name,
                                 subtitle: client.selectedHost == host.id ? "Enter the password below" : "On this network",
                                 busy: client.connecting, selected: client.selectedHost == host.id) { client.connect(discovered: host) }
                    }
                }
                section("Add a Mac") {
                    VStack(spacing: 12) {
                        field(icon: "network") {
                            TextField(client.selectedHost.isEmpty ? "Mac address, like 192.168.1.20"
                                                                  : (client.hosts.first { $0.id == client.selectedHost }?.name ?? "Mac address"),
                                      text: $client.manualHost)
                                .keyboardType(.numbersAndPunctuation).textInputAutocapitalization(.never).autocorrectionDisabled()
                                .focused($focus, equals: .address).submitLabel(.next)
                                .onSubmit { focus = .password }
                                .onChange(of: client.manualHost) { _, value in if !value.isEmpty { client.selectedHost = "" } }
                        }
                        field(icon: "key") {
                            SecureField("Password from SkyDesk on your Mac", text: $client.pairingText)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                                .focused($focus, equals: .password).submitLabel(.go)
                                .onSubmit { client.connectFromForm() }
                        }
                        Button { focus = nil; client.connectFromForm() } label: {
                            HStack {
                                if client.connecting { ProgressView().tint(.white) }
                                Text(client.connecting ? "Connecting…" : "Connect").font(.headline)
                            }.frame(maxWidth: .infinity, minHeight: 52)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(client.connecting || (client.manualHost.isEmpty && client.selectedHost.isEmpty))
                        if client.connecting {
                            Button("Cancel") { client.cancelConnecting() }.frame(minHeight: 44)
                        }
                    }
                }
                if client.queuedFileCount > 0 {
                    Label("\(client.queuedFileCount) file\(client.queuedFileCount == 1 ? "" : "s") will be sent when you connect", systemImage: "tray.and.arrow.up")
                        .font(.callout).foregroundStyle(.teal)
                }
                Text("On your Mac, open SkyDesk Host: it shows the address and password. You only type them once. · Build \(ClientModel.ownBuild)")
                    .font(.footnote).foregroundStyle(.secondary)
                    .padding(.bottom, 32)
            }
            .frame(maxWidth: 580).padding(.horizontal, 24).frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color(.systemGroupedBackground))
        .onChange(of: client.passwordNeeded) { _, needed in
            // Focus moves on a later turn, never inside the update that changed `passwordNeeded`.
            if needed { DispatchQueue.main.async { focus = .password } }
        }
    }
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased()).font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }
    private func field<Content: View>(icon: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(.secondary).frame(width: 22)
            content().font(.title3)
        }.padding(.horizontal, 16).frame(minHeight: 54)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemGroupedBackground)))
    }
}

private struct HostCard: View {
    let icon: String
    let title: String
    let subtitle: String
    var busy = false
    var selected = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon).font(.title3).foregroundStyle(.teal)
                    .frame(width: 44, height: 44).background(Circle().fill(Color.teal.opacity(0.15)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline).foregroundStyle(.primary).lineLimit(1)
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .padding(14).frame(maxWidth: .infinity, minHeight: 72)
            .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemGroupedBackground)))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(selected ? Color.teal : .clear, lineWidth: 2))
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }.buttonStyle(.plain).disabled(busy)
    }
}

// MARK: - Streaming

private struct StreamView: View {
    @ObservedObject var client: ClientModel
    let info: StreamInfo
    @State private var expanded = true
    @State private var controlsFrame = CGRect.zero
    @State private var containerSize = CGSize.zero
    @State private var pickingFiles = false
    @State private var showingUpdate = false
    @State private var dropTargeted = false
    /// Where the user dragged the toolbar to; double-tap (or double-click) puts it back.
    @AppStorage("toolbarOffsetX") private var savedX = 0.0
    @AppStorage("toolbarOffsetY") private var savedY = 0.0
    @GestureState private var dragging = CGSize.zero
    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            RemoteDesktopView(client: client, info: info, controlsFrame: controlsFrame).ignoresSafeArea()
            VStack(spacing: 8) {
                toolbar
                    .background(GeometryReader { proxy in
                        Color.clear.preference(key: ControlsFramePreference.self, value: proxy.frame(in: .global))
                    })
                    .gesture(moveToolbar)
                    .onTapGesture(count: 2) { withAnimation(.snappy) { savedX = 0; savedY = 0 } }
                if !activeTransfers.isEmpty { transferList }
                if client.showStats { stats }
                if !info.inputEnabled {
                    Text("View only: remote input is off on the Mac").font(.caption).padding(8).background(.thinMaterial, in: Capsule())
                }
            }
            .offset(x: savedX + dragging.width, y: savedY + dragging.height)
            .padding(.top, 8).fixedSize(horizontal: false, vertical: true).zIndex(10)
            if dropTargeted {
                RoundedRectangle(cornerRadius: 20).stroke(aqua, style: StrokeStyle(lineWidth: 4, dash: [10, 8])).padding(12)
                    .overlay(Label("Drop to send to your Mac", systemImage: "laptopcomputer.and.arrow.down").font(.title2.bold())
                        .padding(16).background(.regularMaterial, in: Capsule()))
                    .allowsHitTesting(false).zIndex(20)
            }
        }
        .overlay(alignment: .bottomTrailing) { CornerReadout(stats: client.stats) }
        .background(GeometryReader { proxy in Color.clear.preference(key: ContainerSizePreference.self, value: proxy.size) })
        .onPreferenceChange(ContainerSizePreference.self) { containerSize = $0 }
        .persistentSystemOverlays(.hidden).ignoresSafeArea(.keyboard)
        .onPreferenceChange(ControlsFramePreference.self) { controlsFrame = $0 }
        .fileImporter(isPresented: $pickingFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { client.sendFiles(urls) }
        }
        .onDrop(of: [.item], isTargeted: $dropTargeted) { providers in receive(providers); return true }
        .sheet(isPresented: $showingUpdate) { UpdateSheet(client: client) }
    }

    /// Drag the toolbar anywhere (finger or iPad pointer); it is kept fully on screen.
    private var moveToolbar: some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .global)
            .updating($dragging) { value, state, _ in state = value.translation }
            .onEnded { value in
                // controlsFrame already includes the drag; nudge it back inside the screen if it went past an edge.
                let frame = controlsFrame
                var dx = value.translation.width, dy = value.translation.height
                if containerSize.width > 0 {
                    if frame.minX < 0 { dx -= frame.minX } else if frame.maxX > containerSize.width { dx -= frame.maxX - containerSize.width }
                    if frame.minY < 0 { dy -= frame.minY } else if frame.maxY > containerSize.height { dy -= frame.maxY - containerSize.height }
                }
                savedX += dx; savedY += dy
            }
    }
    private var activeTransfers: [FileTransferEngine.Progress] {
        client.transfers.filter { $0.state == .active }
    }
    private var transferList: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(activeTransfers.prefix(3)) { item in
                HStack(spacing: 8) {
                    Image(systemName: item.outgoing ? "arrow.up.circle.fill" : "arrow.down.circle.fill").foregroundStyle(aqua)
                    Text(item.name).font(.caption).lineLimit(1).truncationMode(.middle).frame(maxWidth: 220, alignment: .leading)
                    ProgressView(value: item.fraction).frame(width: 90)
                }
            }
        }.padding(10).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12)).allowsHitTesting(false)
    }
    /// Files dragged in from another app (Files, Photos…) in Split View or Slide Over.
    private func receive(_ providers: [NSItemProvider]) {
        for provider in providers {
            provider.loadFileRepresentation(forTypeIdentifier: UTType.item.identifier) { url, _ in
                guard let url else { return }
                // The provided file is deleted when this callback returns, so copy it first.
                let name = provider.suggestedName.map { $0 + (url.pathExtension.isEmpty || $0.hasSuffix("." + url.pathExtension) ? "" : "." + url.pathExtension) }
                    ?? url.lastPathComponent
                let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
                try? FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
                let target = copy.appendingPathComponent(FileNames.sanitized(name))
                guard (try? FileManager.default.copyItem(at: url, to: target)) != nil else { return }
                DispatchQueue.main.async { client.sendFiles([target]); try? FileManager.default.removeItem(at: copy) }
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 4) {
            Image(systemName: "line.3.horizontal").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                .frame(width: 18, height: 44).padding(.leading, 6)
                .accessibilityLabel("Drag to move the toolbar. Double-tap to put it back.")
            SessionStatusView(networkSymbol: client.networkSymbol, networkDescription: client.networkDescription)
                .padding(.horizontal, 8)
            if expanded {
                Divider().frame(height: 28).padding(.horizontal, 4)
                if client.updateBuild != nil {
                    ToolButton(title: "Update", icon: "arrow.down.circle.fill", active: true) { showingUpdate = true }
                }
                ToolButton(title: client.keyboardWanted ? "Hide keys" : "Keyboard",
                           icon: client.keyboardWanted ? "keyboard.chevron.compact.down" : "keyboard",
                           active: client.keyboardWanted) { client.toggleKeyboard() }
                    .disabled(info.inputEnabled != true)
                Menu {
                    Button { client.showDock() } label: { Label("Show Dock here", systemImage: "dock.rectangle") }
                    Divider()
                    Button("Escape") { client.shortcut(key: 41) }
                    Button("Tab") { client.shortcut(key: 43) }
                    Button("Switch app  ⌘Tab") { client.shortcut(key: 43, modifiers: 8) }
                    Button("Spotlight  ⌘Space") { client.shortcut(key: 44, modifiers: 8) }
                    Button("Copy  ⌘C") { client.shortcut(key: 6, modifiers: 8) }
                    Button("Paste  ⌘V") { client.shortcut(key: 25, modifiers: 8) }
                    Button("Undo  ⌘Z") { client.shortcut(key: 29, modifiers: 8) }
                    Menu("Desktops") {
                        Button("Mission Control  ⌃↑") { client.desktopSwipe(.up) }
                        Button("This app's windows  ⌃↓") { client.desktopSwipe(.down) }
                        Button("Next desktop  ⌃→") { client.desktopSwipe(.left) }
                        Button("Previous desktop  ⌃←") { client.desktopSwipe(.right) }
                    }
                    Divider()
                    Button("Release all keys") { client.releaseInput() }
                } label: { ToolLabel(title: "Shortcuts", icon: "command") }
                if info.displayBlankingSupported == true {
                    // The Mac may hold a switch back for some seconds (minimum time between display changes).
                    ToolButton(title: client.changingMacDisplay ? "Switching…" : client.macDisplayBlanked ? "Restore Mac" : "iPad only",
                               icon: client.macDisplayBlanked ? "display" : "display.slash",
                               active: client.macDisplayBlanked && !client.changingMacDisplay,
                               busy: client.changingMacDisplay) { client.toggleMacDisplay() }
                        .disabled(client.changingMacDisplay)
                        .accessibilityHint("Makes the iPad the Mac's only screen. Using the Mac's own keyboard or trackpad brings its screen back.")
                }
                Menu {
                    Section("Files") {
                        Button { pickingFiles = true } label: { Label("Send files to Mac…", systemImage: "square.and.arrow.up") }
                            .disabled(!client.filesReady)
                    }
                    Section("Clipboard") {
                        if client.clipboardSyncing {
                            Toggle("Sync clipboard with Mac", isOn: $client.syncClipboard)
                        } else {
                            Button { client.sendClipboard() } label: { Label("Send iPad clipboard to Mac", systemImage: "arrow.up.doc.on.clipboard") }
                            Button { client.getClipboard() } label: { Label("Get Mac clipboard", systemImage: "arrow.down.doc") }
                        }
                    }
                    Section {
                        Toggle("Show statistics", isOn: $client.showStats)
                        // Settings in a submenu keep More short enough that it never scrolls under the pointer.
                        Menu {
                            Toggle("Start in iPad only mode", isOn: $client.startIPadOnly)
                            Toggle("Play Mac sound on iPad", isOn: $client.playMacSound)
                            Toggle("iPad pointer (no delay)", isOn: $client.localPointer)
                            Picker("Pointer size", selection: $client.pointerScale) {
                                Text("Small").tag(0.75); Text("Medium (Mac size)").tag(1.0); Text("Large").tag(1.5); Text("Extra large").tag(2.0)
                            }.pickerStyle(.menu).disabled(!client.localPointer)
                            Toggle("Show keyboard for text fields", isOn: $client.automaticKeyboard)
                            Toggle("Detailed statistics", isOn: $client.showTimingDetails)
                            Toggle("Sharpen text", isOn: $client.sharpenText)
                            Toggle("Sharper colour (4:4:4, more data)", isOn: $client.sharperColour)
                            Toggle("Show frames sooner (less delay)", isOn: $client.presentOnArrival)
                            Toggle("Use USB cable when plugged in", isOn: $client.preferCable)
                            Section("SkyDesk build \(ClientModel.ownBuild)") { EmptyView() }
                        } label: { Label("Settings", systemImage: "gearshape") }
                    }
                } label: { ToolLabel(title: "More", icon: "ellipsis.circle") }
                ToolButton(title: "Disconnect", icon: "xmark", active: false) { client.disconnect() }
            }
            Button { withAnimation(.snappy) { expanded.toggle() } } label: {
                Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.body.weight(.semibold))
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }.accessibilityLabel(expanded ? "Hide controls" : "Show controls")
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
    }

    private var stats: some View { StatsHUD(stats: client.stats, details: client.showTimingDetails) }
}

/// Observes only the statistics, so their twice-a-second refresh redraws this box and nothing else.
private struct StatsHUD: View {
    @ObservedObject var stats: StreamStatsModel
    let details: Bool
    var body: some View {
        VStack(spacing: 3) {
            Text(stats.metrics).font(.system(.callout, design: .monospaced).bold())
            Text(stats.networkTiming).font(.system(.caption, design: .monospaced))
            Text(stats.displayTiming).font(.system(.caption, design: .monospaced))
            if details {
                Text(stats.timingDetails).font(.system(.caption2, design: .monospaced))
                Text(StatisticsText.explanation).font(.caption2).multilineTextAlignment(.center).frame(maxWidth: 520)
            }
        }.monospacedDigit().padding(10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12)).allowsHitTesting(false)
    }
}

/// Bitrate · click-to-screen delay · build, fixed in the bottom-right corner, always shown whether or not
/// "Show statistics" is on, with no box behind it (user request 2026-11-13). A thin dark edge keeps the white text
/// readable over a light Mac window. It never takes a touch or a click, so whatever is under it stays usable.
/// Observes only the statistics, like StatsHUD.
private struct CornerReadout: View {
    @ObservedObject var stats: StreamStatsModel
    var body: some View {
        Text(stats.corner.isEmpty ? "v\(ClientModel.ownBuild)" : stats.corner)
            .font(.system(size: 11, weight: .medium, design: .monospaced)).monospacedDigit()
            .foregroundStyle(.white)
            .shadow(color: .black, radius: 0.6).shadow(color: .black.opacity(0.9), radius: 1.5)
            .padding(.trailing, 10).padding(.bottom, 6)
            .allowsHitTesting(false)
            .accessibilityLabel("Stream: \(stats.corner)")
    }
}

/// Installing a newer build over Wi-Fi, including the one-time certificate setup.
private struct UpdateSheet: View {
    @ObservedObject var client: ClientModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch client.updateState {
                    case .idle, .failed:
                        Text("SkyDesk build \(client.updateBuild ?? 0) is ready on your Mac (you have \(ClientModel.ownBuild)).")
                            .font(.title3)
                        if case .failed(let reason) = client.updateState {
                            Label(reason, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        }
                        primary("Install Update") { client.installUpdate() }
                        Text("SkyDesk closes while iPadOS installs it. Open it again afterwards and it reconnects by itself. Your Mac's app updates itself after you disconnect.")
                            .font(.callout).foregroundStyle(.secondary)
                    case .preparing:
                        HStack(spacing: 12) { ProgressView(); Text("Preparing the update on your Mac…") }
                    case .needsCertificate:
                        Text("One-time setup").font(.title2.bold())
                        Text("Your iPad needs to trust your Mac's update server first. SkyDesk sends a small certificate over its own secure connection.")
                        primary("Get Certificate") { client.requestUpdateCertificate() }
                        safetyNote
                    case .certificateArrived:
                        Text("One-time setup").font(.title2.bold())
                        step(1, "Open Files and tap “\((client.certificateName as NSString).deletingPathExtension)”. iPadOS says “Profile Downloaded”.")
                        Button { client.openFilesFolder() } label: { Label("Open Files", systemImage: "folder") }.buttonStyle(.bordered)
                        step(2, "Open Settings › General › VPN & Device Management › SkyDesk wireless updates, and tap Install.")
                        step(3, "Then Settings › General › About › Certificate Trust Settings, and turn on “SkyDesk Update CA”.")
                        step(4, "Come back here and install.")
                        primary("Install Update") { client.installUpdate() }
                        safetyNote
                    case .installing:
                        Label("Installing…", systemImage: "arrow.down.app").font(.title3.bold())
                        if let left = client.closingForUpdate {
                            Text("Closing SkyDesk in \(left)… iPadOS finishes the update once SkyDesk is off screen.")
                                .font(.title3).monospacedDigit()
                            Button("Stay Open") { client.stayOpenForUpdate() }.buttonStyle(.bordered)
                        } else {
                            Text("Go to the Home Screen and iPadOS installs the update (watch the SkyDesk icon). Open SkyDesk again afterwards and it reconnects; the Mac app updates itself a few seconds after the iPad disconnects.")
                                .foregroundStyle(.secondary)
                            Button("Try Again") { client.installUpdate() }.buttonStyle(.bordered)
                        }
                    }
                }.padding(24).frame(maxWidth: 560, alignment: .leading)
            }
            .navigationTitle("Update SkyDesk")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
    }
    private func primary(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title).font(.headline).frame(maxWidth: .infinity, minHeight: 50) }.buttonStyle(.borderedProminent)
    }
    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)").font(.headline).frame(width: 28, height: 28).background(Circle().fill(Color.teal.opacity(0.2)))
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
    private var safetyNote: some View {
        Text("The certificate only works for private network addresses and .local names, so it can't be used to fake real websites. Remove it any time in Settings › General › VPN & Device Management.")
            .font(.footnote).foregroundStyle(.secondary)
    }
}

private struct ToolLabel: View {
    let title: String
    let icon: String
    var active = false
    /// Shows a spinner in place of the icon while the Mac is still carrying out the request.
    var busy = false
    var body: some View {
        VStack(spacing: 1) {
            if busy { ProgressView().controlSize(.small).frame(height: 20) }
            else { Image(systemName: icon).font(.system(size: 17, weight: .medium)) }
            Text(title).font(.system(size: 10, weight: .medium)).lineLimit(1)
        }
        .foregroundStyle(active ? Color.black : Color.primary)
        .padding(.horizontal, 8)
        .frame(minWidth: 58, minHeight: 46)
        .fixedSize()
        .background(RoundedRectangle(cornerRadius: 10).fill(active ? aqua : .clear))
        .contentShape(Rectangle())
    }
}

private struct ToolButton: View {
    let title: String
    let icon: String
    let active: Bool
    var busy = false
    let action: () -> Void
    var body: some View {
        Button(action: action) { ToolLabel(title: title, icon: icon, active: active, busy: busy) }.accessibilityLabel(title)
    }
}

private struct ContainerSizePreference: PreferenceKey {
    static var defaultValue = CGSize.zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

private struct ControlsFramePreference: PreferenceKey {
    static var defaultValue = CGRect.zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}

/// The "SD" mark used in the app icon.
struct AppMark: View {
    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            ZStack {
                RoundedRectangle(cornerRadius: side * 0.225, style: .continuous).fill(.black)
                HStack(spacing: -side * 0.02) {
                    Text("S").foregroundStyle(.white)
                    Text("D").foregroundStyle(aqua)
                }.font(.system(size: side * 0.5, weight: .heavy, design: .rounded))
            }.frame(width: side, height: side)
        }.accessibilityHidden(true)
    }
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
