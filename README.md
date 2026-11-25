# Mezcla

Per-app (and per-browser-tab) volume from the macOS menu bar. Native Swift, SwiftUI and Core Audio,
under 1 MB, with no virtual audio drivers or kernel extensions.

- A slider for every app that uses audio, with its real icon. Helper processes (Chrome, Discord, Safari's
  WebKit service, and so on) are grouped under the app you recognise.
- **Per-tab volume in Safari and Chromium browsers** (Helium, Chrome, Brave, Edge, Arc, Vivaldi, Opera): each
  tab that plays audio gets its own row under its browser, with the site's real favicon, up to 150 %.
- **Per-app output**: send Music to a JBL speaker and Zoom to the laptop speakers. Right-click an app › Output,
  or click the device glyph next to its name. Remembered by device, even while it is disconnected.
- **Ducking during calls**: when an app records and plays at once (Zoom, Teams, Meet in a browser, FaceTime),
  everything else fades down to 15/30/50 % and gently back afterwards. Dictation apps don't trigger it.
- **Microphone indicator**: apps using the microphone get an orange mic glyph, and apps that only record (such
  as dictation tools) are listed under "Using Microphone".
- **Real devices**: outputs use Apple's own glyphs (AirPods models, Beats, HomePod) or the right kind of
  device (earbuds, over-ear headphones, speaker, TV), with battery levels for Bluetooth headsets and a brief
  card under the menu bar when one connects.
- Soft changes: volume glides over about 50 ms, an app that is already playing fades from where it was, and
  muting fades out instead of cutting.
- Click an icon to mute. Optional boost to 150 % with a soft limiter (−0.3 dBFS ceiling), so boosted audio
  never clips.
- Output volume and device picker, in sync with the volume keys and Control Center.
- Remembers each app's volume and applies it as soon as the app uses audio again.
- Follows output changes (AirPods, HDMI, USB), sleep and wake, and apps that play to a non-default device.

Requires macOS 14.2 or later and the **System Audio Recording** permission. Audio never leaves the Mac.

## Use

```sh
scripts/build-app.sh          # builds build/Mezcla.app (release, signed)
open build/Mezcla.app
swift test                    # 63 tests
scripts/build-app.sh --install  # also installs to /Applications and relaunches
```

### Per-tab volume

Browsers mix all of their tabs into one audio stream before macOS sees it, so no app can split tabs from the
outside. Mezcla includes a small browser extension that applies each tab's volume inside the page. Install it
once per browser (Settings › Per-Tab Volume in Browsers… walks you through it):

1. Open `chrome://extensions` and turn on **Developer mode**.
2. Click **Load unpacked** and choose `~/Library/Application Support/Mezcla/Browser Extension`.

At launch, Mezcla registers its native messaging host with every installed Chromium browser. Nothing else
needs configuring.

### Diagnostics

```sh
build/Mezcla.app/Contents/MacOS/Mezcla --selftest           # devices, audio processes and how they group
build/Mezcla.app/Contents/MacOS/Mezcla --selftest spotify   # real tap at 25 % for 3 s, with the measured level
build/Mezcla.app/Contents/MacOS/Mezcla --preview            # the live panel in an ordinary window
build/Mezcla.app/Contents/MacOS/Mezcla --preview demo light # a representative state, without touching audio
build/Mezcla.app/Contents/MacOS/Mezcla --preview demo quiet # toggles idle apps to watch the panel resize
log stream --level debug --predicate 'subsystem == "dev.mezcla"'
```

## How it works

**Apps.** For every app whose volume is not 100 %:

```
app ──► process tap (muted) ──► private aggregate device ──► C IOProc: gain ──► real output
```

The tap silences the original stream and hands it to Mezcla, and the IOProc applies gain and plays it. All of
it is private to the process: if Mezcla quits or crashes, macOS removes the taps and the apps immediately sound
normal again.

**Tabs.**

```
Mezcla ⇄ Unix socket ⇄ mezcla-bridge (native messaging host) ⇄ extension service worker ⇄ page scripts
```

The page script scales every `<audio>` and `<video>` element (including detached `new Audio()` elements) and
routes Web Audio through one gain node per audio context. Pages still see their own volume, so a site's volume
controls keep working. Muting a tab uses the browser's native tab mute.

## Architecture

