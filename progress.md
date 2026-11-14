# Progress

## 2026-11-12
- Inspected empty workspace and installed Apple build tools.
- Established scope, verification plan, and primary API references.
- No live display capture, remote input, or system settings changed.
- Implemented shared framing, TLS-PSK transport, Keychain pairing, bounded capture window, HEVC encoder/decoder, host app, and iPad app.
- Six protocol tests passed. macOS and simulator builds are running; TLS tests and synthetic media check are next.
- The device-discovery tool automatically updated Xcode device support before returning. This was Apple's wrapper behavior, not a manual system configuration change. Physical iPad unavailable; no device installation attempted.
- Final suite: ten tests passed. macOS, simulator, and physical iOS target builds passed. Host ad-hoc signature verified.
- 120 synthetic frames at 2560×1600 passed encrypted loopback with hardware encode and decode. Evidence and limitations recorded in VERIFICATION.md.
- Host native UI launched with sharing off and permissions ungranted. Key remained hidden. Simulator app installed and launched; simulator GUI absent.
- Fixed simulator-only presentation API availability, explicit modifier release for toolbar shortcuts, interruption handling, and idle-to-motion stall detection.
- README and executable build script provide build, pairing, operation, architecture, security limitations, and physical acceptance steps.
- Rebuilt host initially blocked at startup on legacy Keychain authorization. Process samples and bounded probes isolated the issue; asynchronous, serialized, explicitly noninteractive startup access now presents an Unlock button. Final native UI/screenshot verified the recovered state. Existing key preserved; sharing off; no permission approvals automated.
- Final iPad build installed and launched in the simulator; the test simulator was shut down afterward. Mac host remains open with sharing disabled.

## Physical iPad installation attempt
- Physical M5 iPad is now connected over USB, paired, and has Developer Mode enabled.
- A valid Apple Development identity and team [REDACTED_SIGNING_TEAM] are available.
- Signed device build with automatic provisioning failed: `Unable to process request - PLA Update available`. Apple requires acceptance of the updated Program License Agreement before the account can register/provision this iPad.
- Inspected all five local provisioning profiles; none includes this iPad. No compatible offline provisioning path exists among those profiles.
- App is not installed on the physical iPad. Awaiting the user's agreement acceptance in the Apple Developer account, then retry signed build, install, and verify launch.

## Physical iPad installation completed
- On the user's retry request, Apple's agreement/provisioning block cleared. The signed Release device build succeeded with team [REDACTED_SIGNING_TEAM].
- `devicectl device install app` successfully installed `com.skylar.skydesk.pad` on the physical M5 iPad.
- Device app inventory confirms SkyDesk 0.1.0, build 1. `devicectl device process launch` succeeded.
- Installation and launch are verified; live host pairing, streaming, input, and performance were not tested in this installation step.

## Accessibility recognition repaired
- Reproduced Start Sharing failure with Settings showing SkyDesk enabled while `AXIsProcessTrusted()` returned false; no TCP listener existed.
- Restart and permission off/on did not help. Removed only SkyDesk's existing entry and added the exact running app through System Settings. All other app grants remained unchanged.
- Start Sharing now succeeds; screenshot confirms Screen Recording and Accessibility checkmarks, remote input enabled, 2560 cap, 120 FPS target, and restored 80 Mbps bitrate. Existing pairing key preserved.
- Verified TCP listener on port 48772 and successful connections via loopback and current Wi-Fi IP 10.240.173.132. Ethernet en7 disappeared during follow-up, so the earlier 10.62.101.30 address is stale. Asked user to reconnect iPad using the current address.
- Physical session, input, and performance acceptance remain open. No source rebuild or additional unit test run was needed for this permission-entry repair.

## Live address follow-up
- Added native live LAN IPv4 enumeration, interface labels, per-address copy controls, and a two-second refresh that also runs while sharing is off. Addresses disappear when their interface disconnects.
- Four focused address tests passed. Host built and launched; displayed Wi-Fi address matches macOS at 10.240.173.132.
- Ad-hoc rebuild reproduced the old permission identity problem. Configured the existing Apple Development certificate locally, removed build/project overrides that forced ad-hoc signing or masked the local team, rebuilt, and verified the certificate-based designated requirement.
- Preserved previous builds and source snapshot. Existing pairing key unlocked without replacement. macOS approval and the permission refresh after signing migration completed; both permissions are recognized.
- Verified current IP in native UI, Copy address availability, active sharing, and two established client connections to port 48772. User confirmed desktop and input work. Session remains running at the selected 40 Mbps; did not interrupt it to change settings.
- User's 5–30 FPS report was clarified as mostly idle-desktop behavior. Explained that the counter counts unique new frames rather than panel refreshes. No performance code changes without a motion-based failure signal. User-reported RTT is usually about 15 ms, with spikes near 80 ms; end-to-end latency and sustained motion throughput are unmeasured.

