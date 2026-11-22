# Setup guide

This guide sets up an Android e-reader so that KOReader keeps your place in sync with your
BookOrbit library. It works on its own: the reader wakes, syncs, and goes back to sleep. Plan
on about 30 minutes. You need nothing but the reader and a phone or computer to download files.

## 1. What you need

- An **Android e-reader** with Android 8 or newer (Settings › About shows the version).
- A **BookOrbit account** and the address of its server.
- **Tailscale**, but only if your BookOrbit server is on a private Tailscale network
  ("tailnet"). If the server is reachable on the open internet, skip Tailscale.

## 2. Install KOReader (the right build)

Download the newest `.apk` for your reader from
[KOReader's releases](https://github.com/koreader/koreader/releases) (usually the `arm64`
one) and install it.

Use **this build only**. The F-Droid and Play Store copies ignore the add-on this setup
installs in step 6.

How to tell which one you have: open Android Settings › Apps › KOReader › App details (at the
bottom). "Installed from F-Droid" or "Google Play" means the wrong build: uninstall it and
install the one above. Your books and settings stay in the `koreader` folder.

## 3. Install the BookOrbit plugin and sign in

Follow the plugin's own instructions:
[BookOrbit Sync plugin for KOReader](https://github.com/bookorbit/bookorbit/blob/main/koreader-plugin/README.md).
Sign in from KOReader's Tools › BookOrbit menu.

## 4. Install Tailscale (only for a private server)

1. Install Tailscale from the Play Store (or its `.apk` from tailscale.com) and sign in.
2. Android Settings › Network › VPN › Tailscale ⚙: turn **Always-on VPN** on.
3. On the same page, turn **Block connections without VPN** **off**. Tailscale only carries
   traffic for your private network. With this on, everything else (including updates for
   this app) is blocked.

## 5. Install Orbit Companion

1. On the reader, download `orbit-companion-<version>.apk` from
   [this project's releases](https://github.com/Fledgewing/BookOrbit-Android/releases/latest)
   and open it. When Android asks, allow your browser or file manager to install apps.
2. Open **Orbit Companion**, then **Setup**. Tap each row that isn't ticked:

| Row | What to do |
|---|---|
| Set Orbit as Home app | Pick Orbit Companion as the Home app ("Always"). |
| Allow notifications | Allow. The app shows one quiet notification so Android keeps it running. |
| Not disabled by the system | Re-enable any app it names (see step 7). |
| Install updates | Allow "Install unknown apps" for Orbit, so it can update itself. |
| Battery: Unrestricted | Choose "Unrestricted" so Android doesn't stop syncs. |
| Tailscale signed in and connected | Only for a private server: open Tailscale and sign in. |
| Allow "lock screen" (device admin) | Allow. "Sync and sleep" uses it to turn the screen off; nothing else. |
| KOReader patch installed | Tap to install the KOReader add-on (step 6). |
| KOReader patch answered | Tap to open KOReader; it ticks once the add-on is running. |
| Wi-Fi off/on test | Tap. It checks that Wi-Fi can be switched without a prompt, and leaves Wi-Fi as it was. |

## 6. Install the KOReader add-on (patch)

- **Easiest:** on Setup, tap **KOReader patch installed** and allow storage access. It
  downloads the add-on, checks it, and puts it in the `koreader/patches` folder. Then close
  and reopen KOReader.
- **By hand:** download `2-orbit-android.lua` from the same releases page and copy it into
  the `koreader/patches` folder on the reader (create the folder if needed), then restart
  KOReader.

The add-on then updates itself.

## 7. Notes for your reader brand

- **Meebook:** the Meebook launcher "freezes" apps it thinks are unused. Open it, go to
  **Freeze management**, unfreeze KOReader, Tailscale and Orbit Companion, and turn
  automatic freezing off.
- **Boox** (not yet tested): Boox can also freeze apps. In Apps › App Management, open
  Freeze Settings and set KOReader, Tailscale and Orbit Companion to never freeze. Allow
  them to run in the background if Boox asks.
- **Any reader:** set the battery to "Unrestricted" for KOReader, Tailscale and Orbit
  Companion (Android Settings › Apps › the app › Battery).

## 8. Recommended settings

In KOReader, open **Tools › Android sync**:

- **Wi-Fi: Just in time.** Wi-Fi is on only while something needs it.
- **Home button: Back to my book, then BookOrbit home.**
- **Apply recommended settings**, then **Apply recommended gestures.**
- Run **Test sync path**: every step should show ✓.

The same Wi-Fi and Home settings are in Orbit Companion › Settings; changing one changes both.

**Reading in another app?** Orbit Companion › Settings › **Home opens** picks what the Home
button opens. The choices are KOReader + BookOrbit (the default) or any installed app, with
reader apps such as Readest and Moon+ Reader listed first. Home then brings that app back
where you were, and pressing Home twice still shows the launcher page. Sync on sleep, Just in
time Wi-Fi and BookOrbit home work only inside KOReader.

## 8b. A Bluetooth page clicker (optional)

1. Pair the clicker in Android's Bluetooth settings.
2. Open Orbit Companion › Settings › **Clicker buttons** › **Add a clicker**, then press each
   button and pick its action: next or previous page, Home, Back, frontlight on/off, or Sync
   and sleep. Hold and double press are optional per button.
3. In KOReader it works at once. For other reader apps, switch on Android **Settings ›
   Accessibility › Orbit clicker buttons**. It only sees button presses and which app is in
   front; it can't read the screen. Setup reminds you if a vendor app freeze turns it off.
4. Used **Key Mapper** before? Turn it off once Orbit's buttons work; you can then uninstall
   it. Two key mappers both see every key and can fight.

## 9. If something's wrong

- **KOReader asks "Turn on Wi-Fi?"**: Orbit Companion isn't running or is disabled. Open it
  and check its Setup page.
- **"Internet blocked: is 'Block connections without VPN' on…"**: turn that setting off
  (step 4).
- **"… is disabled by …" or "disabled by the system"**: re-enable the app it names (step 7).
- **KOReader restarts after sleep**: some readers stop it a few minutes after the screen goes
  off. That's expected. Home reopens your book, and syncs still run.
- **Sync didn't happen**: run Tools › Android sync › Test sync path. The first step with ✗
  says what to fix.
