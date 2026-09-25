# Helping someone who uses Ozen

For the family member who gets the phone call. Everything Ozen is doing is
written on the status button at the bottom of the caption screen, in Hebrew.
Find the words she reads to you below.

## First: send the report

Settings → Diagnostics (avchun) → **Send the report** (shlichat ha-doch). It opens the share sheet, so
it can go straight to WhatsApp. The report ends with a timeline of what
happened to the captions, with clock times ("microphone stopped delivering
audio", "failed: …", "retry 1 in 2s", "listening"), so "it stopped at lunch"
can be read off it. Nothing in it is what was said; conversations never
leave the phone.

## What the status button says

| She reads | What it means | What to do |
| --- | --- | --- |
| "Listening" (makshiv) | Captions are running. | Nothing. If no words appear, check the microphone (below). |
| "Listening · Cloud captions aren't available, carrying on with the phone's own" (makshiv · ha-ktuviyot ba-anan lo zminot, mamshich im ha-zihuy she-ba-telefon) | Cloud captions lost their key, credit or internet, and a Whisper model already on the phone took over. Captions keep coming, a little less accurate. | Nothing urgent. Fix the key, credit or internet; the cloud is tried again the next time captions start (after Stop, or reopening the app). A pause and resume stays on the phone's model. |
| "Paused" (mushhe) | Paused by a tap. | Tap it to continue. |
| "The phone is talking" (ha-telefon medaber) | The phone is saying a typed reply aloud; captions pause so they don't caption it. | Nothing. They continue by themselves when it finishes. Tapping it stops the phone talking. |
| "Inactive" (lo pail) | Stopped (for example by Siri). | Tap it to start. |
| "Captions paused because of a call" (ha-ktuviyot mushhot biglal sicha) | A phone call or another app has the microphone. | Nothing. They come back after the call. If they don't, a notification "Captions stopped" (ha-ktuviyot ne'etzru) arrives; open Ozen from it. |
| "Downloading the language model · N%" (morid et model ha-safa · N%) | First-time download of the speech model. | Keep the app open (the screen stays on by itself) until it finishes. |
| "Waiting for Wi-Fi to download the language model" (mamtin le-Wi-Fi kdei lehorid et model ha-safa) | The model still has to download and the phone is on cellular data or Low Data Mode. | Connect to Wi-Fi and it starts by itself, or tap to download over cellular. |
| "Not enough free space on the phone" (ein maspik makom panuy ba-telefon) | Not enough room for the model. It says how much to free. | Free space (Settings → General → iPhone Storage), then open Ozen again and it starts by itself. Or tap to pick a smaller model, or switch to Apple's engine, which needs no download. |
| "Model download failed" (horadat ha-model nichshela) | The download failed, usually a dead connection. | It retries by itself for a while. Check the internet, then tap to try again. |
| "Model loading failed" (te'inat ha-model nichshela) | The model is on the phone but didn't load. | Tap to try again. If it keeps failing, pick a smaller model in Settings. |
| "Loading the model / almost ready" (to'en et ha-model / kim'at mukhan) | Starting up. The first time can take a minute or two. | Wait. |
| "The microphone isn't responding" (ha-mikrofon lo megiv) | Audio stopped arriving (a Bluetooth microphone reconnecting, often). | It restarts by itself. If it keeps coming back, choose the microphone again with the button at the bottom right. |
| "No microphone found" (lo nimtza mikrofon) | No microphone is available at all. | Reconnect the microphone, then tap. |
| "No access to the microphone" (ein gisha la-mikrofon) | Microphone permission was turned off for Ozen. | Tap it: it opens iOS Settings. Turn Microphone on. |
| "No permission for speech recognition" (ein ishur le-zihuy dibur) | Speech recognition permission is off (Apple's engine only). | Tap it: it opens iOS Settings. |
| "… not available in Hebrew on this device" (… lo zamin be-ivrit ba-machshir ha-ze) | Apple's engine has no on-device Hebrew on this iPhone. | Tap to switch to Whisper in Settings. |
| "Cloud captions need a valid OpenRouter key" (ha-tamlul ba-anan tzarich mafte'ach OpenRouter takin) | Cloud captions are chosen but there is no key, or OpenRouter turned it down, and no Whisper model is on the phone to take over. | Tap it: Settings opens. Paste the key from openrouter.ai (Keys) and tap Save. |
| "The OpenRouter key is out of credit" (nigmar ha-kredit shel mafte'ach OpenRouter) | The key used up its credit or its spending limit, and no Whisper model is on the phone to take over. | Add credit on openrouter.ai, or tap and switch back to Whisper. |
| "No internet connection" (ein chibur la-internet) | Cloud captions can't reach the internet, and no Whisper model is on the phone to take over. | Check Wi-Fi or cellular data. It retries by itself; or switch to Whisper, which works offline. |
| "Retrying by itself · tap to try now" (menase shuv le-vad · hakishu kedei lenasot achshav) | Something failed and a retry is already scheduled. | Wait a few seconds, or tap to retry now. |

## Things that are working as intended

- **A card on the empty caption screen offers "much more accurate Hebrew
  with a different model".** The phone was set up when the small, fast
  model was the default, and that one gets most Hebrew words wrong. Tapping
  the card switches to the recommended model and downloads it once, over
  Wi-Fi (the status button shows the download); captions come back by
  themselves when it has arrived. "Not now" (the x) puts the card away for
  good; the model can still be picked later in Settings → Whisper model.
- **The buttons at the bottom disappeared.** While captions run and follow
  the newest line, they slide away after a few seconds so they don't cover
  it. Touch the screen, or the small arrow at the bottom, to bring them back.
  To keep them always: Settings → Display → hide the buttons while captions
  run, off.
- **The app is in English (or Hebrew) and should be the other.** Settings →
  App language. "Same as the phone" follows the iPhone's own language.
- **All settings went back to the start.** The settings file couldn't be
  read. The damaged file is kept next to it as `ozen-settings.damaged.json`;
  send the diagnostics report and say so.

- **Speaker numbers start again from 1.** After a long quiet stretch (a new
  conversation), or when the screen is cleared, unnamed voices are numbered
  from "Speaker 1" (dover 1) again, so a phone left listening all week
  doesn't end up at speaker 140. Lines already on screen keep their labels.
  In a room that never goes quiet (a television left on), once there are
  more than twelve unnamed voices the one heard longest ago is forgotten,
  so it gets a new number if it speaks again.
  To have someone always called by name, press and hold one of their
  lines, choose "Who is speaking?" (mi medaber?) and type the name.
- **A line across the captions: "Said while the app was closed · 12 lines"
  (ne'emar k'she-ha-aplikatzia hayta sgura).** Captions kept coming while
  the phone was locked or another app was open; the line shows where the
  ones she hasn't seen begin. The button at the top, "What was said
  meanwhile" (ma she-ne'emar beinta'yim), scrolls up to it.
- **Captions on the lock screen.** The newest lines show there while
  captions run, and stay (saying "paused because of a call" or "captions
  stopped") when something interrupts them. After a minute with nothing
  said, only the newest line stays, with "said N minutes ago" (ne'emar
  lifnei N dakot) under it; after a quarter of an hour it gives way to
  "Listening" (makshiv). With the caption text size at 34 or more, the lock
  screen's lines are larger too, and show fewer words of the line before
  the newest. Settings → Display (tetzuga) → "Captions on the lock screen
  too" (ktuviyot gam be-masach ha-ne'ila) turns them off.

  If none appear: iOS Settings → Ozen → Live Activities must be on (when it
  is off, Ozen's own Settings shows a red note under the switch with a
  button that opens that page), and captions have to be started, or the app
  opened once, with the phone unlocked: iOS only lets an app put one on the
  lock screen from the front. They also end by themselves after eight
  hours; opening the app brings them back. The diagnostics report's "lock
  screen" line says whether the setting is on, whether iOS allows them,
  whether they are showing, and why iOS last refused one.
- **Adding the start button to Control Center or the lock screen.** On iOS
  18 or later: open Control Center, press and hold an empty spot, tap "Add
  a Control" and search for Ozen. For the lock screen: press and hold the
  lock screen, tap Customize, then Lock Screen, remove the flashlight or
  camera button and add Ozen's in its place. The button opens the app,
  so the phone asks for Face ID or the code first.
- **The screen turned off while listening.** After fifteen minutes with
  nothing said, the phone locks as usual to save the battery. Captions and
  doorbell or alarm alerts keep running; unlock to read.
- **An empty screen with a card about "The conversation from … minutes ago"
  (ha-sicha mi-lifnei … dakot).** iOS closed the
  app in the background mid-conversation. The card opens what was said. If
  it keeps happening, look in the report for "iOS low on memory (app using
  … MB)" and at the "Memory" (zikaron) row in Diagnostics: the speech model is most of
  that, so pick a smaller one in Settings → Whisper model (model Whisper) (the recommended
  Turbo (compressed) rather than a 3 GB one), or switch to Apple's engine.
- **Some words are in a different colour.** Numbers (a time, how many pills,
  a phone number) stand out so they aren't missed: yellow among white text,
  white among yellow text, dark blue on a white background. Settings → Display (tetzuga) →
  "Bold numbers" (misparim boltim) turns it off.
- **One person gets two speaker numbers, or two people share one.** Voices
  are told apart by how they sound, which is rough: expect a wrong label now
  and then, more often in a noisy room. Settings → Behaviour (hitnahagut) →
  "Speaker separation sensitivity" (regishut hafradat dovrim) adjusts it:
  towards "merges more" (me'ached yoter) if the same person keeps getting a
  new number, towards "separates more" (mafrid yoter) if two people are
  joined. Build 13 and earlier put everyone under one label (and a
  saved voice's name on everybody's lines); updating fixes that, and saved
  voices keep working.
- **Hearing aids or AirPods are connected, but the phone's microphone is
  used.** On purpose: a microphone on her own ear hears her own voice best
  and everyone else's worst. It is used only when she picks it with the
  button at the bottom right (or when no other microphone is there). Once
  picked it stays her choice: after a phone call, or when a hearing aid
  reconnects slowly, Ozen asks for it again by itself.
- **People further away aren't captioned, or lines stop mid-sentence.**
  The report's `levels:` line says how loud the microphone hears the room
  (quiet / middle / loud, in dBFS) and `speech:` how much of it counted as
  someone talking; the same numbers are in Diagnostics as "Sound levels"
  (ramot kol) and "Heard as speech" (nishma ke-dibur). Speech needs to
  reach about -60 dBFS: if "loud" stays below that through a conversation,
  the phone is too far from the people talking, or an external microphone
  helps. Build 14 and earlier ignored anything under -44 dBFS, which in
  practice was most conversation more than a metre away. `floor:` is the
  room's background noise as the phone has learned it, and `margin:` how
  far above it speech must be: about 6 dB when the noise is steady (a fan,
  an air conditioner), up to 8 dB when it swings. Talking only a few dB
  above a loud `floor:` is where words get lost; moving the phone closer
  to the people than to the noise helps most.
- **Nonsense lines, or a saved voice that stops being recognised, with one
  microphone only.** The report's `damaged:` count (next to `stalls:`) is
  how many pieces of audio arrived broken. Ozen replaces them with silence,
  so a few after a Bluetooth microphone reconnects do no harm; a number
  that keeps climbing means that microphone, or its connection, is failing.
  Try the phone's own microphone to confirm.
- **A small question mark next to a line.** The engine wasn't sure it heard
  that line right. Holding the line offers to ask the speaker to repeat it.
- **No phone notifications when the screen is off.** Settings → Notifications (hatra'ot) shows
  a red warning if notifications are blocked for Ozen in iOS, with a button
  to fix it. If there's no warning, tap "Check that a notification arrives when the phone is locked" (livdok she-hatra'a magi'a k'she-ha-telefon na'ul)
  and lock the phone: a sample doorbell alert arrives within 10 seconds. If
  it doesn't, a Focus mode or Scheduled Summary in iOS is holding it back.
- **The doorbell rang and no alert came at all.** First the report's
  `alerts:` line: `sounds false` means sound alerts are off, `from critical`
  means only alarms and sirens alert, and `muted` counts sounds switched off
  one by one (Settings → Sounds at home (tzlilim ba-bayit)). Then its
  `sounds heard below the alert level:` line, or Diagnostics → "Sounds heard
  too faintly to alert" (tzlilim she-nishme'u chalash midai le-hatra'a). A
  doorbell listed there was heard, but under the 60% sureness an alert
  needs: the phone is too far from the door, so keep it closer or in the
  same room, or under that doorbell in Settings → Sounds at home tap
  "Alert on a fainter sound too" (lehatri'a gam al tzlil chalash yoter).
  If that brings false alarms, the same button undoes it. Not listed at all means the sound classifier didn't recognize
  it as a doorbell (some electronic chimes don't sound like one to it).
- **The doorbell notification comes, but she doesn't notice it.** With the
  phone face down or across the room, turn on iOS Settings → Accessibility →
  Audio & Visual → LED Flash for Alerts: the camera light then blinks for
  every notification, Ozen's included. With the app open, sirens and the
  doorbell already flash the edge of the screen.
- **Alerts don't vibrate.** With the app open each kind vibrates its own
  way: long buzzes for an alarm or siren, a double knock for the door or a
  baby, three quick taps for her name. Settings → Sounds at home (tzlilim ba-bayit) → "How each
  alert feels" (eich kol hatra'a margisha) plays each one, to learn them together. If nothing vibrates
  at all, iOS Settings → Accessibility → Touch → Vibration has been turned
  off, which silences every app. If every alert gives the same plain buzz,
  Diagnostics shows "Vibration for alerts: failed" (retet le-hatra'ot: nichshal) and the report says why.
- **A banner "Saving on the phone failed" (ha-shmira ba-telefon nichshela), or History says the last save failed.**
  The phone is out of storage, so new conversations and settings changes
  aren't being kept, though captions still work. Free some space (Settings →
  General → iPhone Storage) and saving resumes by itself; the banner comes
  back only if it fails again.
- **A model in the model list is greyed out and can't be picked.** It says
  "Not enough space on the phone" (ein maspik makom ba-telefon): its
  download wouldn't fit, and picking it would only stop the captions that
  work now. Free space and it can be picked; a model already on the phone,
  or half downloaded, can always be picked.
- **Picking a model asks "Download … and switch to it?"** (lehorid … ve-la'avor
  elav). Captions are running and that model isn't on the phone yet:
  captions stop until it has downloaded and loaded, so it asks first.
- **A search in History finds nothing, though she remembers the
  conversation.** Every word typed has to appear in it somewhere, so fewer
  words find more: "doctor" (rofe) rather than "what the doctor said about
  the pills". Parts of words count ("rofe" also finds "la-rofe", "to the
  doctor"), and a speaker's name or the conversation's own name can be
  searched too. A conversation that captioned a word wrongly can only be
  found by what is actually written; the day headings (Today, Yesterday, a
  weekday) are the other way in.
- **"Earlier lines were saved. Tap to read them" (shurot mukdamot yoter
  nishmeru) at the top of the captions.** The caption screen keeps the
  newest 300 lines; tapping the note opens the saved conversation where the
  screen cut off. With saving off, or failing, it reads "Earlier lines are
  no longer shown" (shurot mukdamot yoter kvar lo mutzagot) instead.

## Reinstalling

Ozen is sideloaded with a free Apple ID, so it stops opening after seven days.
Two days before, the caption screen says when ("Ozen will stop opening
tomorrow at 07:24" (Ozen tafsik lehipatach machar be-sha'a 07:24)), and a
notification repeats it the day before; Settings → About (odot) and
Diagnostics show the exact date under "Installation valid until" (ha-hatkana tkefa ad).
See [sideloading-from-linux.md](sideloading-from-linux.md) for the command that
refreshes it.
