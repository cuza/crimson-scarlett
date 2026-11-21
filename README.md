# Crimson

A macOS control panel for the Focusrite Scarlett 1st Gen 6i6, 8i6, 18i6, 18i8 and 18i20.

Scarlett MixControl doesn't recognize these interfaces on macOS Tahoe 26 and later. Audio still works, but nothing can set the routing, mixer or input switches. Crimson does.

## Install

Download the DMG from [Releases](../../releases) and drag Crimson to Applications. It needs macOS 14 or later.

## What it does

- **Overview.** Line or instrument, pad, hi gain, output volume and mute, clock source, input levels.
- **Routing.** Choose what each output, recording channel and mixer input plays. Drag lines or pick from a list.
- **Mixer.** Stereo mixes with level, pan, mute, solo and live meters. Link inputs into stereo pairs, rename them, hide the ones you don't use.
- **Save to device.** Stores the setup on the interface, so it starts that way with no computer attached.
- **Read from Device.** Loads the interface's current setup into the app.
- **Presets.** Save and load setups as JSON files.

Crimson writes to the interface only when you change something. Opening the app or connecting the interface sends nothing.

## Limits

The 1st Gen firmware reports its clock, input switches, output volume and mute, and mixer input sources. It doesn't report mix levels or routing.

- Read from Device measures mix levels. It mutes the outputs, plays a quiet tone through each mixer input, reads the meters, then restores everything.
- Routing can't be read or measured. Crimson's copy is the only record of it.

## Supported models

| Model | Status |
|---|---|
| 18i8 | Tested on hardware |
| 6i6, 8i6, 18i6, 18i20 | Built from the Linux driver's tables, untested |

If you own an untested model, please open an issue with what works and what doesn't.

## Building

You need Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
swift test
xcodegen && open Crimson.xcodeproj
```

To sign your build, set `DEVELOPMENT_TEAM` in `project.yml` to your team ID.

`swift run scarlett-probe status` prints the attached interface's model and clock lock. `swift run scarlett-probe meters` prints its meters.

## License

MIT. See [LICENSE](LICENSE).

Focusrite, Scarlett and MixControl are trademarks of Focusrite Audio Engineering Ltd. Crimson is an independent project. Focusrite doesn't make, endorse or support it.
