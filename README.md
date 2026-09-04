# ControlMyMac

Remote-control a Mac from an iPhone over a Tailscale network: the Mac
streams its screen, the phone sends back input events.

Tailscale does the hard part. Both devices already have stable addresses
and mutual authentication, so there is no signaling server, no NAT
traversal, no TURN, and no certificate management — which is why this
does *not* use WebRTC.

## Layout

```
Sources/
  ControlMyMacKit/     shared types (also linked by the iOS client later)
    EncodedFrame.swift
    VideoSink.swift    where encoded frames go: file now, socket in M1
  ControlMyMacAgent/   the Mac-side agent
    ScreenCapturer.swift   SCStream -> CVPixelBuffer
    VideoEncoder.swift     VTCompressionSession, tuned for low latency
    SyntheticSource.swift  generated frames for permission-free testing
    CaptureSession.swift   wires the pipeline, keeps stats
    StreamServer.swift     M1 sink: NWListener, pushes frames to clients
    InputInjector.swift    CGEvent injection + secure-input detection
    QualityController.swift  the adaptive ladder
    PowerManager.swift     sleep assertions and display wake
    AgentEngine.swift      the whole pipeline, wired once
    ServeMode.swift        --serve entry point (a shell around the engine)
    GUI/                   the Mac app
      ControlMyMacGUI.swift  App scene, menu bar item, app delegate
      AgentController.swift  main-actor face of the engine
      DashboardView.swift    status, address, live numbers, clients
      SetupView.swift        the permission/network checklist
      SettingsView.swift     stream, control and app preferences
      ActivityView.swift     live log tail
      Components.swift       tiles, cards, checklist rows
      Preferences.swift      UserDefaults-backed settings
      TailscaleStatus.swift  reads the local tailscaled
      LoginItem.swift        SMAppService registration
  ControlMyMacKit/     (continued)
    WireProtocol.swift     message types and framing
    MessageCoding.swift    encode/decode
    ByteCoding.swift       bounds-checked big-endian reader/writer
    MessageConnection.swift NWConnection speaking framed messages
    VideoCodecSupport.swift CMSampleBuffer <-> wire, both directions
    MP4FileSink.swift      passthrough mux to .mp4
    VideoStreamClient.swift shared client: connect, reassemble frames
  ControlMyMacViewer/  Mac-side receiver used to verify the wire format
    StreamClient.swift     adds a decode pass and a re-mux
    FrameDecoder.swift     VTDecompressionSession
ControlMyMaciOS/       the iPhone client
  VideoRenderer.swift    AVSampleBufferDisplayLayer, decodes internally
  VideoLayerView.swift   UIViewRepresentable host
  TrackpadView.swift     relative pointer, click, scroll, drag gestures
  KeyCaptureView.swift   UIKeyInput host for the system keyboard
  ModifierBar.swift      esc/tab/arrows and the modifier keys
  SettingsSheet.swift    quality, stats, sensitivity (three-finger tap)
  FloatingKeyboardButton.swift  draggable, optional keyboard toggle
  StreamViewModel.swift  connection state for SwiftUI
  ContentView.swift      fullscreen video, no permanent chrome
ControlMyMac.xcodeproj  for Xcode development and device builds
scripts/
  build.sh             builds + assembles + signs ControlMyMac.app
  package.sh           Developer ID signing, DMG, notarization
  make-icon.swift      draws the app icon (generated, not committed)
  run.sh               launches via LaunchServices, tails the log
  streamtest.sh        end-to-end frame-exact regression
```

## The Mac app

`build/ControlMyMac.app` is a normal Mac app: Dock icon, window, menu bar
item. It is also the headless agent — the same binary, dispatching on
whether a mode flag was passed. One bundle means one code signature,
which means **one Screen Recording grant and one Accessibility grant**
covering both the app and every script that drives it.

Four panes:

- **Dashboard** — start/stop, the host and port to type into the iPhone,
  live frame rate, bitrate, resolution, drops and uptime, and a list of
  connected devices.
