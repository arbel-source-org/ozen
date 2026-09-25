# Hyperframes Composition Brief: Ozen

## Objective
Create a short launch-style brag video for Ozen (אוזן): a Hebrew-first iPhone app for live, on-device captions of conversation, built for one grandmother with hearing loss.

## Output
- Composition directory: `brag-output/composition/`
- Rendered video: `brag-output/brag.mp4`
- Format: landscape — 1920x1080
- Duration: 22.9 seconds

## Source Material
- Project root: `/home/shrekinton/Projects/ozen`
- Primary files read: `README.md`, `App/Ozen/Views/{LiveCaptionView,CaptionScreenParts,CaptionTheme,SpeakerColor,PhasePresentation,OnboardingView,GlassStyle,NumberEmphasisText}.swift`, `Sources/OzenKit/{CaptionPipeline (seedForScreenshots),SoundEvents,AlertFlash,AlertVibration,NumberEmphasis,AppSettings}.swift`, `App/Ozen/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png`
- Product name: Ozen · אוזן ("ear")
- Tagline / strongest claim: "Live captions for conversation." (first onboarding page). Punchline: "בהצלחה, סבתא." / "Good luck, Grandma." (last onboarding page).
- Key UI or visual moment to recreate: the live caption screen: black background, caption rows with speaker name + colored dot, dim pending text locking to white, heavy yellow numbers, keyword line with yellow field + bell, doorbell banner, edge flash, glass control bar with the green "מקשיב" status.
- Copy that must appear verbatim (all from the app):
  - `בוקר טוב, איך ישנת הלילה?` — speaker **דנה** (amber `#FABF2E`)
  - `די טוב, תודה. יש לי תור לרופא ב-10:30 ואני צריכה לקחת שני כדורים לפני.` — speaker **דובר 1** (sky `#73C7FA`); `10:30` and `שני כדורים` in heavy `#FFE033`
  - `אני יכולה לקחת אותך, אין בעיה.` — דנה
  - `עוד לא ברור לי אם` — דובר 1, still pending (dim)
  - keyword pill: `דובר 1 — נאמר: שני כדורים`
  - alert banner: `פעמון דלת` / `נשמע עכשיו`
  - status control: `מקשיב` / `הקישו להשהיה`; bottom buttons `מיקרופון`, `להגיד`, `הגדרות`
  - `Live captions for conversation.`
  - `בהצלחה, סבתא.` / `Good luck, Grandma.`
  - `github.com/arbelonson-source/ozen`
- Facts verified from the repo (shown as numbers): 485 commits, 6 distinct commit days (2026-09-13 → 2026-09-18), developed on Linux with no Mac.

## Creative Direction
- Tone preset: polished
- Creative direction: a quiet, warm product film; a love letter disguised as a launch video, with one deadpan pitch-deck joke as the hook.
- Interpretation: restraint. Slow blur-crossfades, long holds, no exit animations except the last scene, one accent hue (icon amber), third-person copy, humor only in the opening TAM slide. Every line of narrative text behaves like an Ozen caption: words arrive one at a time dim (62% white), then the line locks to full white; numbers go heavy + `#FFE033` when it locks.
- Angle: Launch videos brag about user counts. This one brags about having one user. It opens like a pitch deck ("Total addressable market: 1 grandmother.") and then plays it straight as a premium film for an app whose entire market is Grandma. The engineering is the brag (speaker ID, Hebrew-tuned Whisper, sound alerts, 485 commits in six days, no Mac); who it's for is the punchline, in the app's own words.
- Hook: navy field; green "Listening" chip breathing top-left; "Total addressable market:" arrives caption-style, then "1 grandmother." huge, the 1 turning yellow on lock; concentric rings `TAM = 1 / SAM = 1 / SOM = 1` around one amber dot at right.
- Outro / punchline: "בהצלחה, סבתא." locks white, "Good luck, Grandma." beneath, attribution "the last line of Ozen's first-run setup", then the end card (icon, Ozen, github URL) on the strongest cue. Hold on it.
- Avoid:
  - Generic SaaS language
  - Abstract filler visuals (the rings must read as market diagram → sound ripples → halo; no other decoration)
  - Redesigning the app UI: the phone must look like the real app (black, right-to-left Hebrew captions, glass bar)
  - Equalizer/waveform visuals; per-word typing ticks; whooshes
  - Claiming anything not in the repo (no user numbers, no App Store availability)

