# Verification — 2026-11-12

> **Note:** this file records the checks made for the first builds on 2026-11-12. It has not been updated since and does not describe the current code. For the current state, see [README.md](README.md).

## Confirmed

- Host CPU: Apple M4 Max (`sysctl -n machdep.cpu.brand_string`).
- Xcode 27.2; Swift 6.4.2. Sources use Swift 5 language mode with targeted concurrency checking.
- `swift test`: **22 tests, 0 failures** after the native-desktop update. Includes Keychain read/update and interaction-setting restoration, real TLS loopback transfer, and failure to authenticate with a different PSK. The latter closes at the explicit ten-second handshake deadline.
- `./scripts/build.sh`: **macOS host and iOS simulator builds succeeded**.
- `xcodebuild … -scheme SkyDeskPad -configuration Release -destination 'generic/platform=iOS' … CODE_SIGNING_ALLOWED=NO build`: **physical iOS target compiled successfully**.
- Initial Mac host was ad-hoc signed. The live-address update is now Apple Development signed using the existing local certificate; `codesign --verify --deep --strict` succeeds, and the designated requirement uses its identifier/certificate rather than a build hash. It is not Developer ID signed or notarized.
- Mac host launched successfully. Final native accessibility and screenshot inspection confirmed readable controls, sharing disabled, and a responsive **Unlock pairing key** state after rebuilding. The existing key remains protected; no Keychain approval was automated.
- iPad app installed and launched in the M5 iPad Pro 13-inch simulator. This proves process launch, not visual rendering or physical-device behavior.
- Subsequently, the signed Release app was installed and launched on the physical M5 iPad over USB. Device app inventory confirms `com.skylar.skydesk.pad`, version 0.1.0 (1). Apple's earlier Program License Agreement block cleared on retry.
- During the Accessibility follow-up, both host permissions were recognized and Start Sharing succeeded after re-adding only SkyDesk's current app to its existing permission list. Native screenshot confirmed Sharing on with remote input enabled; `lsof` confirmed TCP 48772 listening. Loopback and current Wi-Fi IP 10.240.173.132 accepted TCP. These probes do not prove a physical iPad session.
- After the live-address update and signing migration, both permissions were refreshed and recognized. Two established client connections from 10.240.173.127 to 10.240.173.132:48772 and active hardware encoding were observed. The user confirmed **desktop and input work** on the iPad.
- Four focused LAN-address tests pass (primary-interface ordering, disconnect/DHCP updates, filtering, and VPN/no-default-route behavior). Native UI changed from no IP to the correct 10.240.173.132 Wi-Fi address, matching `ipconfig`; Copy address is present. Address refresh runs every two seconds while sharing is on or off. Live physical network-switch behavior was covered by snapshot tests, not a disruptive network change during the user's session.

Final builds have no errors. Expected warnings: Xcode's “Metadata extraction skipped, no AppIntents.framework dependency found”, plus three macOS deprecation warnings for the intentional legacy Keychain interaction guard. Those APIs are necessary for this ad-hoc-signed host's file-based Keychain: the modern per-request LAContext setting did not prevent authorization waits in the observed environment. The process-local setting is serialized and restored after each operation.

## Startup regression resolved

Rebuilding the ad-hoc-signed host changed its Keychain authorization identity. A native relaunch became unresponsive; a one-second process sample traced the main thread to `HostModel.init` → `PairingStore.load` → `SecItemCopyMatching`. Startup Keychain work was moved off the main thread, made noninteractive, and given an explicit asynchronous unlock action. Bounded probes showed both per-query UI flags and LAContext were insufficient for the legacy ACL; process-scoped suppression returned `errSecAuthFailed` immediately. Final relaunch and screenshot verified the usable unlock screen without granting access or replacing the key.

## Hardware media smoke check

Command: `swift run skydesk-check --frames 120`

120 synthetic frames at 2560 × 1600 passed through hardware HEVC encoding, TLS loopback, and hardware HEVC decoding. Both hardware flags were confirmed. Decoded dimensions matched.

Recorded diagnostic sample:

```json
{
  "frames": 120,
  "width": 2560,
  "height": 1600,
  "hardwareEncode": true,
  "hardwareDecode": true,
  "encodeP50MS": 9.324583,
  "encodeP95MS": 9.949375,
  "decodeP50MS": 1.234,
  "decodeP95MS": 1.424416,
  "encodeTransportDecodeP95MS": 12.216417
}
```

These are static-image, single-Mac diagnostic measurements. They exclude ScreenCaptureKit, actual LAN transit, iPad presentation, and input-to-photon time. They are not proof of 120 FPS or the 30 ms target.

## Open acceptance gates