- **Setup** — a checklist of everything that has to be true before the
  phone can connect, each with the fix one click away. This is the
  screen that answers "why isn't it working?".
- **Activity** — a live tail of the agent log.
- **Settings** — quality, frame rate, codec, port, view-only mode, sleep
  behaviour, launch at login.

The bundle identifier comes from `scripts/local.env` (see
`scripts/local.env.example`), falling back to `com.example.controlmymac.agent`.
Pick one and keep it: TCC keys its grants on the identifier, so renaming
it later silently throws away the Screen Recording and Accessibility
permissions already granted, with no error to explain why capture
suddenly fails.

## Idle by default

Capture and encoding only run while a device is connected. With nobody
watching, the `SCStream` and the `VTCompressionSession` are torn down
entirely — not paused — and all that remains is an `NWListener` waiting
on a socket.

Measured on an M3 Pro, one process:

| state | CPU |
|---|---|
| headless agent, idle | 0.0% |
| app with its window closed, idle | 0.0% |
| app with its window open, idle | 0–2% |
| streaming 1280p30 to one viewer | ~26% |

The phone notices nothing. Capture comes back up about 65ms after a
client connects, and the client waits for `videoFormat` before doing
anything anyway — so a cold start and a warm one look identical from the
other end. When the last viewer leaves there is a five-second grace
before teardown, so a phone that blips off Wi-Fi and straight back does
not pay for a pipeline rebuild.

Two things follow from this that are easy to get wrong:

- `CaptureSession.stop(finishSink:)` exists because the sink *is* the
  server. Finishing it would close the listener along with the encoder,
  which is the one thing that must never happen.
- Pointer scaling cannot wait for the encoder. `ScreenCapturer.outputSize`
  computes the stream geometry from the display alone, so the injector
  knows the coordinate space during the window where a phone is
  connected and moving the cursor but no frame has been encoded yet.

## First run

```bash
cp scripts/local.env.example scripts/local.env   # then edit it
./scripts/build.sh
open build/ControlMyMac.app
```

`scripts/local.env` is gitignored and holds the bundle identifier and
Apple Team ID your builds sign with. Without it the build still works
and falls back to `com.example.*` identifiers, which are fine for
running locally but must be changed to something you own before you sign
for anyone else.

The app opens on **Setup**, which lists everything that has to be true
before a phone can connect — two macOS permissions and a working
tailnet — with the fix for each one click away.

For the iOS app, open `ControlMyMac.xcodeproj` and set your team under
Signing & Capabilities; the committed project deliberately has no team
and a placeholder bundle identifier.

## Build and run

```bash
./scripts/build.sh
open build/ControlMyMac.app             # the app
```

Headless, for scripts and tests — the same binary, different mode:

```bash
./scripts/run.sh --capture --duration 10   # record to a file (M0)
```

Stream it instead, and receive it:

```bash
open -a build/ControlMyMac.app --args --serve --duration 0
.build/release/ControlMyMacViewer --host your-mac.your-tailnet.ts.net --output ~/Desktop/rx.mp4
```

Or run the whole check in one go:

```bash
./scripts/streamtest.sh                              # loopback
./scripts/streamtest.sh your-mac.your-tailnet.ts.net  # over the tailnet
```

## iOS client

For the simulator, with no Xcode project involved:

```bash
./scripts/build-ios.sh
xcrun simctl install booted build/ios/ControlMyMac.app
xcrun simctl launch booted com.example.controlmymac.ios -host your-mac.your-tailnet.ts.net -autoconnect YES
```

`UserDefaults` picks up `-key value` launch arguments for free, which is
how the app gets driven from `simctl` where there is no way to tap a
button. Drop `-autoconnect YES` to use the connect form.

For your actual iPhone, open `ControlMyMac.xcodeproj` and run. The
project compiles `ControlMyMacKit` straight into the app target via a
file-system-synchronized group rather than linking it as a package, so
there is one less moving part and no manifest to keep in sync.

Output goes to `~/Movies/ControlMyMac/`, logs to
`~/Library/Logs/ControlMyMac/{agent,viewer}.log`.

