# SkyDesk implementation plan

## Goal
Build a native macOS host and iPad client for Apple Silicon remote desktop: hardware HEVC, a 120 Hz presentation path, bounded latency, and native input. Under 30 ms and sustained 120 FPS require physical-device measurements, not build success.

## Active follow-up: native iPad desktop and interaction
1. [complete] Reproduce the scrolling throughput limit, inspect scaling and input routing, and establish regression checks. User now reports 12–30 FPS during scrolling, not merely idle frames.
2. [complete] Create a session-owned HiDPI virtual desktop using the authenticated iPad's actual pixel dimensions. User explicitly chose a separate iPad-sized desktop rather than mirroring.
3. [complete] Correct bounded pipeline pacing based on measured/simulated feedback delay; preserve low-latency bounds and HEVC dependencies.
4. [complete] Fix toolbar hit testing, add a larger menu handle, and show FPS plus actual bitrate with timing details optional.
5. [complete] Add automatic Apple software keyboard when a remote editable field gains focus, forward committed text, and keep the focused field above the keyboard with consistent pointer mapping.
6. [in progress] Build/sign both apps using the stable identity, install the iPad update, run focused tests and media checks, then verify a live session. Keep the existing session running until replacement builds are ready.

## Latest follow-up
1. [in progress] Add persistent Auto keyboard toggle, remove resolution HUD line, and optional mild output sharpening.
2. [pending] Add iPad only button: black Mac displays, keep stream awake, restore on local keyboard/trackpad activity or session end, ignore tagged remote input.
3. [pending] Diagnose remaining scrolling limit. User measured 46–50 FPS at 40 Mbps; 25 Mbps remains clear but does not improve scrolling.
4. [pending] Build/install updated apps and verify controls, local restoration, and performance on device.

## Phases
1. [complete] Confirm SDK APIs and establish a native project.
2. [complete] Implement authenticated transport, protocol, and meaningful tests.
3. [complete] Implement display capture, hardware encoding, input, and host controls.
4. [complete] Implement hardware decoding, Metal presentation, discovery, input, and client controls.
5. [complete] Build both apps, run protocol/transport/media checks, document setup and hardware acceptance gates.

## Current follow-up: show current Mac address
1. [complete] Confirm host pairing UI has no address and inspect current interfaces. Sharing is currently off; both permissions are recognized. Current Wi-Fi address is 10.240.173.132.
2. [complete] Add live LAN address detection, readable interface labels, and per-address copy actions. Exclude loopback, tunnels, inactive links, and self-assigned addresses; clear stale addresses on disconnect.
3. [complete] Run focused address-selection checks, build and reopen the updated Mac host, and verify its displayed address against macOS. Existing key retained; permissions refreshed for the stable signed build; user confirmed desktop and input work.

### Rebuild recovery
- Four address tests pass and the first updated build visibly shows the current Wi-Fi IP. Its new ad-hoc hash invalidated existing permission/keychain recognition, reproducing the previous build-identity problem.
- Use the already-installed Apple Development identity and local team configuration for a stable designated requirement. Remove the script's forced ad-hoc override and the project setting that masked Local.xcconfig. Then refresh the same app's existing grants once; preserve the existing pairing key.
- Recovery complete: current app uses the certificate-based requirement, both permissions are recognized, and the existing key is unlocked. Two active connections to 10.240.173.127 were verified; user confirmed desktop and input work. Keep the live session running.

## Handoff
- Local implementation and available verification are complete. See README.md and VERIFICATION.md.
- Physical iPad installation and launch are complete. Host permissions are recognized and sharing is on. User confirmed desktop and input work. Sustained-motion FPS and measured end-to-end latency remain open gates; do not describe this prototype as proven sub-30 ms or sustained 120 FPS.
- Apple's agreement block cleared on retry. The Release app was signed with team [REDACTED_SIGNING_TEAM], installed on the physical M5 iPad, verified in its app inventory as version 0.1.0 (1), and launched successfully.

## Decisions
- New, empty workspace; no existing files or Git history to preserve.
- Swift, SwiftUI/AppKit/UIKit, ScreenCaptureKit, VideoToolbox, Metal, Network.framework. XcodeGen supplies reproducible projects.
- Encrypted TLS-PSK connections with a random 256-bit pairing key, separate video and control streams, one active client, explicit host start/stop.
- Bound the video pipeline before encoding. Never discard arbitrary encoded interframes; congestion requests a new keyframe.
- Default to a session-owned Retina virtual display matching the authenticated iPad. Keep public-API physical-display mirroring as a fallback. Virtual displays use a private CoreGraphics API; audio, WAN traversal, and unattended startup remain outside scope.

## Verification
- Protocol fragmentation, limits, hostile input, coordinate mapping, and frame gating tests.
- Positive and wrong-key TLS loopback checks.
- Synthetic hardware HEVC encode/decode round trip without capturing the user's display or injecting input.
- macOS and iPad simulator/device-target builds; physical device and permission gates reported separately.

## Observations / errors
- Accessibility follow-up resolved: Settings showed SkyDesk enabled while the host rejected Start Sharing. Restart and off/on toggle did not help. Removing only SkyDesk's existing entry, then adding the exact current app restored the grant; host now shows both permissions granted and Sharing on with input enabled. Ad-hoc signing is a plausible contributor, not a verified TCC record.
- Network changed during follow-up: en7 disappeared, default route moved to en0, current IP is 10.240.173.132. Port 48772 listens; loopback and current-IP TCP probes pass. Old 10.62.101.30 times out. Physical iPad reconnect remains unverified.
- `git status` reports `fatal: not a git repository`; workspace is empty. Initialize only if useful later.
- Device discovery stalled in Apple's `devicectl` wrapper while it automatically ran Xcode first-launch device-support installation. It completed successfully; physical iPad is listed as unavailable. Do not retry device discovery during builds.
- First Swift build found the SDK spelling `VTDecodeFrameFlags._EnableAsynchronousDecompression`; corrected. Six protocol tests then passed.
- iOS simulator Metal headers omit `addPresentedHandler`; simulator-only GPU-completion timing is explicitly labeled. Physical builds use actual presentation callbacks.
- Wrong-key test initially allowed 8 seconds, shorter than the channel's 10-second deadline. The test now permits 12 seconds and verifies neither endpoint reaches ready.
- Mac UI inspected through native computer use. Help text truncation corrected. Simulator app process launches, but no Simulator GUI application is installed at Xcode's expected path; no visual iPad claim.
- Relaunch after ad-hoc rebuilding hung in `HostModel.init` -> `PairingStore.load` -> `SecItemCopyMatching`, confirmed by a one-second process sample. Keychain authorization was blocking the main thread. Startup now performs noninteractive Keychain access on a worker and exposes an explicit asynchronous unlock button. Original key remains intact; no Keychain approval was automated.
- Both LAContext and the deprecated per-query UI-fail flag were insufficient for the legacy macOS Keychain ACL. A bounded probe using process-local `SecKeychainSetUserInteractionAllowed(false)` returned `errSecAuthFailed` immediately. PairingStore now serializes this scoped change and restores the previous setting, retaining normal approval for explicit Unlock. Intentional legacy-API deprecation warnings are documented.
