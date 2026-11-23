# Setup guide

This guide sets up an Android e-reader so that KOReader keeps your place in sync with your
BookOrbit library. It works on its own: the reader wakes, syncs, and goes back to sleep.

**The short version: sideload one app, then follow its Setup.** Orbit Companion installs
everything else (KOReader, the BookOrbit plugin and the KOReader add-on) from their official
releases, checks each download, and walks you through the rest with one button. Plan on about
15 minutes. With a computer and a USB cable there is also a script that does it all at once
(see "Set up over USB" below).

## 1. What you need

- An **Android e-reader** with Android 8 or newer (Settings › About shows the version).
- A **BookOrbit account** and the address of its server.
- **Tailscale**, but only if your BookOrbit server is on a private Tailscale network
  ("tailnet"). If the server is reachable on the open internet, skip Tailscale.

## 2. Sideload Orbit Companion

On the reader, download `orbit-companion-<version>.apk` from
[this project's releases](https://github.com/Fledgewing/Orbify/releases/latest)
and open it. When Android asks, allow your browser or file manager to install apps.

**Play Protect** may say the app is unknown or "unsafe". That is its standard warning for apps
from outside the Play Store: tap **More details**, then **Install anyway**. It can warn again
when Orbit installs KOReader or updates itself; the answer is the same.

## 2b. Full or Add-on (companion 0.11.0+)

The first time you open Orbit Companion it asks how it should run:

- **Full**: Orbit is the Home app. Home opens your book or BookOrbit, and Orbit switches Wi-Fi,
  keeps the reader awake for sleep syncs, and runs clicker buttons and the Settings PIN.
- **Add-on**: your reader keeps its own Home screen and Wi-Fi. Orbit installs, updates and sets
  up KOReader, BookOrbit and the Orbit plugin. Setup then has four required steps (KOReader, the
  BookOrbit plugin, the Orbit plugin, signed in to BookOrbit); every other row is optional and
  says what you get with it. Wi-Fi switching, sleep sync, clicker buttons and the PIN are
  helpers in Settings, off until you turn them on.

A reader already set up before 0.11.0 stays Full and is not asked. Switch either way later in
Settings › **Mode**.

## 3. Open Orbit Companion › Setup › Fix next

Open **Orbit Companion**, then **Setup**, and tap **Fix next**. It goes through every step that
isn't ticked, in order, and brings you back to Setup after each one. You can also tap any row
yourself. Tips that only explain something (Play Protect, Family Link, a launcher that
freezes apps) aren't steps: read them, tap **Got it** to hide them (**Show hidden tips** at the
bottom brings them back).

| Row | What it does |
|---|---|
| Family Link supervision / Managed device | Shown only if a parent's Family Link or a work profile controls the reader. It says what it blocks (installs, the Home app, accessibility). When a step won't stick, **approve it in the parent's Family Link app**. |
| Play Protect scans installs | Reminder: on a Play Protect warning, tap **More details**, then **Install anyway**. |
| Not disabled by the system | Some launchers (Boox, Meebook) "freeze" apps they think are unused. It names any frozen app and opens the page to re-enable it (step 5). |
| Install updates | Allow "Install unknown apps" for Orbit, so it can install KOReader and its own updates. |
| KOReader app installed | Installs the official KOReader from its GitHub releases, for your reader's processor, and checks the download. Tap it again later to check for a KOReader update. |
| BookOrbit plugin installed | Installs the BookOrbit plugin from BookOrbit's GitHub release into `koreader/plugins/` (allow storage access) and restarts KOReader. After that the plugin updates itself from your BookOrbit server. |
| KOReader patch installed | Installs the KOReader add-on into `koreader/patches/` and checks it. |
| Set Orbit as Home app | Pick Orbit Companion as the Home app ("Always"). |
| Allow notifications | Allow. The app shows one quiet notification so Android keeps it running. |
| Battery: Unrestricted | Choose "Unrestricted" so Android doesn't stop syncs. |
| Tailscale signed in and connected | Only for a private server: install Tailscale and sign in (step 4). |
| Allow "lock screen" (device admin) | Allow. "Sync and sleep" uses it to turn the screen off; nothing else. |
| KOReader patch answered | Open KOReader once; it ticks when the add-on is running. |
| Wi-Fi off/on test | Tap. It checks that Wi-Fi can be switched without a prompt, and leaves Wi-Fi as it was. |