Verify the encoder without any permissions:

```bash
./build/ControlMyMacAgent.app/Contents/MacOS/ControlMyMacAgent --selftest --duration 4
```

## Two environment gotchas

**The CommandLineTools toolchain is broken on this machine.** Its
`libPackageDescription.dylib` is missing symbols its own
`.swiftinterface` advertises, so SwiftPM manifests fail to *link*.
`scripts/build.sh` works around it by setting `DEVELOPER_DIR` to the
Xcode install, which needs no `sudo`. Fixing it properly:

```bash
sudo xcode-select -s /Applications/Xcode-beta.app
```

**The `.app` bundle is not cosmetic.** A bare executable launched from a
terminal has its TCC decisions attributed to the *terminal*, not to
itself. A signed bundle with a stable identifier gets its own Screen
Recording grant. Signing with a real Apple Development certificate
(rather than ad-hoc) means TCC keys on team + bundle ID, so the grant
survives rebuilds instead of re-prompting every time.

## Design notes

Settings that decide whether this feels immediate or soupy:

- `RealTime = true`, `AllowFrameReordering = false` — B-frames cost a
  frame of latency and buy nothing for screen content.
- Long GOP (600) with on-demand IDR. Periodic keyframes waste bitrate
  when the receiver can request one exactly when it needs one.
- Capture downscales on the GPU before the encoder sees a frame. A
  Retina panel is ~3456px wide; encoding that is pure waste.
- `pixelFormat = 420YpCbCr8BiPlanarFullRange` so buffers reach
  VideoToolbox with no conversion.

ScreenCaptureKit dedupes: on a static screen it delivers frames marked
`.idle` with no image buffer. `ScreenCapturer` counts those separately
rather than treating them as a dead link.

## Milestones

- [x] **M0** — capture + encode, written to `.mp4`. Proves TCC and the
      ScreenCaptureKit -> VideoToolbox path with no networking.
- [x] **M1** — streaming over the network, with a receiver that decodes
      every frame and re-muxes it. Verified on loopback and over the
      tailnet interface; a genuine second-machine run still needs a
      client that isn't macOS.
- [x] **M2** — iOS client, video only. Verified on a physical iPhone
      over the tailnet.
- [x] **M3** — pointer: move, click, double-click, right-click, scroll,
      press-and-drag. Verified: cursor moved 162.0pt of 162.0pt expected.
- [x] **M4** — keyboard. Ordinary text goes over as literal text and is
      injected with `keyboardSetUnicodeString`, so any layout, language,
      emoji and dictation work; keycodes are used only for shortcuts and
      for keys with no character.
- [x] **M5 (part)** — adaptive quality ladder with manual override.
      Verified switching 1920p <-> 640p live in ~100ms.
- [ ] Reconnect on network change, clipboard sync, menu bar UI.

## Wire format

Every message is length-prefixed, big-endian:

```
u32  byteLength      (of everything after this field)
u8   messageType
...  payload
```

A client opens **two** connections to the same port and declares each
with a `hello`. Multiplexed onto one TCP stream, head-of-line blocking
would stall input behind video on every hiccup — the worst-feeling
failure mode a remote desktop has.

Because both ends are Apple, the payload stays in **AVCC** (length-
prefixed NALU) form the whole way. SPS/PPS travel out of band in a
`videoFormat` message pulled from the `CMFormatDescription`, so there is
no Annex-B conversion anywhere.

The server drops non-keyframes once a client has `maxPendingSends`
frames unacknowledged. On a slow link, buffering more only converts
bandwidth you don't have into latency you can't hide. Keyframes are
never dropped: losing one strands the decoder until the next IDR.

## Sleep, and staying reachable

A sleeping Mac leaves the tailnet completely — the interface goes down
and the node shows offline, so there is nothing for the phone to reach.
Wake-on-LAN does not bridge this: magic packets are layer 2 and do not
cross a tailnet. Waking a slept Mac remotely needs an always-on device
on the *same LAN* to send that packet.

So the agent doesn't try to wake the machine, it keeps it reachable:

