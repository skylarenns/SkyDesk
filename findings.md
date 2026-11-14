# Findings

## Live LAN address display
- Before the change, a native UI check for the current IP returned false; the host had no address text or copy action.
- `LANAddressDiscovery` reads current interface addresses, filters for active Wi-Fi/Ethernet IPv4, removes loopback, point-to-point, multicast and self-assigned addresses, and places the primary physical interface first. It returns a fresh snapshot on every refresh, including an empty snapshot after disconnect.
- The host refreshes every two seconds independently of sharing and on activation. The installed UI displays 10.240.173.132 with a Wi-Fi label and Copy address; `ipconfig getifaddr en0` reports the same value.
- Four focused tests pass: primary-interface ordering, disconnect/DHCP changes, unusable interfaces/addresses, and VPN/no-default-route behavior. macOS builds and strict signature verification pass.
- The first ad-hoc rebuild reproduced loss of permission/keychain recognition. The build script forced ad-hoc signing and project.yml masked Local.xcconfig's team. Both overrides were removed; local settings now select the existing Apple Development identity and team [REDACTED_SIGNING_TEAM]. The installed app's designated requirement is certificate/identifier based rather than a build hash.
- Existing key unlocked successfully without replacement. After macOS authorization and permission-entry refresh, both permissions are recognized. Host PID 93447 listens on 48772 with two established connections from 10.240.173.127. Native UI verifies the current IP, Copy address, and sharing on. User explicitly confirmed desktop and input work.
- User reported 5–30 FPS and RTT usually around 15 ms with spikes near 80 ms, then clarified low FPS occurs mostly on a still desktop. Renderer statistics count unique newly presented frames; capture ignores non-complete frames. This is not a reproducible motion-throughput failure yet. No speculative queue, bitrate, or codec changes were made; sustained-motion FPS and end-to-end latency remain unmeasured.

## Accessibility follow-up
- User screenshot shows connection pending; TCP probes to 127.0.0.1 and 10.62.101.30 port 48772 both return errno 61 (connection refused).
- Host restarted while being inspected. Screen Recording is now recognized; Accessibility is not. System Settings shows the SkyDesk Host Device Control and Data Access toggle on.
- Host currently uses ad-hoc signing with a hash-based designated requirement. Permission attribution to a different build remains a hypothesis, not a verified TCC record.
- Direct read-only TCC database queries are unavailable. Do not modify/reset TCC as a substitute for diagnosis.
- Restarting the host and toggling its existing grant off/on did not fix recognition. Removing only SkyDesk's permission entry and re-adding `build/Build/Products/Debug/SkyDesk Host.app` did. Native screenshot confirms both permission checkmarks, Sharing on, 80 Mbps, 120 FPS target, and input enabled. No source changes or key replacement were needed.
- `lsof` confirms SkyDesk PID 61255 listening on TCP 48772. Loopback and the current en0 address 10.240.173.132 accept TCP. The previous en7 interface no longer exists; its old 10.62.101.30 address times out. A TCP probe does not verify iPad pairing or streaming.

- Xcode 27.2, Swift 6.4.2, iPhoneOS 27.2 SDK, and XcodeGen are installed.
- Apple documents `minimumFrameInterval` as a maximum capture cadence, not a promise of new frames. Source refresh rate and content changes limit delivery.
- ScreenCaptureKit can deliver IOSurface-backed buffers directly into VideoToolbox. Use a small capture queue and no B-frame reordering.
- Network.framework exposes TLS pre-shared keys through Security.framework. Verify this locally with real connections before relying on pairing.
- Real iPad presentation and input-to-photon latency must be measured separately from codec and transport timings.
- TLS loopback passes for valid keys; wrong keys never reach application readiness and close at the 10-second deadline.
- Hardware HEVC encode and decode are both confirmed through a 120-frame 2560×1600 synthetic encrypted loopback run. Static pixels and local transport do not prove animated 120 FPS on LAN.
- macOS, iOS simulator, and physical iOS compilation succeeded. Subsequently the signed Release app was installed and launched on the physical M5 iPad.
- The local Xcode installation supplies CoreSimulator and SDKs but has no `Contents/Developer/Applications/Simulator.app`; only simulator process launch was verified.

## Primary references
- https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/minimumframeinterval
- https://developer.apple.com/videos/play/wwdc2022/10155/
- https://developer.apple.com/videos/play/wwdc2021/10158/
- https://developer.apple.com/documentation/security/sec_protocol_options_add_pre_shared_key(_:_:_:)

## Native iPad desktop and interaction, 2026-11-12
- User chose a separate iPad-sized desktop and confirmed USB connection. Physical M5 iPad UDID 00008142-001278A43EF3C01C is connected.
- Fixed two-frame flow-control window limited a deterministic 120 Hz capture / 32 ms feedback simulation to 60 accepted FPS. Adaptive bounded 2–6 frame window reaches 119 accepted FPS in the same simulation, rejects stale backlog, and ignores congestion spikes when sizing. Actual scrolling on iPad still needs measurement.
- 22 Swift tests pass, including native pixel handshake, keyboard viewport/input inverse mapping, text-focus validation, and pacing limits.
- AppKit virtual-display probe passes: 1376 × 1032 logical, 2752 × 2064 pixel, 120 Hz, original main display unchanged, virtual display removed.
- Probe diagnosis: nested NSRunLoop did not refresh AppKit display mode state; NSApplication.run does. CGDisplayIsOnline returns -1 for nonexistent display IDs on this macOS, so a Boolean negation falsely reported removal failure. Removal now checks CGGetOnlineDisplayList membership. WindowServer and independent system_profiler confirmed creation/destruction throughout. No physical display mode changed.
- Added focus-only AX monitoring, native UITextView keyboard proxy, committed Unicode text, caret-aware viewport translation and matching pointer coordinates. Remote field contents are not copied/read. Physical keyboard shortcuts remain HID based.
- Toolbar excludes its measured rectangle from desktop hit testing; larger Controls button. Main HUD FPS + received video Mbps, optional RTT/decode/local display details.
- Stable signing identity retained; working host remains untouched until new builds and deployment.

- Physical user A/B: 40 Mbps gives 46–50 FPS scrolling, ~20 FPS during typing. 25 Mbps remains clear but does not improve scrolling. Bandwidth reduction alone does not fix pacing. User asks optional sharpening.
- New UI requirements: persistent Auto keyboard toggle on top bar; remove resolution HUD text. iPad only button should black Mac display while virtual desktop stays active; restore on local keyboard/trackpad activity, disconnect, or quit. Must tag injected input to prevent remote actions restoring Mac. Use session-owned black windows and idle-sleep assertion so app exit cleans them up; do not persist brightness changes or change security settings.
