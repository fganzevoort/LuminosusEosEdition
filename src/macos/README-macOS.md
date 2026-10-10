# Luminosus on current macOS

## What was wrong
Since macOS 10.14 an app must declare `NSMicrophoneUsageDescription` in its Info.plist
before it may read from *any* audio input (built-in mic, USB/Thunderbolt interfaces).
The 1.3.1 build doesn't have it and isn't code-signed, so macOS gives it silence or
terminates it when an audio block opens an input.

## What changed
| File | Change |
|---|---|
| `macos/Info.plist` | New bundle Info.plist with `NSMicrophoneUsageDescription` and `NSAudioCaptureUsageDescription`, proper bundle id. |
| `macos/luminosus.entitlements` | `com.apple.security.device.audio-input` (needed for hardened-runtime signing). |
| `macos/MacAudioPermissions.h/.mm` | Requests input permission at startup; creates a **System Audio (all apps)** input via a Core Audio process tap (macOS 14.2+). |
| `main.cpp` | Calls the above before the AudioEngine enumerates inputs; removes the tap on exit. |
| `luminosus.pro` | Uses the new Info.plist, adds the Objective-C++ file and AVFoundation. |
| `audio/AudioInputAnalyzer.cpp` | Also accepts 32-bit float samples (some CoreAudio devices return float). |
| `macos/build_macos.sh` | Build → macdeployqt → verify plist → sign → DMG. |
| `macos/patch_existing_app.sh` | Quick fix for the old 1.3.1 app without rebuilding. |

## Build
```bash
xcode-select --install
brew install qt@5
./src/macos/build_macos.sh
```
Result: `build-macos/luminosus.app` and a `.dmg`. With Homebrew's qt@5 this is a native
Apple Silicon build (the 1.3.1 DMG is an Intel-only Qt 5.15.2 build that runs under Rosetta).

## Using it
- **External sound card / mic:** on first start macOS asks for microphone access → Allow.
  In the Spectrum / Audio Level block settings, pick the interface channel.
- **QLab, Music, browser…:** choose input **System Audio (all apps) Left/Right**.
  The first time it starts, macOS asks for permission to record system audio → Allow.
  This captures everything other apps play, not one app in particular.
- Changed your mind? System Settings → Privacy & Security → Microphone (system-audio
  permission is also under Privacy & Security).
- Ad-hoc signed builds: after each rebuild macOS may ask for permission again.
- Devices are enumerated at startup: plug in the interface before launching Luminosus.