- Holds `kIOPMAssertionTypeNoIdleSleep` for its whole life, so the Mac
  stays on the network.
- Holds `PreventUserIdleDisplaySleep` only while a viewer is connected —
  with nobody watching, the display should be free to sleep.
- Calls `IOPMAssertionDeclareUserActivity` when a client connects, which
  wakes a sleeping display. This matters because ScreenCaptureKit stops
  delivering frames entirely once the display sleeps, so without it a
  client would connect to a black screen.

Check what's actually set with `pmset -g custom`; `sleep 0` on AC means
the Mac never idle-sleeps while plugged in. Confirm the agent's
assertions are live with `pmset -g assertions`.

Closing the lid still sleeps the machine regardless of any assertion.

## Quality

`QualityLevel.ladder` is shared between the agent and the client, so the
picker and the controller can never disagree about the rungs.

Auto mode steps **down quickly** on backpressure drops and **back up
slowly**, after 20 clean seconds. The asymmetry is deliberate: dropping
late means a visibly broken stream, while climbing early means
oscillating between two levels, which looks worse than staying low.

A resolution change reconfigures `SCStream` in place, but a
`VTCompressionSession` is fixed-size, so the encoder is rebuilt — new
parameter sets, new `videoFormat`, new IDR.

## Things that broke, and why

Worth keeping: each of these produced a black screen or a silent failure,
and none was obvious from the symptom.

**A no-op quality request rebuilt the encoder.** The client sends its
quality preference on every connect. `QualityController` fired its change
callback even when nothing had changed, which rebuilt the
`VTCompressionSession`, produced new parameter sets, and pushed a format
change at a client that had just started decoding. Fixed by deciding
before mutating, and by having `CaptureSession.reconfigure` return early
when the geometry is unchanged — a bitrate-only change is applied live
instead.

**The renderer checked the wrong status object.** On iOS 17+ frames go
into `layer.sampleBufferRenderer`, which has its own `status`. The code
checked `layer.status`, so a failure on the path actually in use was
never seen and the flush-and-recover never ran. One bad format change
meant a black screen for the rest of the session.

**The display layer was never flushed across a format change.** Feeding
`AVSampleBufferDisplayLayer` buffers with a new format description while
it still holds the old one wedges it. It now flushes and asks for an IDR
before anything with the new format arrives.

**Dead connections were never dropped.** A send to a closed socket fails
with `ENOTCONN` but does not move an `NWConnection` to `.cancelled` or
end its receive loop, so nothing noticed. The server kept pumping frames
at a corpse — one error per frame, forever — while still counting it as
a live client. Fatal socket errors now cancel the connection, which is
what a phone dropping off cellular looks like.

**The "needs a restart" banner was `@State`.** Port, frame rate and
codec only apply when the pipeline starts, so Settings shows a banner
when they drift. Storing that as view state meant navigating to another
pane and back silently cleared it, leaving an unapplied change with
nothing on screen to say so. It is now derived: the engine's snapshot
carries the configuration it is actually running with, and the banner is
a comparison against it. Derived state cannot go stale.

**The app filtered itself out of its own stream.** The capturer excluded
its own process from the `SCContentFilter`, which was right when the
agent was headless and had no UI worth seeing. Once it became a real app
with a dashboard, the one window you might actually want to reach from
the phone — to change quality, or to stop sharing — was the only window
you could not see. Nothing is excluded now; there is no feedback loop to
avoid, because the Mac app renders numbers, never the video.

**A `repeatForever` animation never stopped.** The status dot pulses
while a device is connected. Setting its animated value back to `false`
does not cancel a `repeatForever` — the view keeps redrawing at display
rate, forever. The app sat at ~22% CPU indefinitely after any session
ended, which is precisely the cost idle mode exists to remove. The
pulsing ring is now a separate view that only exists while animating;
removing it from the hierarchy is what actually stops it.

**The input test blamed the code for a hand on the trackpad.** It reads
the real cursor, injects a move, and reads again — so any human mouse
input during that window corrupts the measurement, and it reported
"scaling is wrong". It now watches the cursor for 250ms with nothing
injected first, checks for vertical drift it never causes itself, steps
away from the display edge instead of clamping against it, and retries;
interference is reported as INCONCLUSIVE rather than as a failure.

