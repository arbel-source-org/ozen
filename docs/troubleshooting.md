# Helping someone who uses Ozen

For the family member who gets the phone call. Everything Ozen is doing is
written on the status button at the bottom of the caption screen, in Hebrew.
Find the words she reads to you below.

## First: send the report

Settings → אבחון (Diagnostics) → **שליחת הדוח**. It opens the share sheet, so
it can go straight to WhatsApp. The report ends with a timeline of what
happened to the captions, with clock times ("microphone stopped delivering
audio", "failed: …", "retry 1 in 2s", "listening"), so "it stopped at lunch"
can be read off it. Nothing in it is what was said; conversations never
leave the phone.

## What the status button says

| She reads | What it means | What to do |
| --- | --- | --- |
| מקשיב | Captions are running. | Nothing. If no words appear, check the microphone (below). |
| מושהה | Paused by a tap, or while the phone speaks a typed reply. | Tap it to continue. |
| לא פעיל | Stopped (for example by Siri). | Tap it to start. |
| הכתוביות מושהות בגלל שיחה | A phone call or another app has the microphone. | Nothing. They come back after the call. If they don't, a notification "הכתוביות נעצרו" arrives; open Ozen from it. |
| מוריד את מודל השפה · N% | First-time download of the speech model. | Keep the app open (the screen stays on by itself) until it finishes. |
| ממתין ל-Wi-Fi כדי להוריד את מודל השפה | The model still has to download and the phone is on cellular data or Low Data Mode. | Connect to Wi-Fi and it starts by itself, or tap to download over cellular. |
| אין מספיק מקום פנוי בטלפון | Not enough room for the model. It says how much to free. | Free space (Settings → General → iPhone Storage), then open Ozen again and it starts by itself. Or tap to pick a smaller model, or switch to Apple's engine, which needs no download. |
| הורדת המודל נכשלה | The download failed, usually a dead connection. | It retries by itself for a while. Check the internet, then tap to try again. |
| טעינת המודל נכשלה | The model is on the phone but didn't load. | Tap to try again. If it keeps failing, pick a smaller model in Settings. |
| טוען את המודל / כמעט מוכן | Starting up. The first time can take a minute or two. | Wait. |
| המיקרופון לא מגיב | Audio stopped arriving (a Bluetooth microphone reconnecting, often). | It restarts by itself. If it keeps coming back, choose the microphone again with the button at the bottom right. |
| לא נמצא מיקרופון | No microphone is available at all. | Reconnect the microphone, then tap. |
| אין גישה למיקרופון | Microphone permission was turned off for Ozen. | Tap it: it opens iOS Settings. Turn Microphone on. |
| אין אישור לזיהוי דיבור | Speech recognition permission is off (Apple's engine only). | Tap it: it opens iOS Settings. |
| … לא זמין בעברית במכשיר הזה | Apple's engine has no on-device Hebrew on this iPhone. | Tap to switch to Whisper in Settings. |
| מנסה שוב לבד · הקישו כדי לנסות עכשיו | Something failed and a retry is already scheduled. | Wait a few seconds, or tap to retry now. |

## Things that are working as intended

- **The screen turned off while listening.** After fifteen minutes with
  nothing said, the phone locks as usual to save the battery. Captions and
  doorbell or alarm alerts keep running; unlock to read.
- **An empty screen with a card about "השיחה מלפני … דקות".** iOS closed the
  app in the background mid-conversation. The card opens what was said.
- **A small question mark next to a line.** The engine wasn't sure it heard
  that line right. Holding the line offers to ask the speaker to repeat it.
- **No phone notifications when the screen is off.** Settings → התראות shows
  a red warning if notifications are blocked for Ozen in iOS, with a button
  to fix it. If there's no warning, tap "לבדוק שהתראה מגיעה כשהטלפון נעול"
  and lock the phone: a sample doorbell alert arrives within 10 seconds. If
  it doesn't, a Focus mode or Scheduled Summary in iOS is holding it back.
- **The doorbell notification comes, but she doesn't notice it.** With the
  phone face down or across the room, turn on iOS Settings → Accessibility →
  Audio & Visual → LED Flash for Alerts: the camera light then blinks for
  every notification, Ozen's included. With the app open, sirens and the
  doorbell already flash the edge of the screen.
- **Alerts don't vibrate.** With the app open each kind vibrates its own
  way: long buzzes for an alarm or siren, a double knock for the door or a
  baby, three quick taps for her name. If nothing vibrates at all, iOS
  Settings → Accessibility → Touch → Vibration has been turned off, which
  silences every app.
- **A banner "השמירה בטלפון נכשלה", or History says the last save failed.**
  The phone is out of storage, so new conversations and settings changes
  aren't being kept, though captions still work. Free some space (Settings →
  General → iPhone Storage) and saving resumes by itself; the banner comes
  back only if it fails again.

## Reinstalling

Ozen is sideloaded with a free Apple ID, so it stops opening after seven days.
Two days before, the caption screen says when ("אוזן תפסיק להיפתח מחר בשעה
07:24"), and a notification repeats it the day before; Settings → אודות and
Diagnostics show the exact date under "ההתקנה תקפה עד".
See [sideloading-from-linux.md](sideloading-from-linux.md) for the command that
refreshes it.