Then open KOReader, go to Tools › BookOrbit and **sign in** to your BookOrbit server.

**Which KOReader?** Only the official build from KOReader's GitHub releases loads the add-on.
F-Droid's KOReader is a separate app that skips add-ons (KOReader's `frontend/userpatch.lua`
turns them off on that build); the Play Store copy isn't the official build either. Setup says
which one you have. Install the official one from Setup; your books and the `koreader` folder
stay. A KOReader signed by someone else has to be uninstalled first (Setup opens its app page).

**Updates are one step.** When Orbit updates (it asks you to confirm), it installs the matching
add-on itself, and KOReader restarts to load it once no book is open (or when the reader next
sleeps). It never interrupts reading, and says "Updated to v… (KOReader restarted)".

## 4. Install Tailscale (only for a private server)

1. Install Tailscale from the Play Store (or its `.apk` from tailscale.com) and sign in.
2. Android Settings › Network › VPN › Tailscale ⚙: turn **Always-on VPN** on.
3. On the same page, turn **Block connections without VPN** **off**. Tailscale only carries
   traffic for your private network. With this on, everything else (including updates for
   this app) is blocked.

## 5. Notes for your reader brand

- **Meebook:** the Meebook launcher "freezes" apps it thinks are unused. Open it, go to
  **Freeze management**, unfreeze KOReader, Tailscale and Orbit Companion, and turn
  automatic freezing off.
- **Boox** (not yet tested): Boox can also freeze apps. In Apps › App Management, open
  Freeze Settings and set KOReader, Tailscale and Orbit Companion to never freeze. Allow
  them to run in the background if Boox asks.
- **Any reader:** set the battery to "Unrestricted" for KOReader, Tailscale and Orbit
  Companion (Android Settings › Apps › the app › Battery).

## 6. Set up over USB (optional)

With a Mac or Linux computer, a USB cable and USB debugging on (Settings › About › tap the
build number 7 times, then Developer options › USB debugging), one script installs
everything:

```sh
tools/install-usb.sh                  # install or update everything
tools/install-usb.sh --fresh          # first clear an old koreader folder (lists it, asks y/N)
tools/install-usb.sh --books out.csv  # also save the reader's book list as a spreadsheet
```

It needs `adb` (Android platform-tools), `curl` and `jq`. It shows the reader's model, Android
version and processor, then downloads the newest KOReader, BookOrbit plugin, Orbit Companion and
add-on from their official GitHub releases, checks every file (GitHub's published checksums,
`SHA256SUMS`, and the build attestations when the `gh` tool is installed), installs the two apps
and copies the plugin and add-on into place. An existing plugin that is new enough is kept (it
updates itself). `--books` lists every book file with its title and author (from NeoReader's
library on a Boox, and from the book itself), plus its reading status and when it was last
opened in KOReader; it runs before any change. The script never deletes anything except the old
`koreader` folder you confirmed with `--fresh`, the plugin folders it replaces and the old
`koreader/patches/2-orbit-android.lua`. Then open
Orbit Companion › Setup › **Fix next** on the reader for the steps that need a tap there.

If you'd rather copy files by hand: unzip `orbit.koplugin.zip` into `koreader/plugins/`, copy the
BookOrbit plugin's `bookorbit.koplugin` folder there too, delete `koreader/patches/2-orbit-android.lua`
if an older setup left it, then restart KOReader.

## 8. Recommended settings

In KOReader, open **Tools › Android sync**:

