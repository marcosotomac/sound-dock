# Contributing to Mezcla

Thanks for helping. Mezcla aims to stay small, native and quiet: no polling, no audio drivers, nothing running
when nothing changes. Changes that keep it that way are the easiest to merge.

## Getting started

```sh
swift test                        # 65 tests, no audio hardware needed
scripts/build-app.sh --install    # build, install to /Applications and relaunch
```

Requires macOS 14.2 or later and a recent Xcode. The app needs the **System Audio Recording** permission. If
you rebuild often, create a self-signed code-signing certificate named “Mezcla Local Signing” in Keychain
Access: `build-app.sh` uses it automatically, and macOS then keeps the permission across builds.

Useful while working:

```sh
build/Mezcla.app/Contents/MacOS/Mezcla --preview demo dark    # the panel with sample data, for UI work
build/Mezcla.app/Contents/MacOS/Mezcla --selftest spotify 150 # a real tap at 150 %, with the measured peak
log stream --level debug --predicate 'subsystem == "dev.mezcla"'
```

## Guidelines

- **Real-time code** (`Sources/MezclaDSP`) never allocates, locks or calls into Swift or Objective-C. Cover
  changes with a test in `GainKernelTests` that drives the IOProc with synthetic buffers.
- **Decisions are pure.** New rules about when to tap, route or duck belong in `TapPlanner` and get a test.
- **UI** follows the system: SF Symbols, system fonts, light and dark mode, VoiceOver labels. Shared metrics
  live in `PanelStyle`.
- **Browser extension** changes must work in Safari and Chromium. Bump the version in both manifests.
- Commits follow [Conventional Commits](https://www.conventionalcommits.org): `feat:`, `fix:`, `docs:`,
  `refactor:`, `perf:`, `test:`, `chore:`.

## Reporting problems

Use the issue templates. For audio problems, the output of `Mezcla --selftest` helps a lot. Security issues go
through [private vulnerability reporting](https://github.com/marcosotomac/sound-dock/security/advisories/new).
