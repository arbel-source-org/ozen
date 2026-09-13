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
- **Nothing leaves the phone.** No server, no account, no API key. (The one
  exception is an explicit, off-by-default switch to let Apple's recognizer
  use Apple's servers when iOS has no on-device Hebrew model.)
- **A status control that always says what's happening** — asking for the
  microphone, downloading the model (with a percentage), loading it,
  listening, paused, or exactly what failed and what to do about it
  (retry, open Settings, switch engine). First-launch model download is the
  slowest thing the app ever does and is never silent.
- **Whisper model manager**: nine model sizes from 76 MB to 3 GB with
  honest Hebrew-quality and speed ratings, download progress, disk usage,
  and delete. "Turbo (compressed)" (626 MB) is the recommended pick.
- **Display built for reading all evening**: text size 20–64 pt, white-on-
  black / yellow-on-black / black-on-white, bold, speaker names on/off,
  screen stays awake while listening, auto-scroll that stops when you
  scroll up to re-read (with a "back to latest" pill).
- **Robust audio**: a live level meter per microphone, automatic recovery
  from phone-call interruptions and route changes (AirPods in/out, USB mic
  unplugged), Whisper-hallucination filtering on silence, no model runs on
  pure silence at all.
- **Diagnostics screen** with every pipeline counter (audio chunks, tokens,
  caption lag, restarts, speaker clusters) and one-tap copy for asking for
  help.

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
only builds on iOS — `AVAudioSession` in particular doesn't exist on macOS
at all, so this half is built and tested by CI
(`.github/workflows/ci.yml`) against the iOS Simulator on GitHub's free
macOS runners, not a plain macOS build. To build it yourself on a Mac:

```bash
brew install xcodegen
xcodegen generate
xcodebuild -project Ozen.xcodeproj -scheme Ozen -destination "platform=iOS Simulator,name=iPhone 16" test
```

## Installing on a phone without a Mac

`.github/workflows/release.yml` builds an unsigned `Ozen.ipa` on GitHub's
macOS runners and attaches it to a release. Signing and installing it with
a free Apple ID from a Linux machine is documented step by step, including
the three things that were broken along the way, in
[docs/sideloading-from-linux.md](docs/sideloading-from-linux.md).

## Status

The whole pipeline — permission, session, input listing, engine
preparation with progress, capture, tokens → segments, speaker clustering,
engine hot-swap, pause/resume, every failure path — lives in `OzenKit` as
`CaptionPipeline` and is unit tested on Linux against fakes (90 tests).
The platform layer (WhisperKit/Speech engines, real audio capture, the
speaker embedder) compiles and its DSP is tested on CI's iOS Simulator.
The app installs and launches on a real iPhone 15 Pro Max. Actual Hebrew
transcription quality, external-mic behaviour and speaker separation in a
real room are being verified by hand — see the design doc's checklist.

## License

MIT — see [LICENSE](LICENSE).

Made by Arbel.
