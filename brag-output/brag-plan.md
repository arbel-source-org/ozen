# Brag Plan: Ozen (אוזן)

## Planning rubric (Step 1 answers)

1. **What is the app?** Ozen ("ear" in Hebrew) is an iPhone app that turns the conversation around a grandmother with hearing loss into live, on-device Hebrew captions: who is talking, the numbers that matter, her keywords, the doorbell.
2. **Most impressive claim?** It was built for exactly one user. The last line of the app's own first-run setup is "Good luck, Grandma." (בהצלחה, סבתא.). Runner-up: 485 commits in 6 days, "developed without access to a Mac."
3. **Visual hook?** Concentric rings. They open as a pitch-deck TAM/SAM/SOM diagram whose every ring equals 1, then become sound ripples around the app's amber ear icon, then the phone "listening."
4. **What to show from the actual UI?** The live caption screen (`LiveCaptionView` / `CaptionRow`): white-on-black Hebrew captions, dim while settling then locking to white, speaker labels with a colored dot, numbers in heavy yellow, the keyword line's yellow field + bell, the doorbell banner and the edge flash, the glass control bar saying "מקשיב" (Listening) in green.
5. **Shortest satisfying video?** ~23s. The demo needs ~9s to show four behaviours legibly; everything around it is short.
6. **Tone?** Preset `polished`; direction: *a quiet, warm product film: a love letter disguised as a launch video, opening with one dry pitch-deck joke.*
7. **Audio feel?** Warm, steady bed held low; a handful of soft, motion-matched sounds that are literally the product's alerts (three quick taps, a two-note doorbell).
8. **Share caption?** "Ozen has a total addressable market of one: Grandma. …" (see Share copy).
9. **User flow worth showing?** Phone on the table → speech becomes captions (dim → locked, speaker named, numbers emphasized) → her keyword buzzes the phone → the doorbell rings and the phone says so.

## What is this app?
Ozen is a Hebrew-first iPhone app that captions live conversation entirely on the phone, built for one grandmother with hearing loss after every existing caption app let her down.

## The angle
Launch videos brag about how many users they have. This one brags about having one.
The film opens like a pitch deck ("Total addressable market: 1 grandmother.") and then plays it completely straight: a premium product film for an app whose whole market is Grandma. The absurd amount of engineering (speaker ID, a Hebrew-tuned Whisper, ~50 sound alerts, 485 commits in six days, no Mac) is the brag; who it was all for is the punchline, delivered in the app's own words.