- **Wi-Fi: Just in time.** Wi-Fi is on only while something needs it.
- **Home button: Back to my book, then BookOrbit home.**
- **Recommended settings**: Orbit already applied the ones still at their default. Open it to
  review any you had changed (Use Orbit's or Keep mine) or to Undo one.
- Run **Test sync path**: every step should show ✓.

The same Wi-Fi and Home settings are in Orbit Companion › Settings; changing one changes both.

**Reading in another app?** Orbit Companion › Settings › **Home opens** picks what the Home
button opens. The choices are KOReader + BookOrbit (the default), the Orbit launcher page, or
any installed app, with reader apps such as Readest and Moon+ Reader listed first. Home then
brings that app back where you were, and pressing Home twice still shows the launcher page.
With KOReader + BookOrbit, **In KOReader, Home goes to** picks "Back to my book, then BookOrbit
home" or "BookOrbit home". **Sync while reading** is in Settings too; KOReader keeps it, and a
change made in the companion applies when KOReader next opens. Sync on sleep, Just in
time Wi-Fi and BookOrbit home work only inside KOReader.

## 8b. A Bluetooth page clicker (optional)

1. Pair the clicker in Android's Bluetooth settings.
2. Open Orbit Companion › Settings › **Clicker buttons** › **Add a clicker**, then press each
   button and pick its action: next or previous page, Home, Back, frontlight on/off, or Sync
   and sleep. Hold and double press are optional per button.
3. In KOReader it works at once. For other reader apps, switch on Android **Settings ›
   Accessibility › Orbit clicker buttons**. It only sees button presses and which app is in
   front; it can't read the screen. Setup reminds you if a vendor app freeze turns it off.
4. **Per app:** each button has a default action, and **+ Override for another app** gives one
   app its own (for example Next page everywhere, but Volume down in Readest).
5. **Send Volume up/down, Send key…** (Page up/down, arrows, Space) are for readers that turn
   pages on keys. They need the **Orbit keyboard**: Setup asks you to switch on "Orbit clicker
   keys" in Android's keyboard settings. It has no keys and never becomes your keyboard: it
   switches in for the press, then yours comes back. A press while you type in a text field
   does nothing. If keys don't arrive, turn on Settings › Clicker buttons › **Keep Orbit
   keyboard active** and use its notification's "Switch keyboard" when you want to type.
6. Used **Key Mapper** before? Turn it off once Orbit's buttons work; you can then uninstall
   it. Two key mappers both see every key and can fight.

## 8c. A Settings PIN (optional)

Keeps kids out of the settings. Off until you set one.

1. Orbit Companion › Settings › **Settings PIN**: type 4–8 digits on the keypad, then again.
2. Behind the PIN: the companion's Settings and Clicker buttons, Setup's **Fix** buttons, the
   update install, turning the PIN off, the launcher's **Android Settings** tile and the
   KOReader **Android sync** menu.
3. **Guarded apps** (Settings, once a PIN is set): Android Settings is on the list; add any app,
   such as the Play Store or a browser. A guarded app opens behind the keypad; **Cancel** goes
   Home. This needs Android **Settings › Accessibility › Orbit clicker buttons**: Setup shows
   a "Clicker buttons / app guard (accessibility) on" row while a PIN is set.
4. A right PIN stays unlocked while you are in the companion's settings, a guarded app, or the
   page a Setup Fix opened. After you leave (Home, KOReader, another app) it stays unlocked for
   2 more minutes, so coming back needs no PIN; then it locks. The screen turning off locks it
   at once. After 5 wrong tries the
   keypad waits 30 s, then twice as long after each further wrong try, up to 5 minutes.
5. Never locked: the companion itself, KOReader, the phone/emergency apps and the status bar.
   Pages a Setup **Fix** opens, and Android's install screens during an update you started.

**What it can't stop:** the quick settings in the pulled-down notification shade (Wi-Fi,
airplane mode and so on), booting into Android's safe mode (the guard doesn't run there), and
anyone with a USB cable and adb. Uninstalling the companion or turning its accessibility
service off both go through Android Settings, which is guarded.

**Forgot the PIN?** Connect the reader by USB with adb (developer options) and run:

```sh
adb shell am broadcast -n net.fledgewing.orbitcompanion/.PinResetReceiver -a net.fledgewing.orbitcompanion.action.RESET_PIN
```

The PIN is gone; set a new one in Settings. Only adb can send this; other apps on the reader
can't.

## 9. If something's wrong

- **KOReader asks "Turn on Wi-Fi?"**: Orbit Companion isn't running or is disabled. Open it
  and check its Setup page.
- **"Internet blocked: is 'Block connections without VPN' on…"**: turn that setting off
  (step 4).
- **"… is disabled by …" or "disabled by the system"**: re-enable the app it names (step 5).
- **KOReader restarts after sleep**: some readers stop it a few minutes after the screen goes
  off. That's expected. Home reopens your book, and syncs still run.
- **Sync didn't happen**: run Tools › Android sync › Test sync path. The first step with ✗
  says what to fix.
