# Ozen — transcription quality, September 2026

## Problem

The owner's report on build 20: "right now it doesn't work well." The
grandmother has not used the app yet and no visit is possible for a while,
so the only thing that can be improved without her is what can be
measured: how many Hebrew words the phone gets wrong, on real recordings,
before anything ships.

## What was measured

A harness (kept outside the repo, `hebrew_wer.py` in the session's
scratchpad; the method is what matters) transcribes 90 Hebrew clips the
way the app decodes — greedy, language forced to Hebrew, one utterance per
pass, no conditioning on earlier text — with `faster-whisper` on this
machine's CPU, and scores words wrong after stripping punctuation and
vowel points:

- 60 clips (9 min) from Google's FLEURS Hebrew test set: read Wikipedia
  sentences, studio-clean, held out from every model here.
- 30 clips (3.6 min) from `imvladikon/hebrew_speech_campus`: recorded
  university lectures, conversational and less clean.

| Model | Lectures | Read sentences |
| --- | --- | --- |
| Small (the default until this build) | 27.0% | 47.9% |
| Turbo, OpenAI (the recommended pick until this build) | 9.7% | 31.3% |
| Large v3, OpenAI | 20.4% | 28.1% |
| **Turbo, ivrit.ai Hebrew training** | **6.6%** | **21.1%** |

Two decoding changes were tried on both Turbos and rejected: retrying at
higher temperature when a pass looks bad changed nothing (no pass looked
bad on these clips), and priming the decoder with a Hebrew sentence made
lectures worse (8.1%) for a negligible gain on read sentences.

WhisperKit stops a pass with no text when the first token's
log-probability is under -1.5, and falls back to sampling when the mean
is under -1.0. Measured on the Hebrew-trained model over the same clips,
the first token's median is -0.02 and the mean's -0.03; no clip came
near either threshold. The thresholds stay.

## Decisions

1. **The Hebrew-trained Turbo is the recommended model and the default
   for a fresh install.** Small was the default; nobody should land on a
   model that gets most words wrong without choosing it.
2. **A phone already set up is offered the switch, not switched.** On the
   empty caption screen, while the recommended model is clearly better
   than the one in use (a higher Hebrew rating in the catalog) and would
   fit on the phone, a card offers it: one tap picks it exactly as
   Settings would, download on Wi-Fi included; "not now" puts the card
   away for good. Switching silently would stop captions for an 819 MB
   download nobody asked for.
3. **The model is published as release assets of this repository.**
   WhisperKit's hub only carries OpenAI's Whisper, and the owner has no
   Hugging Face account. A `WhisperModelOption` can name a release tag as
   its source; the release holds the model's files flat, with a manifest
   giving each file's path, size and SHA-256.
4. **Conversion happens on Linux, compiling on the phone.** The
   conversion tool's verification and compile steps are macOS-only, so a
   script drives the same model classes and converter with those steps
   stubbed and saves uncompiled `.mlpackage` bundles; every weight is then
   palettized to 8 bits (uniform), 1.6 GB to 819 MB. The store compiles
   the packages with `MLModel.compileModel` after the download, once.
5. **A Mac checks every model release before the catalog points at it.**
   The `verify-model` workflow rebuilds the folder from the assets the
   way the phone does, compiles it with Apple's compiler, transcribes five
   FLEURS clips kept in the repo with WhisperKit's command line, and fails
   above a share of words wrong. Its first run produced correct Hebrew for
   the 8-bit model.

## Components

- `WhisperModelSource`, `WhisperModelOption.source` / `.folderName`,
  `WhisperModelCatalog.recommendedImproves(on:)` (OzenKit).
- `ReleaseModelManifest`, `ReleaseDownloadPlan`, `ReleaseModelDownloader`
  behind `ReleaseFileFetching` (OzenKit, tested with a fake fetcher:
  fresh download, resume from a cut-off file, a server that ignores the
  range, a checksum mismatch, a bad manifest).
- `URLSessionReleaseFileFetcher` (range requests, streamed to disk,
  CryptoKit SHA-256) and `WhisperModelStore.download` / `compilePackages`
  (OzenPlatform).
- `AppSettings.offersBetterModel` / `betterModelOfferDismissed`, the
  caption screen's card, `LiveCaptionViewModel.acceptBetterModelOffer`.
- `scripts/model-release/`: `manifest.py` (pack / unpack), `wer.py`, five
  clips, README; `.github/workflows/verify-model.yml`.

## Error handling

- A cut-off download continues per file; a file that arrived at full
  size but with the wrong checksum is deleted and reported, and the next
  attempt fetches it again. A manifest that could write outside the
  folder is refused before anything is written.
- A folder with packages but no compiled bundles reads as a partial
  download, so the engine downloads again (skipping whole files) and
  compiles.
- The existing gates apply unchanged: Wi-Fi wait, free-space check,
  retries with growing delays, the status line saying what is happening.

## Manual checks for build 21

- On a phone with build 20 and Turbo (compressed) or Small in use: the
  card appears on the empty caption screen; tapping it shows the download
  on the status button, then "loading", then captions with the Hebrew
  model; Settings → Whisper model shows it installed at about 819 MB
  actual; "not now" removes the card and it does not return.
- Fresh install: the walkthrough's "Accurate" is preselected and says
  819 MB; the first download and compile complete on Wi-Fi and captions
  run.
- Airplane mode in the middle of the download, then back online: the
  download continues and finishes; the diagnostics report shows one
  download, not two.
- A real conversation: fewer wrong words than build 20 by the owner's
  ear, and the live line still appears while someone is talking (the
  8-bit encoder is bigger than the mixed-precision Turbo's; if the phone
  falls behind, `InferenceCadence` slows the previews, and the catalog's
  speed rating should drop to 2).

## Not done, on purpose

- No mixed-precision (4/8-bit) recipe like Argmax's 626 MB Turbo: their
  recipe search needs Core ML predictions, which only run on macOS. Worth
  revisiting on the free macOS runner if 819 MB or its memory use proves
  a problem on the phone.
- No change to the utterance boundaries, the voice detector or the
  audio front end: nothing here can measure them without recordings from
  her table.
