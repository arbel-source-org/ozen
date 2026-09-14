# Ozen ("ear" in Hebrew)

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
  so a person's turns are labeled by name. Unnamed voices are numbered from
  1 in each conversation, so a phone listening all week doesn't reach
  "speaker 140".
- **Two swappable on-device engines** — [WhisperKit](https://github.com/argmaxinc/WhisperKit)
  (Whisper via CoreML) and Apple's own on-device Speech framework — picked
  in Settings, since which one is actually better for Hebrew on a given
  device is an open, testable question rather than an assumption.
- **Nothing leaves the phone.** No server, no account, no API key. (The one
  exception is an explicit, off-by-default switch to let Apple's recognizer
  use Apple's servers when iOS has no on-device Hebrew model.)
- **A status control that always says what's happening** — asking for the
  microphone, downloading the model (with a percentage and the time left
  at its current pace), loading it,
  listening, paused, or exactly what failed and what to do about it
  (retry, open Settings, switch engine). First-launch model download is the
  slowest thing the app ever does and is never silent.
- **Whisper model manager**: nine model sizes from 76 MB to 3 GB with
  honest Hebrew-quality and speed ratings, download progress, disk usage,
  and delete. "Turbo (compressed)" (626 MB) is the recommended pick.
- **Display built for reading all evening**: text size 20–64 pt (pinch
  the captions to change it), white-on-black / yellow-on-black /
  black-on-white, bold, speaker names on/off (shown once at the start of
  each person's turn, like a chat), a small question mark on lines the
  engine itself was unsure of (so she knows when to ask again), numbers
  (the time of an appointment, how many pills, a phone number) in a
  heavier weight and a second colour, whether written in digits or in
  words ("and six" (u-ve-shesh), "three pills" (shlosha kadurim)), long
  stretches of speech
  broken into short paragraphs at sentence ends, screen stays awake while
  listening (and locks as usual after a quarter hour with nothing said, while
  captions and alerts carry on), auto-scroll that stops when you scroll up to re-read (with a
  "back to latest" pill). With VoiceOver on, each finished line is read
  out or sent to a braille display by itself, once, with the speaker's
  name when the speaker changes. Doorbell, alarm and name alerts are
  read out the moment they happen.
- **Robust audio**: a live level meter per microphone, automatic recovery
  from phone-call interruptions and route changes (AirPods in/out, USB mic
  unplugged), Whisper-hallucination filtering on silence, no model runs on
  pure silence at all.
- **Recovers by itself.** A recognizer that drops out mid-conversation,
  an audio session that fails, or a model download that hit a dead Wi-Fi
  is retried automatically with growing delays, and the status line says
  so. Failures only a person can fix (a denied permission) never are.
  Retries wait out a phone call instead of burning attempts during it.
  A microphone that silently stops delivering audio (a Bluetooth hearing
  aid reconnecting, say) is noticed within seconds and restarted, instead
  of the screen saying "listening" over captions that never come.
- **Downloads that can't get stuck.** A cut-off model download is told
  apart from a whole model and simply continues from where it stopped,
  instead of failing to load on every launch.
- **Downloads that don't eat the data plan.** On cellular or in Low Data
  Mode a model waits for Wi-Fi, says how big it is, and starts by itself
  when Wi-Fi arrives. "Download now" asks first; a setting allows it
  always.
- **Downloads that fit.** Free space is checked before a model download
  starts, with room left for the first load. A phone that's too full says
  how much to free (or to pick a smaller model), is never retried on a
  timer, and starts the download by itself when she comes back to the app
  with enough room. The model list marks the models that won't fit.
- **Type to speak.** The other half of a conversation: type a reply, or
  tap one of the ready-made phrases ("Wait, I didn't understand" (rega, lo
  hevanti), "Can you repeat that?" (efshar lachzor al ze?)), and the phone
  says it in Hebrew. The last typed sentence stays under the field, to say
  again when it wasn't caught or keep as a ready-made phrase in one tap.
  Captions pause while the phone
  talks, so it doesn't caption itself, and come back on their own. A
  full-screen pad in huge letters lets someone type to her where captions
  can't keep up, or turns what she typed upside down for the person facing
  her to read. "Write to me" (kitvu li) opens it straight from Siri or the Action button.
- **Names and words list.** Family names, the doctor, the medicines.
  Both engines are primed with the list (Apple's recognizer via
  contextual strings, Whisper via a decoder prompt), edits apply from the
  next sentence, and Whisper output that is just the list read back is
  dropped.
- **Keyword alerts.** Her name, or any word she picks, buzzes the phone
  and highlights the line, matching through Hebrew's attached prefixes
  ("ve-le-Ruti" still matches "Ruti"). Said over and over at the table, it
  buzzes at most once every 15 seconds, while every line it's in stays
  highlighted.
- **Sound alerts.** Doorbell, knocking, a baby crying, a smoke alarm, a
  civil-defence siren and about 45 more, recognized on the phone by
  Apple's sound classifier and shown as a banner, with per-sound muting.
  Sirens and alarms flash the edge of the whole screen for a few seconds,
  the doorbell and a crying baby twice, so they're caught from the corner
  of the eye (slower than any seizure risk, and a steady glow with Reduce
  Motion on). The phone vibrates differently for each, so they can be told
  apart in a pocket: long buzzes for an alarm, a double knock for the door,
  three quick taps for her name. The banner and flash also show over
  whatever screen is open, such as the keyboard for typing a reply. A
  lesser sound heard meanwhile (a kettle during a smoke alarm) still buzzes
  but doesn't take the alarm's banner or flash away.
- **Alerts reach her with the screen off.** With the phone in a pocket or
  locked, a sound alert or her name becomes a phone notification (once per
  30 seconds per sound or word), so the doorbell isn't missed just because
  nobody was looking at the app. If captions stop there and nothing will
  bring them back (a call ends but iOS keeps the microphone, or recovery
  gave up), the app first tries to take the microphone back by itself, and
  otherwise sends one notification saying so, removed again once captions
  are back. (iOS may suspend a locked app for the length of a call; then
  this runs whenever iOS next lets the app run.)
- **Battery warnings** at 20% and 10% while captions run, because hours of
  listening drain the phone and nobody following a conversation watches
  the battery icon. With the phone in a pocket they arrive as a
  notification, since a phone that switches off takes the alerts with it.
- **Warns before the install runs out.** Installed with a free Apple ID,
  the app stops opening after seven days without a word. It reads its own
  provisioning profile, says on the caption screen two days ahead when that
  will happen ("Ozen will stop opening tomorrow at 07:24" (Ozen tafsik
  lehipatach machar be-sha'a 07:24)), and sends a reminder
  notification the day before, in daytime.
- **Keeps its cool.** Whisper refreshes the in-progress line less often
  when the phone runs hot or Low Power Mode is on, instead of throttling
  and falling behind; the careful end-of-sentence pass is never skipped.
- **Conversation history.** Conversations are saved as they happen,
  searchable, shareable as text (a long one opens with its lines that had
  numbers in them), can be given a name ("Visit to the doctor" (bikur etzel
  harofe)), list who took part, and open with a summary: length, how much
  each person said, speaking pace, longest turn, and every line with a
  time, an amount or a phone number in it, each a tap from where it was
  said.
  The list reads a small summary per conversation, so it opens quickly
  even after months of daily use, and autosaving never stutters the
  captions. Old conversations can delete themselves after a week, a
  month, three months or a year (off by default); starred or named ones
  are always kept, and a change that would delete something asks first.
  If the phone fills up and saving starts failing, the caption screen says
  so, instead of conversations quietly going unsaved.
- **Nothing lost when iOS closes the app.** A speech model is one of the
  biggest things in a phone's memory, so iOS may end the app in the
  background mid-conversation. Coming back, the empty screen offers the
  conversation from a few minutes ago, one tap away. When iOS warns it is
  short of memory and captions are off, the app lets go of the loaded
  model first, so it is less likely to be the app iOS ends.
- **Captions on the lock screen.** While captions run, the newest two
  lines show on the lock screen and in the Dynamic Island as a Live
  Activity, the top line always saying who is talking, so the last sentence can
  be read without unlocking the phone. A call or a failure keeps it there
  and says why the lines stopped; if iOS closes the app it says the lines
  aren't updating rather than showing an old sentence as new, and after a
  quiet minute it says how long ago the last line was said. Settings can
  turn it off, since anyone looking at the phone can read it.
- **Picks up where she stopped reading.** Captions carry on with the phone
  locked or another app open; coming back, a line across the captions marks
  where the ones she missed begin, with how many there are, and a button at
  the top jumps up to it ("What was said meanwhile" (ma she-ne'emar
  beinta'yim)). A glance away of a few seconds doesn't move the mark.
  After five minutes or more with nothing said, the time the talking
  started again is drawn between the lines, so an old sentence isn't read
  as the one just before.
- **Star what matters.** Hold a caption line to mark it as important
  (what the doctor said about the pills), copy it, or say who is talking.
  Stars are saved with the conversation, counted in the history list,
  marked in shared text, and one button steps through them later. One
  list gathers every starred line from every conversation, and can be
  shared as text. A search result opens at the lines it found,
  highlighted.
- **Saved speakers can be renamed**, and the new name follows onto lines
  already on screen and into the names list.
- **First-launch walkthrough** in large type that explains the engines and
  the one-time model download before it happens, asks for the
  microphone with a reason, and asks for her name (with "Grandma" (savta) one tap
  away), so the name alert works from the first conversation instead of
  waiting for someone to find it in Settings. A phone set up before that
  page existed gets the same question as a card on the empty caption
  screen, until a word is added or it's turned down.
- **Siri and Shortcuts.** "Hey Siri, start captions in Ozen" (hey Siri,
  hatchel ktuviyot be-Ozen), "Stop captions" (atzor ktuviyot),
  and "Say in Ozen ..." (tagid be-Ozen ...) to have the phone say something aloud.
- **A start button in Control Center** (iOS 18): "Start captions" (hatchalat
  ktuviyot) opens Ozen and starts listening in one press. It can also
  replace the flashlight or camera button at the bottom of the lock screen.
- **Diagnostics screen** with every pipeline counter (audio chunks, tokens,
  caption lag, restarts, speaker clusters), free space, memory use, a
  timeline of the last failures, retries, microphone stalls, phone calls
  and low-memory warnings with clock times, and one-tap copy of all of it
  for asking for help.

## Repo layout

```
Package.swift          OzenKit: platform-independent core logic
Sources/OzenKit/        (builds + tests on Linux — no Mac needed for this half)
Sources/OzenPlatform/  WhisperKit/Speech/AVFoundation/Accelerate integration
                        (Apple-only; built and tested via CI's macOS runner)
Tests/                  Unit tests for both of the above
App/Ozen/               The SwiftUI app itself (generated via XcodeGen)
App/OzenWidget/         Widget extension: lock screen captions, Control Center button
App/Shared/             Code compiled into both the app and the widget extension
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

When she calls with a problem, [docs/troubleshooting.md](docs/troubleshooting.md)
says what every status message means and what to do about it, and how to
get the diagnostics report sent over.

## Status

The whole pipeline — permission, session, input listing, engine
preparation with progress, capture, tokens → segments, speaker clustering,
engine hot-swap, pause/resume, automatic recovery, every failure path —
lives in `OzenKit` as `CaptionPipeline` and is unit tested on Linux
against fakes, along with the alert matching, history, statistics,
vocabulary, model-download, recovery, battery, notification and layout
logic (442 tests). The platform layer (WhisperKit/Speech engines, real
audio capture, the speaker embedder) and the app's view model are built
and tested on CI's iOS Simulator, with the view model driven end to end by
the same fakes (another 77 tests).
The app installs and launches on a real iPhone 15 Pro Max. Actual Hebrew
transcription quality, external-mic behaviour and speaker separation in a
real room are being verified by hand — see the design doc's checklist.

## License

MIT — see [LICENSE](LICENSE).

Made by Arbel.
