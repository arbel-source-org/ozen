# Ozen (אוזן)

Live, on-device captions for conversation — built for a grandmother with
hearing loss who found every existing transcription app either unreliable
with external microphones or too shallow a feature to trust. Hebrew-first.

## Why this exists

Existing apps (evaluated: Nagish) had three concrete problems: inconsistent
handling of external microphones (no explicit input picker, a USB-C
lavalier mic didn't work at all, AirPods worked but not reliably), live
transcription treated as a minor feature rather than the point of the app,
and no real speaker detection. Ozen exists to fix specifically those three
things, for Hebrew conversation, entirely on-device.

## What it does

- **Live captions, not batch transcription.** Partial text updates
  continuously as speech happens; text only locks in (stops changing) once
  it's actually stable — see `CaptionStabilizer`.
- **Explicit microphone selection**, including external Bluetooth/wired/
  USB-C inputs, with automatic recovery when a preferred input reconnects
  mid-conversation.
- **Speaker detection**, always on, with optional one-time voice enrollment
  so a person's turns are labeled by name.
- **Two swappable on-device engines** — [WhisperKit](https://github.com/argmaxinc/WhisperKit)
  (Whisper via CoreML) and Apple's own on-device Speech framework — picked
  in Settings, since which one is actually better for Hebrew on a given
  device is an open, testable question rather than an assumption.
- **Nothing leaves the phone.** No server, no account, no API key.

## Repo layout

```
Package.swift          OzenKit: platform-independent core logic
Sources/OzenKit/        (builds + tests on Linux — no Mac needed for this half)
Sources/OzenPlatform/  WhisperKit/Speech/AVFoundation/Accelerate integration
                        (Apple-only; built and tested via CI's macOS runner)
Tests/                  Unit tests for both of the above
App/                    The SwiftUI app itself (generated via XcodeGen)
project.yml             XcodeGen config — run `xcodegen generate` to get Ozen.xcodeproj
docs/superpowers/specs/ Design doc with the full rationale and open questions
```

## Building

This was developed without access to a Mac. The portable core is built and
tested directly:

```bash
swift build && swift test
```

The full app (anything touching WhisperKit/Speech/AVFoundation/SwiftUI)
only builds on macOS/iOS and is built and tested by CI
(`.github/workflows/ci.yml`) on GitHub's free macOS runners. To build it
yourself on a Mac:

```bash
brew install xcodegen
xcodegen generate
xcodebuild -project Ozen.xcodeproj -scheme Ozen -destination "platform=iOS Simulator,name=iPhone 16" test
```

## Status

Core logic (caption stabilization, speaker clustering, mic-selection
policy, settings) is unit tested and green. The platform layer (WhisperKit/
Speech engines, real audio capture, the speaker embedder) is written but
has not yet been verified on real hardware — that needs an actual iPhone,
an actual external mic, and an actual Hebrew conversation, none of which
CI can provide. See the design doc's manual test checklist before trusting
this with something that matters.

## License

MIT — see [LICENSE](LICENSE).

Made by Arbel.
