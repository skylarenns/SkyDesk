# SkyDesk

A native Apple remote desktop for one person's own devices. **SkyDesk Host** runs in the Mac's menu bar, captures a display and streams it as hardware-encoded HEVC. **SkyDesk** on the iPad decodes it in hardware, draws it with Metal and sends back keyboard, trackpad, touch and gesture input. The same link carries clipboard text, files in both directions, the Mac's sound, and updates of both apps. The two devices talk to each other directly: there is no account, relay or server.

This file describes the code at **build 40** (`CURRENT_PROJECT_VERSION` in `project.yml`). [VERIFICATION.md](VERIFICATION.md) is the dated record of the first builds and does not describe the current state.

**No end-to-end performance figure has been measured.** 120 FPS is the default target frame rate, not a verified result. The delays the iPad shows are estimates added up from parts (see [Statistics](#statistics)); nobody has yet filmed an input and its response to check them.

## Status

| Builds | State |
| --- | --- |
| 31 to 35 | Installed and used on the real Mac and iPad. |
| 36 and 37 | Installed on 2026-11-13. Build 37's log shows the forward-secret exchange in use and the iPad issued its own key. The 4:4:4 option has not been switched on yet. |
| 38 (video over encrypted UDP, the "Late" figure, host settings saved) | Installed on 2026-11-13. **Video over UDP failed on the real devices**: the UDP flow came up 36 ms after connecting, but the session's first frame (about 200 kB on a quiet desktop) was sent over UDP, the iPad was waiting for it on TCP, nothing was shown for 1.5 s, and the fallback then carried the session on TCP. No frame has yet been displayed from UDP on the real devices. |
| 39 (first frame always over TCP, the iPad reports a stream that started on the wrong path within half a second, faster encoder mode) | Installed and used on 2026-11-14. Video stayed on UDP for a 62-minute session on home Wi-Fi (Late: average 2.3 ms, 1% high 12.2 ms). The Mac's sound was heard on the iPad and the log shows the Mac's speakers silenced. Encoding took 13.9 ms at 10 to 29 frames a second against 17.0 ms in build 38, and click-to-screen 37.3 ms against 41.1. A session through WireGuard worked (46 ms round trip, video on UDP), but the Mac re-sent a piece of every frame after a fixed 35 ms without an acknowledgement, counted those as loss, and cut the bitrate to its 1.5 Mbps floor within a minute. |
| 40 (the Mac learns how long acknowledgements take; its own probes no longer count as loss) | Built and unit-tested. Not yet run on the real devices. |

Not yet confirmed on real hardware, even in the installed builds:

- that the Mac's speakers really are silent while the iPad plays its sound (the log says the Mac asked for that; nobody has yet confirmed it by ear);
- pinch and rotate actually reaching Mac apps (a unit test shows AppKit reads the injected events as magnify and rotate events, nothing more).

`swift test` runs 152 tests with no failures (last run 2026-11-14 on the build 40 sources). Tests use the Mac's hardware encoder and loopback connections; they never capture the screen.

## Requirements

- An Apple Silicon Mac on macOS 14 or later. Hardware HEVC encoding is required; there is no software fallback. Sound needs macOS 14.2. Wireless updates need macOS 15.
- An iPad on iPadOS 17 or later, with hardware HEVC decoding.
- Xcode with the iOS SDK, and XcodeGen (`brew install xcodegen`). No third-party packages.
- Network: the iPad must reach the Mac on TCP **48772**. Video also uses UDP **48772** when it gets through (build 38); if it does not, everything stays on TCP. Updates are served on TCP **48773** for a few minutes at a time.

## Build and first install

```sh
./scripts/build.sh
```

The script creates a placeholder `Local.xcconfig` if there is none, regenerates `SkyDesk.xcodeproj` from `project.yml`, builds the signed Mac app into `build/Build/Products/Debug/SkyDesk Host.app`, and compiles the iPad app for the simulator without signing (a compile check, not something you can install).

**Signing.** Put your own values in `Local.xcconfig` (it is listed in `.gitignore`):

```
DEVELOPMENT_TEAM = YOUR_TEAM_ID
CODE_SIGN_IDENTITY[sdk=macosx*] = Apple Development
```

A stable development identity matters for the Mac app: macOS ties the Screen Recording and Accessibility grants and the Keychain items to the app's signature, and the Mac app only updates itself to a build with the same signing requirement. An ad-hoc build has a new identity every time it is rebuilt.

**Mac.** Copy `SkyDesk Host.app` to `/Applications` and open it. "Open at login" only works from there. The app has no Dock icon unless its window is open; look for the iPad icon in the menu bar.

**iPad, first time.** Open `SkyDesk.xcodeproj`, select the **SkyDeskPad** scheme, your team and your iPad, and Run. Or build a signed device app from the command line and install it with Xcode:

```sh
xcodebuild -project SkyDesk.xcodeproj -scheme SkyDeskPad -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath build-device \
  -allowProvisioningUpdates build
```

After that first cable install, both apps can be updated over Wi-Fi (see [Updates](#updates)).

**Permissions on the Mac.** The host window shows what is missing:

- **Screen Recording**: required. Without it a session is refused and the iPad is told why.
- **Accessibility**: required while "Allow keyboard, trackpad and touch input" is on. It is also what moves windows in iPad only mode and finds text fields for the iPad keyboard.
- **System audio recording**: macOS asks once, the first time sound is captured.
- **Keychain**: if macOS will not hand over the pairing password without asking, the host shows "Password locked" and an **Unlock…** button, and stays responsive while you answer.

If System Settings shows Accessibility enabled but SkyDesk still reports it missing, quit and reopen the host. If that does not help, remove only SkyDesk Host from the Accessibility list and add the exact app you are running. This fixed the one observed case, after an ad-hoc development build (recorded in VERIFICATION.md).

## Pair and connect

1. On the Mac, open the host window (menu bar icon › **Open SkyDesk…**). It shows the Mac's **address** and a **password**. The first launch generates the password: eight characters shown as `xxxx-xxxx`.
2. On the iPad, open SkyDesk and allow local network access. Tap the Mac under **Nearby**, or type its address under **Add a Mac**. Type the password and tap **Connect**. Dashes and spaces in the password do not matter; capital letters do.
3. That is the only time you type anything. The iPad remembers the Mac and connects by itself from then on.

What happens around that:

- **Addresses.** The Mac lists its active Wi-Fi and Ethernet IPv4 addresses, refreshed every two seconds, and after them any VPN tunnel address, labelled **VPN**. The address field on the iPad also takes a `.local` name and an optional `:port`.
- **Recent Macs.** The iPad keeps the five most recent addresses. Tap one to connect; touch and hold for **Forget this Mac**.
- **Auto-connect.** On launch, and whenever the app comes back to the front with nothing connected, the iPad tries the most recent Mac for 5 seconds (25 seconds on the first launch after an update, because the Mac is usually restarting into its own update). Then it shows the connection screen.
- **Several addresses for one Mac** (home Wi-Fi and a VPN address, say): the iPad opens a plain TCP connection to each remembered address, sending nothing, and uses the newest one that answers.
- **Away from home.** There is no relay. Put the iPad and the Mac on the same VPN and type the Mac's VPN address once. The toolbar then shows a shield icon instead of Wi-Fi. This path has not been confirmed end to end.
- **USB cable.** With "Use USB cable when plugged in" on, connecting by tapping a Mac under **Nearby** first tries a route that is not Wi-Fi or cellular, and falls back to the normal route if there is none.
- **Its own key (build 37).** The first time a build 37 iPad connects with the password to a build 37 Mac, the Mac issues that iPad a random key of its own and lists the iPad under **Paired iPads**. The iPad uses that key from its next connection on. See [Pairing and security](#pairing-and-security).
- **Lost connection.** If the link goes quiet for five seconds while SkyDesk is on screen, the iPad ends the session and tries to reconnect for a few seconds before showing the connection screen.
- **Background.** When SkyDesk leaves the screen, everything held down is released on the Mac, video and sound pause, and the link is kept for the roughly 30 seconds iPadOS allows. Coming back within that time resumes with a fresh keyframe; later, the iPad reconnects.

Only one iPad can be connected at a time.

## SkyDesk Host on the Mac

**Menu bar.** The icon's menu shows the state, one action that fits it (**Turn On Sharing**, **Turn Off Sharing**, **Disconnect iPad** or **Unlock…**), **Open SkyDesk…**, **Open at Login** and **Quit SkyDesk**. Closing the window leaves the host running. A launch at login opens no window unless something needs you (a locked Keychain or a missing permission). The first run from `/Applications` switches "Open SkyDesk when I log in" on once; if you switch it off, it stays off.

**When the port is open.** The host listens whenever it is running, the Mac is awake, the pairing password has been read from the Keychain, and either sharing is on or "Turn on automatically when my iPad connects" is on. That switch is on by default, so by default a paired iPad can start a session at any time, and **Turn Off Sharing** or **Disconnect iPad** ends the session but does not keep the iPad out. To keep it out, switch that option off or quit the host. The port closes when the Mac sleeps and reopens when it wakes.

**Window.**

| Card | What it holds |
| --- | --- |
| Status | State, the main button, "Turn on automatically when my iPad connects", "Open SkyDesk when I log in", and live capture figures while connected. |
| Update ready | Appears when a newer Mac build is staged. **Update Mac Now**. |
| Files | Appears while connected. **Send Files…**, recent transfers. Dropping files anywhere on the window sends them. |
| Pairing | Addresses, the password (hide, copy, **Change…**). |
| Paired iPads | Each iPad with its own key, when it last connected, **Remove**, and "Let new iPads pair with the password". |
| Display & quality | The settings below. Locked while an iPad is connected. |

**Display & quality.**

| Setting | Default | Notes |
| --- | --- | --- |
| Desktop | Separate iPad desktop | A virtual 2× Retina display the size of the iPad's screen, or **Mirror a Mac display** (then pick the display and a resolution cap of 1920, 2560 or native up to 4096; never upscaled). |
| Frame rate | 120 | 30, 60 or 120; lowered to what the iPad's screen can show. |
| Bitrate | 25 Mbps | 15, 25, 40, 60 or 80. With the next setting on, this is the upper limit. |
| Lower the bitrate when the network is slow | On | See [Video](#video). |
| Allow keyboard, trackpad and touch input | On | Off gives a view-only session. |
| Sync clipboard text with the iPad automatically | On | |
| Allow file transfers | On | Incoming files go to Downloads. |
| Play this Mac's sound on the iPad | On | |
| Encode faster | On | Build 39. The encoder's fastest mode. Measured on the Mac alone at 2752 × 2064: with frames 62 ms apart (ordinary desktop use) 11.5 ms per frame instead of 16.8, and frames about twice the size; with frames 17 ms apart, no difference. Not yet measured in a real session. |
| Low-latency rate control (experimental) | Off | A VideoToolbox encoder mode. Its effect depends on resolution and hardware; this file claims none. |
| Keep this Mac awake while SkyDesk is ready | Off | Stops the Mac sleeping on its own while the port is open. It does not keep a closed MacBook awake. |

All of these are saved between launches (the first seven only since build 38; before that they returned to the defaults whenever the host restarted). Stream settings apply from the next connection; "Keep this Mac awake" applies at once.

**AirDrop link.** While an iPad is connected the host tries to switch off the Mac's AirDrop/Continuity radio link (`awdl0`), because with it up the Wi-Fi radio leaves its channel about twice a second (one measurement, 2026-11-12: worst ping 97 ms with it up, 12 ms with it down). It checks four times a second because macOS switches the link back on. This only happens if the user may run `/sbin/ifconfig awdl0 down` and `up` through `sudo` without a password; the project does not install that rule. One that fits, added with `sudo visudo -f /etc/sudoers.d/skydesk-awdl`:

```
YOUR_USER ALL=(root) NOPASSWD: /sbin/ifconfig awdl0 down, /sbin/ifconfig awdl0 up
```

With the rule in place, AirDrop, AirPlay, Sidecar and Universal Control are unavailable on the Mac during a session; the link is switched back on when it ends. Without the rule nothing changes.

## SkyDesk on the iPad

The app is landscape only and full screen. The desktop's size is fixed when the session starts.

### Toolbar

A floating bar at the top: drag it to move it, double-tap to put it back, and use the chevron to collapse it. Touches on the bar never reach the Mac. It shows the time, date, link type (Wi-Fi, cable or VPN; not signal strength) and battery, and then:

- **Update**: appears when the Mac has a newer iPad build staged.
- **Keyboard**: shows or hides the iPad's on-screen keyboard.
- **Shortcuts**: Show Dock here, Escape, Tab, ⌘Tab, Spotlight, Copy, Paste, Undo, a **Desktops** submenu (Mission Control, this app's windows, next and previous desktop) and **Release all keys**. iPadOS keeps some hardware shortcuts for itself; use this menu for those.
- **iPad only** / **Restore Mac**: see [iPad only mode](#ipad-only-mode). Shown with a separate desktop and input allowed.
- **More**: Send files to Mac…, clipboard sync, Show statistics, and **Settings**.
- **Disconnect**: ends the session. The iPad does not reconnect until SkyDesk is next brought back to the front.

### Input

| On the iPad | On the Mac |
| --- | --- |
| Hardware keyboard | Keys by physical position, so the Mac's own keyboard layout applies. Modifiers, Caps Lock, function and navigation keys, key repeat. |
| Trackpad or mouse | Pointer, click, drag, secondary click, smooth scrolling. |
| Tap, one-finger drag | Click, drag. |
| Two-finger tap | Secondary click. |
| Two-finger drag | Scroll. After the fingers lift, the Mac generates the glide itself so the network cannot make it uneven. |
| Pinch, rotate (screen or trackpad) | Replayed as Mac trackpad magnify and rotate gestures at the pointer. |
| Three-finger swipe on the screen | Up: Mission Control. Down: the app's windows. Left and right: next and previous desktop. |
| On-screen keyboard | Committed text is typed into the Mac. |

Notes:

- Three-finger swipes are sent as Control-arrow key presses, so they follow the Mac's keyboard shortcut settings. Three-finger swipes on the **trackpad** are not possible: iPadOS keeps them and no app receives them.
- Pinch and rotate use gesture event fields that are not in Apple's public headers.
- A secondary-button **drag** is not sent.
- The pointer is drawn by the iPad itself ("iPad pointer (no delay)"), using the image the Mac reports, so it moves without waiting for the video. The Mac leaves its own pointer out of the video meanwhile.
- With "Show keyboard for text fields" on, tapping a Mac text field opens the iPad keyboard and the desktop slides up to keep the caret visible, when macOS Accessibility exposes the field. Password fields switch the keyboard to secure entry. SkyDesk reads only the focused field's type and position, never its contents. Text being composed stays on the iPad until it is committed, and autocorrection is off.
- If iPadOS swallows a modifier's key-up (holding ⌘, ⌘Tab), the next pointer event corrects the Mac's idea of which modifiers are down.
- **Show Dock here** pushes the pointer against the bottom edge, which is how macOS decides which screen gets the Dock.

### Settings (More › Settings)

| Setting | Default | Notes |
| --- | --- | --- |
| Start in iPad only mode | On | Switches the Mac's own displays off about a second after connecting. |
| Play Mac sound on iPad | On | Can be switched during a session. |
| iPad pointer (no delay) | On | |
| Pointer size | Medium (Mac size) | Small, Medium, Large, Extra large. |
| Show keyboard for text fields | On | |
| Detailed statistics | Off | Not saved between launches. |
| Sharpen text | On | Mild sharpening when drawing. |
| Sharper colour (4:4:4, more data) | Off | Build 36, not yet run on real devices. Applies from the next connection. See [Video](#video). |
| Show frames sooner (less delay) | Off since build 38 | Measured on the real iPad in build 36: no benefit (see [Video](#video)). |
| Video over UDP (faster recovery) | On | Build 38, not yet run on real devices. Applies from the next connection. See [Connections](#connections). |
| Use USB cable when plugged in | Off | |

### Statistics

"Show statistics" puts a box under the toolbar:

- **FPS**: new frames that reached the screen in the last second. A still desktop correctly shows few or none.
- **1% low**: from the slowest 1% of gaps between frames over ten seconds. Pauses where the Mac's screen was not changing are left out; every delivery hitch counts.
- **Mbps**: video actually received.
- **Network RTT**: a ping on the control connection, 20 times a second.
- **Picture delay**: Mac capture-to-encoded time + half the round trip + iPad receive-to-screen time.
- **Click to screen**: the same with the whole round trip, for your input travelling to the Mac first.

Averages cover two seconds; "1% high" is the 99th percentile of ten seconds and stays blank until there are 100 samples. "Detailed statistics" adds frames arrived, decode time, the iPad's own display time, and **Late** (build 38).

**Late** is how much later a frame appeared than its spacing on the Mac: if the Mac captured two frames 25 ms apart and they appear 60 ms apart, the second was 35 ms late. Only differences between capture times are used, so the two devices' clocks never need to agree. This is the figure that shows delivery stutter. The **1% low** cannot: a screen that simply changed every 90 ms reads as 11 FPS there although nothing was delayed, and because gaps of 100 ms or more are treated as "the screen was idle" and left out, its value tends to sit just under that cut-off whenever the screen updates irregularly (on 2026-11-13 the most common values after 30 FPS were 10.9 and 12.0 FPS, gaps of exactly 11 and 10 screen refreshes).

Picture delay and Click to screen are **estimates**. They start when ScreenCaptureKit hands the Mac a frame, they assume the network takes the same time in each direction, and they leave out the Mac app's reaction time and the iPad's input sampling. No clocks are compared between the devices.

A small readout in the bottom-right corner is always shown: received bitrate, the click-to-screen estimate and the build number.

## Clipboard, files and sound

**Clipboard.** Text copied on one device is ready to paste on the other, automatically, when the Mac's setting and the iPad's "Sync clipboard with Mac" are both on. Text only, up to 32 KiB of UTF-8; no images or files. The Mac checks its clipboard twice a second. The iPad checks its own only right after connecting and when SkyDesk comes back to the front, so iPadOS shows its paste notice at most once per new copy. When the Mac is not syncing, the More menu has **Send iPad clipboard to Mac** and **Get Mac clipboard** instead, limited to 8 KiB.

**Files.**

- iPad to Mac: **More › Send files to Mac…**, drag files onto the desktop from another app, or "Open in SkyDesk" from the share sheet or Files. Files shared while no Mac is connected are sent as soon as one is. They arrive in the Mac's **Downloads**.
- Mac to iPad: drop files on the host window or use **Send Files…**. They arrive in **Files › On My iPad › SkyDesk**.
- Limits: files only, no folders; 4 GB each; one outgoing file at a time. A file never overwrites another (it becomes "name 2.ext"), names are reduced to a plain file name, and partial files are deleted when a transfer fails. Sending is held to 12.5 MB a second so a big file cannot crowd out the video.

**Sound.** The Mac's sound is captured with a Core Audio process tap (everything the Mac plays except SkyDesk itself), compressed with Opus at 48 kHz stereo, and played on the iPad, mixed with whatever the iPad itself is playing. The Mac's own speakers are silenced only while two things are true: real sound has been captured, and the iPad reports that it is playing. At any other time, including when the iPad is in the background or the sound connection drops, the Mac plays its sound itself. No volume or mute setting is changed. Sound goes from the Mac to the iPad only; there is no microphone path.

## iPad only mode

**iPad only** makes the iPad the Mac's only display: it first moves existing windows onto the iPad desktop, then switches the Mac's other displays off at the WindowServer level. It is available with a separate iPad desktop, input allowed and Accessibility granted, and by default it starts by itself on every connection ("Start in iPad only mode").

The Mac's displays and arrangement come back when you tap **Restore Mac**, when the session ends, when the Accessibility permission is lost, when the set of displays changes, or when someone uses the Mac's own keyboard or trackpad (a key, a click, or a few real pointer movements; input coming from the iPad is marked and does not count). Windows return to where they were unless you moved or resized them on the iPad.

Safeguards:

- A separate helper process (`SkyDeskRestore`, inside the app bundle) gets a heartbeat every second and restores the saved layout if the host quits, crashes or stalls for six seconds.
- The Mac's display stays off for at least 5 seconds and on for at least 20 before it is switched again, because switching the built-in panel in quick succession once left it dark (2026-11-13). The toolbar shows **Switching…** while the Mac waits.
- Only which displays are enabled and where they sit is changed; never resolution, brightness or mirroring. Display sleep is held off while the mode is on.

This uses the private `SLSConfigureDisplayEnabled` call, behind an availability check. It is a convenience, not a security lock.

## Updates

Both apps are updated from the Mac, without a cable.

1. Build both apps with the same build number: the Mac app (Debug) and a signed iPad app for the device (Release).
2. Stage them:

   ```sh
   Tools/publish-update.sh <derived-data-of-the-iPad-build> <derived-data-of-the-Mac-build>
   ```

   The script checks that the build numbers match and both signatures verify, packs the iPad app as an `.ipa`, and places everything in `~/Library/Application Support/SkyDesk/Updates/ready`.
3. The running host notices within about five seconds. It offers the iPad build at the start of the iPad's next session (or straight away if one is running): an **Update** button appears in the toolbar.
4. On the iPad, tap **Update › Install Update**. SkyDesk counts down three seconds, disconnects and goes to the Home Screen, because iPadOS only replaces an app that is off screen. Open it again afterwards; it reconnects by itself.
5. The Mac app replaces itself once the iPad that asked for the update disconnects. Without that, it does so on its own when no iPad is connected, the last session ended more than ten seconds ago, and the iPad has already reported the staged build. **Update Mac Now** does it on request.

**One-time setup on the iPad.** iPadOS installs over-the-air only from an HTTPS server it trusts. Each Mac creates its own small certificate authority for this. The first time, the update sheet offers **Get Certificate**: the Mac sends a profile over the SkyDesk file connection, and the sheet walks through installing it (Settings › General › VPN & Device Management) and switching on full trust (Settings › General › About › Certificate Trust Settings). The authority is limited by name constraints to private IPv4 ranges and `.local` names, so it cannot vouch for a website. Remove it at any time in VPN & Device Management.

**How the Mac replaces itself.** It checks the staged app's signature and that its signing requirement is identical to the running app's, so permissions and Keychain items carry over. A small script then waits for the host to quit, swaps the app in, keeps the previous one as `Updates/previous-host.app`, and reopens it the way it was (window open or menu bar only). If the swap fails the old app is put back. It never replaces itself while an iPad is connected or the display-restore helper is running. The log is `~/Library/Logs/SkyDesk/update.log`.

Limits: the Mac side needs macOS 15, and the iPad must be reaching the Mac on a private IPv4 address (10.x, 172.16 to 172.31.x, 192.168.x or 169.254.x), because the update certificate covers nothing else. A download is not counted as an install: the Mac trusts the iPad's build number only from its next connection.

## How it works

### Connections

A session is up to four separate TCP connections to port 48772, each with TLS 1.2 on top, so one kind of traffic never waits behind another, plus one encrypted UDP flow for video when it is available:

| Connection | Carries |
| --- | --- |
| Control | iPad to Mac: input, gestures, typed text, pings, frame acknowledgements, statistics, requests. Mac to iPad: session details, pointer image, text-field focus, clipboard text, update offers, the iPad's own key. |
| Video | HEVC frames, Mac to iPad: every frame until the UDP flow is up, keyframes always, and everything again if UDP stops. |
| Video datagrams (UDP, build 38) | Ordinary HEVC frames cut into datagrams, Mac to iPad, and requests for missing pieces back. |
| Files | File chunks and their acknowledgements, both ways. Opened when both sides allow files. |
| Audio | Opus packets, Mac to iPad, and "the iPad is playing" back. Opened when both sides allow sound. |

Every message has a 12-byte header (`SKYD`, version, kind, length). The length is checked against a per-kind limit before anything is allocated: 64 KiB for control messages (JSON), 8 MiB for a video frame. Optional abilities are negotiated with feature flags in the first messages (`StreamFeature` in `Sources/Core/Protocol.swift`), so either side can talk to an older build; the Mac uses a feature only when the iPad offered it.

**Video over UDP (build 38).** On TCP one lost packet holds back everything sent after it until the retransmission arrives, and TCP then slows the sender down. So when both sides offer it, video moves to UDP:

- The iPad opens a DTLS 1.2 flow to UDP port 48772 using the same key and the same preferred cipher suite as its TCP connections, and says which session it belongs to. The Mac accepts a flow only for the session in progress. No new secret and no home-made encryption is involved.
- Each frame is cut into datagrams of at most 1,180 bytes of frame data, small enough for any IPv6 path or VPN tunnel. The iPad asks again for exactly the pieces that are missing: after 2 ms for a gap below a piece that did arrive, after 4 ms when a frame's tail stops arriving. The time an answer takes is measured and sets how soon to ask again. The Mac keeps every frame until the iPad acknowledges it (the acknowledgement travels on the control connection) and re-sends the last piece of a frame it has heard nothing about, so a frame that vanished whole is noticed too. How long "nothing" has to last is learned from the acknowledgements themselves (the quickest of the last 32, times one and a half, plus 20 ms, and never under 35 ms), and such a probe is not counted as loss (both since build 40).
- Frames are still handed to the decoder complete and in order, because each one builds on the one before. The stream therefore stays lossless and still needs no periodic keyframes. What changes is how long a loss costs.
- Frames carry their sequence number on both paths and the iPad orders them by it, so switching paths needs no keyframe. TCP always carries the first frame of a session, whatever its size (build 39; build 38 chose by size alone and failed on a small first frame), and any frame over 256 kB (a keyframe is a megabyte or two; as datagrams one measured 2 MB frame took 110 ms and delayed the frames behind it).
- If the UDP flow never comes up (a network that blocks it), or the Mac gets no acknowledgement for a second while frames are outstanding, or the iPad's flow fails or receives video before the stream has started, everything outstanding is re-sent over TCP and the session carries on there. It does not return to UDP until the next connection.
- Nothing slows a UDP sender down by itself, so the Mac paces its datagrams (six times the video bitrate, at least 30 Mbps) and the bitrate control treats a link on which 12% or more of the datagrams have to be sent twice as congested.

What has been tested, all on one Mac: the logic against a simulated link (120 frames a second at about 25 Mbps; with 1% loss and a 5 ms round trip, median 3.5 ms and 99th percentile 23 ms from "encoded" to "ready to decode"; 5% loss, 12.5 and 34.5 ms; 2% loss with a 40 ms round trip, 56.5 and 80.5 ms; every frame delivered in order each time); the real sockets on loopback through a relay that drops datagrams (5% loss repaired on UDP, a blocked UDP path continuing over TCP without a missing frame, a wrong key refused); and real hardware-encoded video at 2752 × 2064 and 120 frames a second through 2% loss, all 300 frames decoded in order. For comparison, the usual estimate of what TCP can carry under loss (1.22 × segment size ÷ (round trip × √loss)) gives about 28 Mbps at 1% loss and 5 ms, and about 2.5 Mbps at 2% loss and 40 ms; that is a formula, not a measurement of this code. **Whether UDP improves anything on a real network has not been measured.** Compare the Late figure with "Video over UDP" off and on.

QUIC was considered and not used: Apple's QUIC needs TLS 1.3, which did not accept this project's pre-shared key in a loopback probe, so it would have needed certificates and a different pairing design, and its reliable streams wait behind a lost packet just as TCP does.

### Video

```text
Mac    ScreenCaptureKit            8-bit frames at the session's frame rate, sRGB, Rec. 709
       frame window                skips a capture before encoding when the iPad is behind
       VideoToolbox HEVC           hardware only, realtime, no frame reordering
       video connection
iPad   VideoToolbox HEVC           hardware only
       newest-frame mailbox        an undrawn frame is replaced by a newer one
       Metal                       one textured quad, YUV to RGB, optional sharpening
       screen                      at the display tick, or on arrival
```

- **Size.** With a separate desktop the Mac creates a virtual 2× Retina display with the pixel size of the iPad's window; a full-screen M5 13-inch iPad Pro asks for 2752 × 2064 (1376 × 1032 points). The virtual display uses the private `CGVirtualDisplay` classes, as [Chromium's test code](https://raw.githubusercontent.com/chromium/chromium/cca923fbde2d338f3730885e0dbe734eee8465a2/ui/display/mac/test/virtual_display_mac_util.mm) does; a macOS update could break it, and mirroring uses public APIs only.
- **Keyframes.** One at the start and one after each pause. A keyframe at 2752 × 2064 measured about 1.4 to 1.9 MB, which is why there are no periodic ones.
- **Frame window.** The iPad acknowledges every frame once it is decoded. The Mac allows 2 to 8 frames in flight, sized from the recent minimum acknowledgement time plus two frames of slack, and stops taking new captures when the oldest outstanding frame is over 120 ms old. Skipping happens before encoding, so no frame another frame depends on is ever dropped.
- **Stalls.** Queued data is bounded; a connection that cannot drain is closed rather than left to build up minutes of video. Five seconds without a ping, or a frame unacknowledged for five seconds, ends the session, and every held key and button is released on the Mac.
- **Adaptive bitrate.** Twice a second the Mac looks at two things it measures itself: video waiting to be sent, and how long frames take from "handed to the network" to "acknowledged". The iPad's own measured round trip is taken off the second first, so a network path that is simply slow is not mistaken for congestion (on 2026-11-13 a path that answered everything about 80 ms late had pinned the bitrate at its floor, which blurred the picture without shortening the delay). When video really queues, the bitrate is cut by a quarter to a half towards what the network actually carried; it climbs back at 15% a second, slower near the rate that last failed. It never exceeds the Bitrate setting or goes below 1.5 Mbps. The host window and log say when the network is limiting it.
- **Drawing on arrival** ("Show frames sooner"). A decoded frame is drawn at once if nothing has been drawn for the coming refresh and enough time is left, instead of waiting for the next display tick; the margin adapts to misses. In build 35 this did **not** reduce the measured iPad display time: about 19 ms, against 16.4 ms before. Build 36 asks for a display timer at exactly the stream's rate instead of a range and logs what happens. On the real iPad (2026-11-13) the timer ran at 120 Hz, yet 94 of the first 123 frames drawn on arrival missed the refresh they were aimed at even with the margin at its 7.5 ms maximum, and the display time stayed where it was (about 15 to 18 ms). iPadOS evidently needs a frame almost a whole refresh ahead, so the setting is off by default from build 38 and kept only for experiments.
- **4:4:4** ("Sharper colour"). Normal video keeps colour at half resolution in each direction (4:2:0), which softens coloured text and thin coloured lines. With the option on, an iPad whose hardware can decode HEVC 4:4:4 offers it, and a Mac whose hardware encoder has that profile uses it; otherwise the session carries on in 4:2:0. If a 4:4:4 session ends before a frame reaches the screen, the iPad switches the option off again. It needs more bitrate for the same quality; how much has not been measured.

### Input

Input events travel as small JSON messages on the control connection and are replayed on the Mac as Core Graphics events, each marked as remote so iPad only mode can tell them from someone at the Mac. Pointer positions are fractions of the desktop, mapped through the same aspect-fit and keyboard shift the renderer uses. Pings and frame acknowledgements are answered on the network queue of each side, not the main thread, so interface work does not distort them.

### Sound

A fourth connection, so sound never waits behind video or files. Opus packets carry 10 ms each at 128 kbit/s. The iPad keeps a cushion of 30 ms of sound, grows it towards 100 ms each time playback runs dry, and throws the backlog away if more than 220 ms is waiting, rather than play late. The Mac drops sound instead of queueing it when the connection backs up. Nothing synchronises sound with the picture.

## Pairing and security

**Authentication.** Every session connection is TLS 1.2 from Network.framework with a pre-shared key; there are no certificates, and no SkyDesk message is read before the handshake succeeds. A wrong key fails the handshake. The Mac accepts two kinds of key:

- **The password key.** The password is stretched into a 256-bit key with PBKDF2-HMAC-SHA256, one million rounds, and a salt that is the same for every SkyDesk installation. The Mac keeps the password itself in its Keychain so it can show it; the iPad keeps only the derived key.
- **A key per iPad (build 37).** A paired iPad's key is 256 random bits, created on the Mac, sent once over the already encrypted control connection, and stored in both Keychains. It starts working when that first session ends.

**Paired iPads.** The Mac lists up to twelve. **Remove** deletes one iPad's key and disconnects it if it is connected; the others are untouched. Changing the password does not affect iPads that already have their own key. With "Let new iPads pair with the password" off, the Mac accepts only the listed iPads' keys and the password opens nothing. If no iPad has a key, the password always works, so the Mac cannot be left with no way in. A removed iPad still knows the password: while password pairing is on it can pair again, so change the password as well if it should stay out.

**Forward secrecy (build 37).** Both sides prefer `TLS_ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256`: the pre-shared key proves who is connecting, and a fresh Diffie-Hellman exchange supplies each connection's keys, so a key that leaks later cannot decrypt sessions recorded earlier. If either side is older than build 37 the connection falls back to `TLS_PSK_WITH_AES_128_GCM_SHA256`, which has no forward secrecy. The Mac's log records which was used. So far this has only been exercised by a unit test connecting to itself on the Mac, not between the real devices.

**What is weak, plainly.**

- TLS with a pre-shared key is not a password-authenticated key exchange. The note in `PairingPassword.swift` assumes that anyone who records one handshake made with the password key, or who connects once to the Mac, can test password guesses offline. That note was written before build 37's forward-secret suite. By the rules of TLS 1.2 that suite should stop someone who only records a handshake from testing guesses, because the session keys then also depend on a Diffie-Hellman secret the recorder does not have. It does not stop someone the iPad can be made to connect to in place of the Mac, and because the older suite is still accepted for compatibility, someone in the middle of the connection could force its use. This is reasoning from the protocol, not something tested here; treat the note's assumption as still standing. The only defences are the password's own strength (a generated one has about 39.6 bits) and the cost of a guess (about 0.14 s on an M4 Max core). The salt is shared by all installations, so precomputed tables are possible in principle. A paired iPad's own key is not derived from a password and cannot be guessed this way.
- The Mac does not limit or record failed attempts.
- While password pairing is on, anyone who connects with the password can ask for a key under any iPad's identifier, which replaces that iPad's key (it then falls back to the password and is issued a new one). With password pairing off, an iPad can only renew its own.
- The UDP video flow is DTLS 1.2 with the same keys and suites, so everything above applies to it equally.
- Whoever holds a valid key gets everything the settings allow: the display, input, clipboard text, files into Downloads, the Mac's sound, and switching off the Mac's displays.
- The port listens on all interfaces. It is meant for a trusted home network or a VPN. Do not forward it from a router or expose it to the internet.
- Bonjour advertises the Mac's name and the service, never a key.
- Keys and the password are stored as Keychain items marked "this device only" on both devices. The list of paired iPads (names, identifiers, dates) is kept in the app's preferences.
- The update server uses its own certificate. Only paths beginning with a random token, sent to the iPad over the SkyDesk connection, return anything, and it stops after fifteen minutes. Its certificate authority's private key sits in `~/Library/Application Support/SkyDesk/UpdateCA`, protected by file permissions only.
- Nothing here has had an independent security review.

## Known limits

- Performance is unmeasured end to end (see the top of this file).
- Video over UDP is new and unproven on real networks. After a fallback to TCP a session stays on TCP. There is no forward error correction: every loss costs at least a round trip.
- Wireless updates only work when the iPad reaches the Mac on a private network address (10.x, 172.16–31.x, 192.168.x, 169.254.x); on other addresses, which some VPNs use, the Mac says so instead of offering a download the iPad could not trust.
- "Use USB cable when plugged in" only applies when a Mac is chosen under Nearby; automatic connections and Recent Macs never try the cable first.
- No relay or NAT traversal; away from home needs a VPN (a WireGuard session worked on 2026-11-14).
- One iPad at a time. No HDR. A MacBook with its lid closed is not handled.
- The desktop size is set when the session starts and is not renegotiated.
- Clipboard: text only. Files: no folders, 4 GB each. Sound: Mac to iPad only.
- Three-finger trackpad swipes cannot reach SkyDesk. Secondary-button drags are not sent.
- The project depends on private or undocumented macOS behaviour: the virtual display, switching displays off, the gesture event fields, and on the iPad the call that sends the app to the Home Screen before an update. It is a locally signed personal project, not App Store material.
- The iPad simulator may decode in software and cannot report real presentation times, so it says nothing about speed.

## Tests and checks

```sh
swift test                                  # 152 tests at build 40 (about 20 s; a few open loopback sockets)
swift run skydesk-check --frames 120        # synthetic frames, hardware HEVC, encrypted loopback
swift run skydesk-check --width 1920 --height 1200 --frames 240 --low-latency
```

The tests cover message framing and hostile input, HEVC framing, 4:4:4 colour, geometry and the keyboard shift, frame pacing, bitrate control, the draw-on-arrival timing, statistics, password derivation, per-iPad keys and cipher-suite choice over real TLS on loopback, video over UDP (the logic against a simulated lossy link, then real encrypted sockets through a lossy relay, with real encoded video), frame lateness, recent Macs and the address race, clipboard, file transfer, sound compression and its cushion, scroll momentum, gestures, window placement, display-switch pacing, and the update server.

`skydesk-check` encodes generated pixels, sends them over an encrypted loopback connection and decodes them. It never captures the screen, reads the clipboard or injects input. Its frames are static and not paced by a display, so its timings prove nothing about sustained frame rate or latency. Its `tls` label reports the suite actually negotiated (since build 38).

Two self-checks exist for development: starting the host with `SKYDESK_SMOKE_PNG=<file>` builds its window off screen, saves a picture and exits without opening the port or touching displays; `SKYDESK_DEMO=1` in the simulator shows the streaming screen with generated frames.

Still to do on the real devices: run build 40 through the VPN and see the bitrate stay up; switch 4:4:4 on once; compare the Late figure with video over UDP off and on; the three unconfirmed items under [Status](#status); and film an input and its response at high speed, with both screens in view, to check the delay estimates.

## Source map

- `Sources/Core`: shared by both apps and the tests. Protocol and feature flags (`Protocol.swift`), TLS transport and Keychain (`Transport.swift`), video over UDP (`DatagramVideo.swift` for the logic, `DatagramTransport.swift` for the sockets), pairing (`PairingPassword.swift`, `PairedDevices.swift`), recent Macs and connection decisions (`RecentHosts.swift`), codecs (`VideoCodec.swift`, `AudioCodec.swift`), bitrate control, draw-on-arrival timing, statistics and the log, clipboard, file transfer, gestures and scrolling, the Metal renderer, update support, the Mac's address list, and display layout and window placement for iPad only mode.
- `Sources/Host`: the Mac app. `HostModel.swift` (sessions, settings, updates), `VideoRouter.swift` (TCP or UDP for each frame), `SkyDeskHostApp.swift` (menu bar and window), `DisplayCapture.swift`, `InputInjector.swift`, `HostAudio.swift`, `MacDisplayController.swift` and `WindowMigrator.swift` (iPad only mode), `VirtualDisplayBridge.m`, `ContinuityLink.swift` (AirDrop link), `UpdateCertificates.swift` (update authority and self-update), `CursorMonitor.swift`, `RemoteFocusMonitor.swift`.
- `Sources/Pad`: the iPad app. `ClientModel.swift` (connections, sessions, settings), `SkyDeskPadApp.swift` (screens, toolbar, menus), `RemoteDesktopView.swift` (drawing and all input), `FrameRenderer.swift`, `AudioPlayer.swift`, `RemoteKeyboardProxy.swift`.
- `Sources/Recovery`: the `SkyDeskRestore` helper that restores the Mac's displays.
- `Tests`: unit and loopback tests for `Sources/Core`.
- `Tools`: `Check` (`skydesk-check`), `publish-update.sh`, `EncoderProbe.swift`, `Icon/MakeIcon.swift`, and two display experiments (`VirtualDisplayCheck.m` creates a virtual display; `ExclusiveDisplayCheck.swift` also switches the Mac's real display off and back). Do not run those while using the Mac through SkyDesk.
- `Config`: Info.plists, entitlements, icons. `project.yml`: the Xcode project definition. `Package.swift`: the core library, tests and `skydesk-check`. `scripts/build.sh`: both apps.
- `Verification`: build and test logs and source snapshots kept along the way. `VERIFICATION.md`, `findings.md`, `progress.md`, `task_plan.md`: notes from the first builds on 2026-11-12, not kept up to date.

Files the host writes: `~/Library/Logs/SkyDesk/stream-metrics.log` (numbers and events from both devices, no screen content, restarted above 4 MB), `display-session.log` and `update.log` beside it, and `~/Library/Application Support/SkyDesk` (staged updates, the update authority, display-switch timing).

## Apple references

- [ScreenCaptureKit cadence and surfaces](https://developer.apple.com/videos/play/wwdc2022/10155/)
- [Capture frame interval](https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/minimumframeinterval)
- [VideoToolbox low-latency encoding](https://developer.apple.com/videos/play/wwdc2021/10158/)
- [TLS pre-shared key API](https://developer.apple.com/documentation/security/sec_protocol_options_add_pre_shared_key(_:_:_:))
- [Trackpad scroll events](https://developer.apple.com/documentation/uikit/uipangesturerecognizer/allowedscrolltypesmask)