- Physical iPad installation and launch are verified. User confirmed live desktop streaming and input. Exhaustive shortcut/clipboard/gesture acceptance and measured physical-device performance remain open.
- Host Screen Recording and Accessibility are recognized; live capture is active. Existing pairing key is unlocked and unchanged. Build script now honors the stable Apple Development identity in Local.xcconfig.
- User reported 5–30 FPS mostly on a still desktop, and RTT usually about 15 ms with spikes near 80 ms. The FPS counter measures unique presented frames; these observations do not establish sustained-motion throughput or end-to-end latency.
- Native simulator GUI is absent from the installed Xcode path; iPad layout, actual Metal presentation, and touch/trackpad interaction were not visually verified.
- No LAN motion soak, thermal/power run, capture-to-display calibration, or high-speed-camera latency measurement.
- Audio, HDR, headless/closed-lid operation, WAN traversal, and automatic clipboard synchronization are not implemented. Virtual desktop and software keyboard are now implemented; see the update evidence below.

Follow the physical acceptance pass in README.md before claiming either performance target.

## Native desktop update — build 2

- Release iPad build 2 installed over USB and launched. Device inventory verified version 0.1.0 (2). User confirmed the separate desktop appears.
- Updated signed host replaced the app at its existing path after archiving `Verification/SkyDesk-Host-before-native-desktop.zip`. Its certificate-based designated requirement is unchanged. Both permissions and the existing pairing key were recognized without another prompt. Sharing is on.
- Live host screenshot confirms `iPad Retina desktop · 2752 × 2064 · 120 FPS target`. A single observed interval showed 66 captured / 45 encoded FPS, 10.3 ms encode, 62.0 ms capture-to-decode feedback, and an adaptive limit of five frames. This is not a controlled scrolling benchmark or proof of 120 FPS.
- `Tools/VirtualDisplayCheck.m` passed actual AppKit/WindowServer creation, 1376 × 1032 logical / 2752 × 2064 pixel / 120 Hz mode, preserved main display, and removal. Original probe used a nested run loop and incorrectly treated `CGDisplayIsOnline == -1` as still online; corrected to the host event loop and online-list membership.
- Deterministic pacing regression: 120 Hz source + 32 ms feedback accepted 60 FPS with fixed two-frame window; bounded adaptive window accepts 119 FPS in the same simulation. Congestion/backlog limits also pass. This isolates a pacing bottleneck; it does not measure Wi-Fi or iPad throughput.
- Native-resolution HEVC/TLS loopback: 60/60 frames, hardware encode/decode confirmed, encode p95 9.19 ms, decode p95 1.66 ms, combined p95 10.75 ms. Static synthetic pixels on one Mac only. `Verification/native-media-check.json`.
- Both final signed app builds succeeded; signature verification passed. Expected legacy Keychain and AppIntents warnings only.
- Automatic keyboard, committed Unicode text, caret visibility, hit exclusion for toolbar, FPS/video bitrate HUD and optional timing details are installed. User acceptance of these interactions and sustained scrolling is pending.

## Controls update — build 3

- Signed host and Release iPad builds passed. 24 core tests pass, including display-control compatibility and remote event-tag preservation with untagged local events. Signatures verified.
- Build 3 installed and launched on physical iPad; device app inventory confirms 0.1.0 (3). Host updated in place, both permissions/key retained, sharing on at 25 Mbps.
- Persistent Auto keyboard toggle, resolution HUD line removal, optional mild luminance sharpening, custom toolbar status indicators and connected-session system status bar hiding are installed.
- iPad-only black windows preserve capture display, keep session awake, and restore on local key/trackpad events or disconnect. No persistent brightness changes; host process exit removes windows and power assertion. Physical blanking/local activity/remote input acceptance pending.
- User reports 25 Mbps remains clear but does not improve scrolling. A later host relaunch showed 40 Mbps again, so the first A/B is user-reported rather than continuously verified. Build 3 defaults to 25 Mbps, confirmed in live UI. Sustained 120 FPS remains unproven.

## True iPad-only correction — build 4

- User confirmed the custom toolbar/status indicators are correct. User rejected build 3 blackout windows because the iPad remained secondary; build 4 replaces those windows with a real display-configuration transaction.
- Actual M4 Max check: before = main display 1 plus virtual 18; exclusive = online displays [18], main 18; after = original layout restored. Separate helper-only recovery check also passed with virtual 19. Final independent system_profiler shows only Color LCD, main 1. Both check/recovery processes exited.
- User asked why screen kept going black. Explained these were our timed tests and committed to no more agent-triggered blackouts; further switching is through the user's iPad button.
- Added runtime SLSConfigureDisplayEnabled, original enabled-ID/origin snapshot, temporary application-scope disable, explicit restore, and a separate signed helper armed before any change. Helper observes pipe EOF / six-second heartbeat timeout and verifies/restores independently. Display/keyboard focus input geometry refreshes on topology changes.
- 24 core tests pass; final host and physical iPad builds pass. Physical iPad-only button behavior and local input restoration still need user validation after installation.