One motion idea carries the whole film: **every line of narrative text behaves like an Ozen caption.** Words arrive one at a time, dim ("still settling", the app's 62% pending white), then the line locks to full white. Numbers get the app's number emphasis (heavy, yellow `#FFE033`) the moment a line locks. By the time the phone appears, the viewer has already learned the product's visual grammar.

One shape carries it too: **concentric rings.** Market diagram → sound ripples around the ear → the phone listening → a halo behind the dedication.

## Hook (first 2-3 seconds)
Deep navy (the app icon's own background). Top-left, a small green "Listening" chip (the app's status control) is already breathing. Words arrive dim, caption-style, anchored left:

> Total addressable market:

then, huge, on the beat:

> **1** grandmother.

On the right, three concentric rings labelled `TAM = 1`, `SAM = 1`, `SOM = 1` around a single amber dot. When the line locks, the "1" turns yellow and heavy and the dot pops in.

## Key moments (the middle)
- **The dot becomes the ear.** The amber dot at the center of the market diagram swaps for the real app icon; the rings stop being a market chart and start rippling like sound. "Ozen · אוזן — Hebrew for 'ear'. Live captions for conversation."
- **The table.** A faithful phone mockup running the app's own screenshot conversation, verbatim:
  - דנה: "בוקר טוב, איך ישנת הלילה?" arrives word by word, dim, then locks. → *Knows who's talking.*
  - דובר 1: "די טוב, תודה. יש לי תור לרופא ב-10:30 ואני צריכה לקחת שני כדורים לפני." locks and `10:30` / `שני כדורים` turn yellow. → *Makes numbers stand out.*
  - The keyword hit: soft yellow field + bell on that line, the "נאמר: שני כדורים" pill, and the phone buzzes with the app's real pattern, three quick taps (0 / 0.14 / 0.28s). → *Buzzes on words she picks.*
  - The doorbell: deep-orange banner "פעמון דלת · נשמע עכשיו" drops in and the screen edge flashes twice, 0.4s on / 0.4s off, exactly as `AlertFlash` does for a doorbell. → *Hears the doorbell.*
- **The effort.** "485 commits. 6 days. No Mac." with a small terminal receipt beside it (`git rev-list --count HEAD` → 485, distinct commit days → 6, `uname -s` → Linux). Numbers in the app's emphasis yellow.

## Outro / punchline
The rings drift to center and become a halo. One caption arrives in Hebrew, dim, then locks:

> בהצלחה, סבתא.
> Good luck, Grandma.
> — the last line of Ozen's first-run setup

Then the app icon, "Ozen", and `github.com/arbelonson-source/ozen` land on the track's strongest cue. Hold. No fade to black: the end card is the poster.

## User flow worth showing
Entry → key action → result, all inside the phone mockup in Scene 3:
1. **Entry:** phone set on the table, control bar shows "מקשיב" (Listening).
2. **Key action:** people talk; captions arrive dim, lock white, labelled by speaker, numbers emphasized.
3. **Result:** the things she would otherwise miss reach her: her keyword buzzes the phone; the doorbell becomes a banner and an edge flash.

## Tone
- Preset: `polished`
- Creative direction: a quiet, warm product film; a love letter disguised as a launch video, with one deadpan pitch-deck joke as the hook.
- Interpretation: restraint everywhere except type scale. Slow blur-crossfades, long holds, no exit animations, third-person voice, one accent hue (the icon's amber). Humor appears once (the TAM slide) and comes from the project's truth. Five scenes instead of the preset's 3-4 because the demo is one long scene and the bookends are short.

## Format: landscape — 1920x1080
## Duration: 22.9 seconds

## Visual identity (from the project)
- Background: radial navy from the app icon, `#17384D` center → `#0B2230` edge. The phone screen itself is the app's true black `#000000` (caption theme "White on black").
- Accent: the icon's ear amber `#FFCA28` (inner `#FAA700`); number-emphasis yellow `#FFE033` (`CaptionTheme.numberText`).
- Text: `#FFFFFF`; pending text `rgba(255,255,255,0.62)` (`CaptionTheme.pendingText`).
- Supporting product colors: speaker amber `#FABF2E`, speaker sky `#73C7FA` (`SpeakerColor`), listening green `#30D158`, doorbell banner `#B34D00` @ 0.92 over an orange `#FF9F0A` edge flash, keyword field yellow @ 0.22.
- Display font: **Frank Ruhl Libre** (serif, Hebrew + Latin) — the voice of the film, and of the dedication.
- Body/UI font: **Heebo** (sans, Hebrew + Latin) — the voice of the app; everything inside the phone, plus emphasized numbers. The app itself uses the iOS system font, which can't be shipped; Heebo is the closest open Hebrew UI face.
- Metadata font: JetBrains Mono (bundled) for labels, glosses and the terminal receipt.
- Strongest visual element: the caption row itself (speaker label + dot, dim-to-white lock, yellow heavy numbers), and the amber ear icon.

## Share copy (draft)
Ozen has a total addressable market of one: Grandma. Live Hebrew captions for the conversation around her (who's talking, the numbers that matter, the doorbell), all on the phone. 485 commits in 6 days, built without a Mac.

## Audio direction
- Role: warm bed with sparse, professional accents.
- Music: `happy-beats-business-moves-vol-12-by-ende-dot-app.mp3` ("steady and clean", the preset's pick for `polished`).
- Music treatment: start 2.19s into the track (on a beat) so the track's first strong cue (8.74s) lands exactly on the cut to the phone. Volume 0.5 (gain lane) with a 0.5s fade-in, ducked to 0.36 under the doorbell, fade out over the last 1.5s under the end card. A first render at ~0.28 measured -26 LUFS (too quiet), so the bed was raised and SFX lowered; final master is -16 LUFS with a limiter at -1.5 dBTP.
- Music cue guidance: bundled preset read — `assets/music/cues/happy-beats-business-moves-vol-12-by-ende-dot-app.music-cues.{md,json}`, 109.96 BPM. With the 2.19s offset, strong cues fall at composition times **6.55** (cut to the phone), **10.92** (keyword buzz), **15.28** (cut to "485 commits"), **20.74** (end-card lockup; the track's strongest cue, 22.93s). Lock those four. Beat-grid window for the sequential "485 commits / 6 days / No Mac" lines: 15.83, 16.37, 16.91. Everything else uses natural timing for readability.
- Audio-reactive treatment: subtle; bass/RMS makes the navy glow and the ring system breathe. No waveform or equalizer visuals (the "Listening" chip is the app's own status control, not a visualizer, and does not react to audio).
- SFX posture: sparse, soft, motion-matched. Four moments.
- Audio-coupled moments: the icon reveal (one soft thud); the keyword buzz (three quick soft taps at +0 / +0.14 / +0.28s, the app's `AlertVibration.keyword` pattern); the doorbell (a two-note "ding-dong" one beat apart, as the banner drops); the end-card lockup (one soft hit under the strongest cue).
- Restraint rule: no per-word typing ticks, no whooshes on transitions, nothing louder than the bed's peaks. Bells only for the doorbell.

## Storyboard

### Scene 1 — The market — 3.81s (0.00 → 3.81)
Navy field, rings on the right labelled `TAM = 1`, `SAM = 1`, `SOM = 1`. Top-left: green "Listening" chip (persists all film). Left-anchored serif text: "Total addressable market:" (words arrive dim from 0.30, lock 1.08). Then "1 grandmother." huge (arrives 1.63, locks 2.20: "1" goes yellow + heavy; amber dot pops at ring center with a small "סבתא" label). Hold to 3.81.
Sequential/interaction: yes — words arrive one at a time, then the line "locks" (the app's caption-stabilizer behaviour). Rings draw in one by one, outer to inner.
Audio intent: the bed alone, just faded in; let the joke land dry.
Audio-coupled idea: none (restraint).
Music: warm, steady, low.
Transition mood: soft (blur crossfade; the dot stays put and becomes the icon) → Scene 2

### Scene 2 — The ear — 2.74s (3.81 → 6.55)
The amber dot swaps for the real app icon tile (ear on navy) at the ring center; rings begin rippling outward like sound. Left: "Ozen" + "אוזן" wordmark (4.37), mono kicker "HEBREW FOR 'EAR'" (4.6), tagline "Live captions for conversation." (4.9, verbatim from the app's first onboarding page). Hold to 6.55.
Sequential/interaction: none beyond the staggered lockup.
Audio intent: a first gentle lift; the product has a name.
Audio-coupled idea: one soft thud as the icon lands.
Transition mood: soft → Scene 3 (beat-locked to strong cue at 6.55)

### Scene 3 — The table — 8.73s (6.55 → 15.28)
Phone mockup rises on the right (where the icon was; rings now sit behind it, "listening"). Left column: the film's own transcript builds line by line, each arriving dim and locking, with a small mono gloss under it translating what the phone shows. Mono kicker above: "ON THE PHONE · NO SERVER · NO ACCOUNT" (README: "No server, no account.").
- 7.10 דנה's line arrives, locks 7.90 → 7.64 **Knows who's talking.** — gloss: "Good morning, how did you sleep?"
- 8.74 דובר 1's line arrives fast (14 words), locks 9.83, numbers turn yellow → 9.83 **Makes numbers stand out.** — gloss: "…a doctor's appointment at 10:30… two pills before."
- 10.92 keyword hit: yellow field + bell on the line, pill "דובר 1 — נאמר: שני כדורים", phone buzzes three quick taps → 11.45 **Buzzes on words she picks.** — gloss: keyword: "two pills"
- 12.54 doorbell banner "פעמון דלת · נשמע עכשיו" drops in; edge flash 0.4 on / 0.4 off ×2 → 13.10 **Hears the doorbell.** — gloss: "and about 50 other sounds"
- 13.65 → 15.28 breathe: דנה's reply "אני יכולה לקחת אותך, אין בעיה." arrives and locks; a new pending line "עוד לא ברור לי אם" stays dim (still settling).
Sequential/interaction: yes — four product behaviours in order, each with its annotation; simulated haptic buzz and doorbell alert. Sequential TEXT hold: annotations stack and stay on screen (never replaced), so each has ≥1.6s settled; the last holds 1.6s before the cut.
Audio intent: the bed finds its groove as the demo starts; product sounds are the only accents.
Audio-coupled idea: three quick soft taps with the buzz; two-note doorbell with the banner.
Transition mood: soft → Scene 4 (beat-locked to strong cue at 15.28)

### Scene 4 — The effort — 3.28s (15.28 → 18.56)
Left: three huge lines, numbers in emphasis yellow: "485 commits." (15.83) "6 days." (16.37) "No Mac." (16.91). Right: a small mono terminal receipt whose outputs appear in step: `git rev-list --count HEAD` → `485`; `git log --format=%ad --date=short | sort -u | wc -l` → `6`; `uname -s` → `Linux`. Rings slide mostly off the right edge. Hold to 18.56.
Sequential/interaction: yes — three lines on consecutive beats (beat-grid 15.83 / 16.37 / 16.91); they are 2-word reads and the full set then holds 1.65s.
Audio intent: the driest, most rhythmic moment; the facts ride the beat.
Audio-coupled idea: beat-aligned reveals only, no SFX.
Transition mood: soft, slowest of the film → Scene 5

### Scene 5 — The dedication — 4.34s (18.56 → 22.90)
Centered (a solemn closing). Rings drift to center as a halo. "בהצלחה, סבתא." arrives dim word by word in the Hebrew serif (19.09), locks white (19.65). Under it "Good luck, Grandma." (19.9) and a mono attribution "— THE LAST LINE OF OZEN'S FIRST-RUN SETUP" (20.18). At 20.74 (strongest cue) the end card lands beneath: app icon, "Ozen", `github.com/arbelonson-source/ozen`. Hold to 22.90; music fades under it. No fade to black.
Sequential/interaction: the dedication locks like a caption; end-card lockup lands as one unit.
Audio intent: exhale; one soft hit on the lockup, then the bed fades.
Audio-coupled idea: end-card lockup on the strongest cue.
Music: fades out 21.5 → 22.9.

**Scene durations:** 3.81 + 2.74 + 8.73 + 3.28 + 4.34 = **22.90s**

**Music mood for this video:** warm, steady, understated (cinematic-polished).
**Audio summary:** a low steady bed fades in under a dry joke, settles into its groove exactly as the phone appears, carries three product sounds (a thud, three taps, a doorbell) and lands its strongest beat on the end card before fading out.
