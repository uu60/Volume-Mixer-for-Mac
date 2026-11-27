# Volume Mixer

A native macOS 14.2+ menu bar app that controls each audio-producing process without installing an audio driver.

## How it works

- A process at 100% stays on the normal Core Audio path. No tap or aggregate device exists for it.
- Moving a process below 100% creates a private `CATapDescription` with `.muted` behavior, attaches it to a private aggregate device, applies gain in a real-time IO callback, and sends it to the selected physical output.
- Returning the slider to 100% stops the IO callback and destroys both the aggregate device and process tap.
- Gain changes use an atomic target and per-sample smoothing in a tiny C helper, so the audio callback takes no Swift lock and allocates no memory.
- Volumes and the last nonzero value are stored by bundle identifier. A remembered value is restored when the app appears again.
- The top slider controls the selected device's native volume when available. Otherwise, it scales the tapped app audio in software and remembers that level per output device. The output list changes macOS's default output.
- Output rows use each device's Core Audio icon when available, with a device-type symbol for devices that do not publish one.
- AirPlay outputs published by Core Audio appear in the output list. Nearby receivers that macOS has not exposed as output devices must first be connected in macOS Sound settings.

## Requirements

- macOS 14.2 or later
- Xcode 15.1 or later (the project was compile-checked with Xcode 27.2 / macOS 27.2 SDK)
- No third-party dependencies, virtual audio driver, system extension, or installer

## Build and run

1. Open `VolumeMixer.xcodeproj` in Xcode.
2. Select the **VolumeMixer** scheme and **My Mac** destination.
3. If Xcode requests it, choose your development team under **Signing & Capabilities**. For a local ad-hoc build, signing can also be disabled from the command line.
4. Build and run.
5. The app appears only in the menu bar. Left-click its speaker icon for system volume, output selection, and app volumes. Right-click it to quit.
   While the panel is open, the Apps list checks for changes four times per second; checks stop when it closes. The refresh button remains available.
6. The first time a slider goes below 100%, macOS asks for **System Audio Recording** permission. Grant it in System Settings if requested, then retry the slider.

Command-line build:

```sh
xcodebuild \
  -project VolumeMixer.xcodeproj \
  -scheme VolumeMixer \
  -configuration Debug \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

The `AppIcon` asset catalog is included in the target, so Xcode adds the icon to packaged `Volume Mixer.app` automatically. To regenerate its sizes from the system speaker symbol, run `swift Tools/GenerateAppIcon.swift VolumeMixer/Assets.xcassets/AppIcon.appiconset` from this directory.

## Notes and limitations

- This is a minimal, native implementation intended for normal stereo output devices. Core Audio supplies Float32 buffers at the aggregate device's client side; unusual multi-stream/pro-audio devices should be tested before relying on them.
- macOS owns its built-in Sound menu item. To use this app in its place, hide the built-in Sound item in macOS Control Center settings; the app cannot remove Apple's menu item itself.
- Bluetooth reconnects, sample-rate changes, and device disappearance can invalidate a Core Audio graph. The controller rebuilds active taps whenever the default output device changes.
- Audio process objects from the same app are grouped into one row, and that row controls all currently active objects for the app. Helpers inside an app bundle use the enclosing app's name and icon.
- The project includes `NSAudioCaptureUsageDescription`, which Apple requires for Core Audio taps.
- Compilation verifies API names, availability, Swift/C bridging, and linkage. It does not replace listening tests on each target Mac, output device, or macOS release.

## Privacy

Audio stays in the real-time Core Audio callback. The app does not write, retain, analyze, or transmit captured samples.