## Native desktop update
- Source implementation and 22 core tests complete; virtual-display lifecycle check passed after correcting the diagnostic event loop and removed-ID handling.
- iPad Retina 2752×2064 at 120 Hz verified locally. Hardware HEVC smoke and final signed builds next, then device installation and live keyboard/menu/performance verification.
- Simulation improvement is not proof of sustained physical-device FPS or latency.

- Build 2 installed and launched on physical M5 iPad over USB; app inventory confirms 0.1.0 (2). Updated Mac app installed at the existing path, signed requirement unchanged. Both permissions/key retained without prompts.
- User confirmed separate desktop appears. Native host screenshot shows 2752×2064 and 120 FPS target; one live interval 66 capture / 45 encoded FPS, encode 10.3 ms, feedback 62.0 ms, window limit 5. Two established TLS channels verified.
- Asked user to test scrolling FPS, auto keyboard/caret visibility, and larger Controls hit target. Waiting on physical interaction acceptance.

## Controls follow-up — build 3
- Added persistent Auto keyboard toggle, removed resolution HUD line, added optional mild luminance sharpening.
- Added session-owned Mac black windows and idle-display-sleep assertion. iPad-only request/ack capability is available only with separate desktop and remote input. On disconnect/quit/permission loss, restore; physical event monitors restore on local key/trackpad input, tagged remote events ignored. Black windows and assertion belong to process, so crash/exit removes them without persistent brightness changes.
- Stream hides system status bar and moves time/date, battery/charging and Wi-Fi/network connection indicator into the adaptive toolbar. Wi-Fi symbol indicates connection type, not measured signal strength.
- Both signed app builds passed. Initial event test incorrectly tried to clear CGEvent user data after copying, which macOS ignores; bounded probe confirmed fresh physical-source events remain untagged. Test now exercises actual source isolation and copy preservation.
- Need device installation and physical validation of new UI/blanking/local activity restore. Performance A/B: 25 Mbps equally clear, not smoother than 46–50 FPS at 40 Mbps.

## User correction: true iPad-only desktop
- User confirmed custom toolbar/status indicators and hidden system status/resolution HUD work.
- User rejects black-window implementation: Mac content/display remains and iPad stays secondary. Must make iPad main/only active display, disabling built-in panel, and restore original display layout on local keyboard/trackpad/disconnect. Existing black-overlay implementation is installed build 3 but does not satisfy this clarified behavior.
- Research: runtime SkyLight exports SLSConfigureDisplayEnabled; displayplacer primary header confirms CGError(CGDisplayConfigRef, CGDirectDisplayID, bool). Need runtime loader, snapshot original enabled IDs/origins/main, application-scoped disable, automatic restoration with independent helper before hardware test. Do not use mirroring of virtual display (reported WindowServer crash path).
- Physical iPad Time Profiler could not attach by confirmed PID 1312 or by name despite devicectl showing it and get-task-allow=true; do not keep retrying Instruments. Host sample file exists.

- True exclusive display checks passed: only virtual/main ID18, original layout restored; helper-only recovery passed with ID19. Mac restored to built-in main1, no lingering test/helper processes. User noticed tests blacking screen: acknowledged responsibility, promised no more agent-triggered blackouts.
- Build4 implements actual disable/main switch, bundled signed restore helper, per-session snapshots, heartbeat/EOF fallback, local input restoration, updated input/focus coordinates. Both apps compile, 24 tests pass. Minor helper concurrency annotation rebuild running. Install next; leave switching to user.

## Parallel Fable handoff
- User says iPad-only stays on Restore Mac, but existing app/browser windows do not migrate to iPad. Window transfer is the remaining functional gap; no migration code written yet.
- User explicitly requests two Fable threads: window/display issue and compression/performance + FPS1% lows + latency2s averages/1% highs. Latency must include BOTH RTT and local display separately (user confirmed).
- Detailed shared handoff: Verification/FABLE_HANDOFF.md. Root stops source edits once threads start; preserve no-more-agent-blackouts boundary.