## Visual Identity
- Background: field `radial-gradient(#17384D → #0B2230)` from the icon (draw as a radial or solid + localized glow, not a full-screen linear gradient); phone screen `#000000`
- Text: `#FFFFFF`; pending `rgba(255,255,255,0.62)`; captions' secondary/gloss `rgba(255,255,255,0.62)`
- Accent: `#FFCA28` (icon ear), `#FAA700` (icon inner), number emphasis `#FFE033`
- Product colors: speaker amber `#FABF2E`, speaker sky `#73C7FA`, listening green `#30D158`, doorbell banner `#B34D00` at 0.92 with orange `#FF9F0A` edge flash, keyword field `rgba(255,224,51,0.22)`
- Display font: Frank Ruhl Libre (serif; Hebrew + Latin). Weights 400 / 900 for extreme contrast.
- Body/UI font: Heebo (sans; Hebrew + Latin), 300 / 400 / 800. Used for everything inside the phone and for emphasized numbers.
- Metadata: JetBrains Mono (bundled; 400/700) for kickers, glosses, the terminal receipt.
- Visual references from the project: `AppIcon-1024.png` (copy into `assets/`), `CaptionRow`, `PhasePresentation` status chip, `SoundAlertBanner`, `AlertFlashOverlay`, glass control bar.
- Fonts are not in the bundled set: embed local woff2 via `@font-face` (files in `assets/fonts/`).

## Storyboard
Use the storyboard in `brag-output/brag-plan.md` as the creative contract.

Scene summary:
1. The market — 3.81s — "Total addressable market:" / "1 grandmother." + rings TAM=SAM=SOM=1 around an amber dot; green Listening chip
2. The ear — 2.74s — dot becomes the app icon; rings ripple; "Ozen · אוזן", "Live captions for conversation."
3. The table — 8.73s — phone mockup running the app's screenshot conversation; four behaviours annotated in order: knows who's talking, numbers stand out, buzzes on her words (3 taps), hears the doorbell (banner + edge flash ×2)
4. The effort — 3.28s — "485 commits." "6 days." "No Mac." + terminal receipt
5. The dedication — 4.34s — "בהצלחה, סבתא." / "Good luck, Grandma." + end card on the strongest cue; hold

## Audio
- Audio role: warm bed with sparse professional accents
- Audio arc: fades in under the dry joke; settles into its groove as the phone appears; product sounds (thud, three taps, doorbell) are the only accents; strongest beat lands on the end card; fades out under it.
- Music: `happy-beats-business-moves-vol-12-by-ende-dot-app.mp3` (in `assets/music/`)
- Music treatment: `data-media-start` 2.19 (on a beat) so source 8.74s → composition 6.55s. Volume 0.5 with a 0.5s fade-in, ducked to 0.36 under the doorbell, fade-out over the last 1.5s, implemented with a `data-automation` volume lane. First render measured -26 LUFS (too quiet), so the bed was raised and SFX lowered; delivery master is -16 LUFS.
- Music cue guidance: bundled preset, 109.96 BPM. Strong cues at composition times 6.55, 10.92, 15.28, 20.74 (source 8.74, 13.11, 17.47, 22.93 minus the 2.19 offset). Beat grid for the "485 / 6 / No Mac" lines: 15.83, 16.37, 16.91. Mark `// beat-locked:` and `// beat-grid:` in the timeline. Ignore cues wherever they would hurt readability.
- Audio-reactive treatment: subtle; extract bass + RMS from the music with `extract-audio-data.py`; drive the navy glow intensity and ring-system scale (≤3%) only. No waveform/equalizer. Do not touch text.
- Audio-coupled moments:
  - Scene 2 icon lands — one soft thud
  - Scene 3 keyword hit — three quick soft taps at +0 / +0.14 / +0.28s (matches the app's `AlertVibration.keyword`)
  - Scene 3 doorbell — a two-note ding-dong one beat apart as the banner drops
  - Scene 5 end card — one soft hit on the 20.74s cue
- SFX selection guidance: soft, low-HF-risk files; nothing louder than the bed's peaks; volumes 0.5–0.7; no SFX on transitions or on typing.
- SFX analysis guidance: `~/.claude/plugins/cache/brag/brag/0.2.2/skills/brag/assets/sfx/sfx-analysis.md`
- Exact SFX choice: Hyperframes chooses filenames, timestamps, and volumes after the animation exists.
- Audio files: copy the chosen music and SFX into `brag-output/composition/assets/`.

## Hyperframes Instructions
Use the Hyperframes domain skills (`hyperframes-core`, `hyperframes-animation`, `hyperframes-creative`, `hyperframes-keyframes`, `hyperframes-cli`); do not enter the generic promo workflow. Prefer native Hyperframes conventions.

Requirements:
- Show real UI/copy from Ozen (the phone scene uses the app's own strings verbatim).
- Keep all text readable; reading-time floor: short label ~0.8s settled, sentences ~0.3s/word.
- Keep the video 15–25s (22.9s).
- Include the planned music/SFX layer.
- Beat-lock 1–3 major moments to strong cues (6.55, 15.28, 20.74) within ±0.15s; beat-grid the three effort lines within ±0.10s.
- Run `npx hyperframes check` and fix everything it reports before render.