```
Sources/
  MezclaDSP/          C. Real-time kernel: one-pole gain smoothing and a soft limiter. No allocation, no locks.
  MezclaBridgeShared/ The private socket shared by the app and its bridge. Foundation only.
  MezclaBridge/       Native messaging host (mezcla-bridge): relays stdin/stdout to the socket and back.
  MezclaSafariExtension/ Native half of the Safari web extension (sandboxed .appex inside Mezcla.app).
  MezclaCore/         Swift, no UI.
    CoreAudio/        Typed property access, devices, processes, listeners that clean up after themselves.
    Tap/              ProcessTap: tap, aggregate device and IOProc as one resource, rolled back on partial failure.
    Identity/         Which app an audio process belongs to (pure rules plus system facts).
    Engine/           TapPlanner (a pure function) and MixerEngine (the actor that applies its plan).
    Browser/          BrowserBridge (the actor that serves the socket) and BrowserTab.
    Domain/           Value types: AppID, AppVolume, MixerSnapshot, PlaybackActivity, and so on.
    Permissions/      Capture permission status and request.
  Mezcla/             The menu bar app.
    App/              Entry point, composition root, NSStatusItem and NSPanel, setup guide.
    Presentation/     MixerViewModel (@Observable, @MainActor), behind MixerControlling and BrowserBridging.
    Services/         Persistence, login item, icons and browser integration, behind protocols.
    Views/            SwiftUI rows, header and footer, sharing their metrics through PanelStyle.
    Diagnostics/      --selftest, --preview and the demo environment.
BrowserExtension/     Manifest V3 extension; its ID is fixed by the public key in the manifest.
SafariExtension/      Safari's manifest and background page; page scripts are shared with BrowserExtension/.
Tests/MezclaCoreTests/ Planner, identity, activity and volume curve; the C IOProc driven with synthetic
                       buffers; and BrowserBridge over a real socket.
```

Design decisions:

- **One-way data flow.** The UI sends commands through `AsyncStream`s, which keep them in order. The engine
  and the bridge publish snapshots only when something changed.
- **Plan, then execute.** `TapPlanner` takes the current state and returns actions without touching Core Audio
  or clocks, so every rule is tested without hardware.
- **Actors on their own queues.** `MixerEngine` and `BrowserBridge` each run on a `DispatchSerialQueue` that
  also receives their Core Audio notifications or socket events. Callbacks arrive already isolated, so there
  are no locks, under Swift 6 strict concurrency.
- **No polling.** Everything reacts to notifications. When nothing changes, Mezcla does no work.
- **Its own panel instead of `MenuBarExtra`.** `MenuBarExtra` resizes its window around the bottom edge, so
  the panel drifted away from the menu bar when its content changed. `MenuBarPanel` keeps the top edge fixed
  and animates height changes. `StatusItemController` dismisses it like a menu: click outside, press Esc, or
  switch app or Space. Right-click the icon to quit.
- **Minimal re-rendering.** Each row receives its volume as a value, so dragging a slider redraws only that row.

Policies that keep it light:

| Situation | What Mezcla does |
|---|---|
| App at 100 % | Nothing: no tap, no CPU, untouched audio. |
| Custom volume, app silent | The tap is ready but stopped, and starts the moment the app plays. |
| Silent for 15 s | Stops the IOProc so the output device can sleep. |
| Slider back at 100 % | Keeps the tap at unity for 3 s, so dragging through 100 % doesn't rebuild it. |
| Output change, sleep, new helper process | Rebuilds or updates only what changed. |

Measured on a MacBook Pro (macOS 27): 13–17 MB of memory and 0.0 % CPU when idle, and 0.0 % CPU while
processing audio. A −12 dBFS tone with the slider at 25 % measures −35.7 to −36.1 dBFS at the output (expected:
−36.1). The small spread comes from the drift compensation macOS applies to the tap; Mezcla's own gain is
exact, as the kernel tests verify.

## Known limits

- Audio that Mezcla processes is mixed to stereo, so an app with a custom volume loses spatial audio and Dolby
  Atmos. At 100 % it is untouched.
- Per-tab volume covers Chromium browsers. Safari needs a Safari Web Extension inside an Xcode app target, and
  Firefox needs an add-on signed by Mozilla, which is a possible follow-up. Boosting a tab above 100 % works for
  sources Web Audio may read (same-origin, blob streams such as YouTube or Twitch, calls); cross-origin plain
  files stay at 100 %.
- Safari only loads an ad-hoc-signed extension with Develop › Allow Unsigned Extensions, which Safari resets
  when it quits. A Developer ID signature removes that step.
- Some AirPlay outputs refuse aggregate devices. The row shows a warning and the app keeps playing normally.
- With ad-hoc signing (no developer account), macOS asks for the audio permission again after every build.
- Two private system functions are resolved at runtime, each with a fallback: TCC, to read the capture
  permission, and `responsibility_get_pid_responsible_for_pid`, to group helper processes.