**SwiftUI printed `1,280p`.** `Text("\(width)p")` resolves to the
`LocalizedStringKey` initialiser, which runs interpolated numbers through
a formatter and adds thousands separators. Resolutions and port numbers
need `Text(verbatim:)`; counts are better off with the grouping.

**`Scene.defaultSize` is ignored on this macOS build**, and
`.windowResizability(.contentMinSize)` makes it worse — the window opens
pinned to the content's *minimum*. The opening size is now set by hand
on first launch only, so the window still remembers whatever size it is
left at afterwards.

**`scripts/build.sh` failed silently for several commits.** A comment was
placed inside a `$(...)` substitution, so the `#` swallowed the closing
paren. The script printed a build success from the earlier `swift build`
line and then died, leaving a stale `.app` bundle. Several "verified"
runs were testing an old binary. If a change appears to have no effect,
check that `scripts/build.sh` exits 0 before believing anything else.

## Shipping it

`./scripts/package.sh` builds a DMG. Whether anyone else can run it
depends entirely on the certificate:

| Certificate | Runs on |
|---|---|
| Ad-hoc (`-`) | this Mac, and TCC re-prompts on every rebuild |
| Apple Development | Macs in your provisioning profile |
| Developer ID Application | any Mac, once notarized |

The current build uses **Apple Development**, so the DMG is fine for
moving between your own machines and useless to anyone else — Gatekeeper
refuses it outright. Distributing properly needs a paid Apple Developer
Program membership (the free tier does not issue a Developer ID), then:

```bash
xcrun notarytool store-credentials ControlMyMac \
  --apple-id you@example.com --team-id YOUR_TEAM_ID --password APP-SPECIFIC-PW

NOTARY_PROFILE=ControlMyMac ./scripts/package.sh
```

`package.sh` detects the Developer ID, signs with it, submits for
notarization, waits, and staples the ticket so first launch works
offline. The hardened runtime is already on — `build.sh` signs with
`--options runtime`, which notarization requires.

The iPhone side is the harder half of shipping: it needs App Store review
or TestFlight, and an app whose entire purpose is remote-controlling a
computer draws scrutiny. Ad-hoc distribution to your own devices has no
such problem.

## Known limits

- **Secure Input** — when a password field is focused anywhere, macOS
  blocks synthetic keyboard events system-wide. You cannot type into a
  password prompt remotely. Detect it and say so rather than looking
  broken.
- **Lock screen** — a user-session agent cannot capture or post events
  to `loginwindow`. Keep the Mac logged in.
- **Sleep** — hold an `IOPMAssertion` (or `caffeinate -d`) while a
  client is connected, or the link dies with the display.
- **Backpressure is untested under real constraint.** It never triggers
  on loopback or LAN, which also means the auto quality ladder has only
  been exercised by asking for levels manually, never by real congestion.
- **No reconnect.** A dropped connection shows a banner with a Retry
  button; it does not come back on its own when the network returns.
- **`open -a` will not pass `--args` to an already-running instance.**
  `scripts/streamtest.sh` silently measures the wrong agent if the app
  is already up. Quit it first.
- **Settings that need a restart.** Port, frame rate and codec are baked
  into the listener and the capture session at start. The app shows a
  banner and a Restart button rather than pretending they apply live.
- **Portrait wastes most of the screen.** A 16:10 desktop aspect-fit
  into a portrait phone is tiny. Landscape fills correctly; pinch-zoom
  and pan are the real answer and belong with the input work.
- **Not yet tested off the local network.** The physical-device run
  worked, but Tailscale reported a direct connection over a private
  LAN range — phone and Mac were on the same network. Cellular is the untested case, and the one that
  matters for the actual goal.
- **The jitter number is not latency.** Client and server clocks are
  never synchronised, so only the spread of arrival times is meaningful.
  Absolute one-way delay would need timestamp exchange.
