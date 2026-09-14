# Installing Ozen on an iPhone from a Linux machine (no Mac, free Apple ID)

This is the exact path that worked on 2026-09-13 with an iPhone 15 Pro Max on
iOS 18.7.3 and an Arch Linux desktop. It is written down because three separate
things were broken along the way, none of them in Ozen itself.

## What you need

- The unsigned `Ozen.ipa` from the latest GitHub Release (built by
  `.github/workflows/release.yml`, `gh workflow run release.yml` to make a new one).
- `usbmuxd` + `libimobiledevice` (`idevice_id -l` must show the phone; if you get
  `LIBUSB_ERROR_ACCESS`, `sudo systemctl restart usbmuxd` — it races udev on boot).
- [AltServer-Linux](https://github.com/NyaMisty/AltServer-Linux) (the CLI binary,
  v0.0.5 was used), and [Provision's `anisette_server`](https://github.com/Dadoum/Provision)
  running on `127.0.0.1:6969`.
- A free Apple ID. **Use an app-specific password** from appleid.apple.com rather
  than the real one; the AltServer CLI takes it on the command line.

## The three gotchas

1. **`anisette_server` aborts with "libplist is not available"** on Arch, because
   it dlopens `libplist.so.3` and Arch ships `libplist-2.0.so.4`. Symlinks fix it:
   ```
   mkdir -p ~/.local/share/altlinux/compat-lib
   ln -s /usr/lib/libplist-2.0.so.4 ~/.local/share/altlinux/compat-lib/libplist.so.3
   ln -s /usr/lib/libplist-2.0.so.4 ~/.local/share/altlinux/compat-lib/libplist-2.0.so.3
   LD_LIBRARY_PATH=~/.local/share/altlinux/compat-lib ./anisette_server
   ```
2. **Apple returns HTTP 503 during sign-in** (since September 2026) whenever the
   `X-MMe-Client-Info` header contains `com.apple.dt.Xcode`, which
   `anisette_server` hardcodes. The fix in AltServer-Linux is an unmerged PR with
   no binary, so a 50-line local proxy rewrites the one substring instead:
   `anisette_proxy.py` listens on `:6970`, forwards to `:6969`, and replaces
   `com.apple.dt.Xcode` with `com.apple.akd` in the response body. Point
   AltServer at the proxy with `ALTSERVER_ANISETTE_SERVER=http://127.0.0.1:6970`.
3. **"AltServer could not find the device" right after signing succeeded**: the
   USB connection dropped during the multi-minute signing step. Set the phone's
   Auto-Lock to Never while installing, `sudo systemctl restart usbmuxd`, and run
   the same command again — the 2FA code will be asked for again.

## Getting the build

Each run of the release workflow attaches `Ozen.ipa` to a GitHub Release named
"Ozen build N", tagged `v0.2.N` (the app's version series, then the build
number, which Settings shows in brackets). The repository is private, so
downloading needs an account with access: sign in on the Releases page, or
with the GitHub CLI logged in,

```
gh release download v0.2.N -R arbelonson-source/ozen -p Ozen.ipa --clobber
```

## The command

```
ALTSERVER_ANISETTE_SERVER=http://127.0.0.1:6970 \
./AltServer -u <UDID from idevice_id -l> -a YOUR_APPLE_ID -p YOUR_APP_SPECIFIC_PASSWORD Ozen.ipa
```

The app carries a widget extension (the lock screen captions and the Control
Center button), which AltServer signs as a second App ID, `…Ozen.Captions`. A
free Apple ID allows ten new App IDs a week, so this only matters when
installing many different apps with it.

Then on the phone: Settings → General → VPN & Device Management → trust the
developer certificate; Settings → Privacy & Security → Developer Mode → on
(the phone restarts). The app expires after 7 days on a free Apple ID; run the
same command again to refresh it (a paid developer account removes the limit).

## Refreshing

Ozen warns on its own caption screen two days before it stops opening, and sends
a reminder notification the day before; Settings → About (odot) shows the exact moment
under "Installation valid until" (ha-hatkana tkefa ad). Settings shows the installed build as "0.2.0 (N)", N being
the release's build number.

Refresh with the **same Apple ID** as last time: AltServer then installs over
the existing app, and her settings, enrolled voices, saved conversations and
the downloaded speech model (hundreds of MB) all stay. A different Apple ID
gives the app a different bundle identifier, so it installs as a second, empty
copy.
