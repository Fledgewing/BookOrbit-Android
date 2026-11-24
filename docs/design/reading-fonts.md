# Reading fonts: Bitter and Literata

ROADMAP 12. Android (Orbit Companion); Xteink needs nothing (§5). Status: **building**.

## 1. Outcome

A reader who wants Bitter or Literata in KOReader's font menu turns on one Optional Setup row,
"Reading fonts: Bitter, Literata". It is off by default, never counted, walked or prompted
(companion-checklist §3.7). Turning it off removes the files again.

## 2. The fonts and their licenses

Both are under the **SIL Open Font License 1.1**.

| Family | Upstream, pinned | Copyright (from its OFL.txt) | Reserved Font Name |
|---|---|---|---|
| Bitter 2.002 | [solmatas/BitterPro](https://github.com/solmatas/BitterPro) at `75fe4ad9`, the last commit with static TTFs (`fonts/ttf/` was removed in `9d358f0a`, 2024-04-09; Google Fonts' `ofl/bitter/upstream_info.md` names this repo) | Copyright 2011 The Bitter Project Authors | "Bitter Pro" |
| Literata 3.103 | [googlefonts/literata](https://github.com/googlefonts/literata/releases/tag/3.103), tag 3.103 = `0c2761b7` (the commit google/fonts uses) | Copyright 2017 The Literata Project Authors | none |

What OFL asks of us when we redistribute them unmodified:

- **Ship the license with the fonts.** Each family's `OFL.txt` is downloaded, SHA-checked, into
  the same folder as the fonts (`Bitter-OFL.txt`, `Literata-OFL.txt`). The copyright notice is in
  the font files' name tables too.
- **Don't sell the fonts by themselves.** We don't sell anything.
- **Reserved Font Names apply only to modified versions.** We ship upstream's files byte for byte
  (the SHA-256 check guarantees it), so "Bitter Pro" doesn't constrain us. If we ever subset or
  instance a font ourselves, the result must not be called "Bitter Pro" ("Bitter" is not reserved).
- The license covers the fonts only; it doesn't extend to Orbify's code (MIT) or the documents
  rendered with them.

**Static, not variable.** google/fonts ships only `Bitter[wght].ttf` and Literata's variable
font. KOReader handles variable fonts only from v2026.07 (crengine PR #669, koreader PR #15553),
with open issues (optical sizing off below 100 dpi zoom, crengine #746; width axis unset,
koreader #16313). Static Regular, Italic, Bold and Bold Italic work on every KOReader version and
map to its four styles (usWeightClass 400/700, fsSelection matches). Literata uses its default
12 pt text size (the unsuffixed `Literata-*.ttf`; 7, 36 and 72 pt are left out).

## 3. Delivery: downloaded on the device, nothing in the APK

When the user turns the row on, the companion downloads each file from a
`raw.githubusercontent.com/<repo>/<40-hex commit>/…` URL and keeps it only when its SHA-256 is the
one in `ReadingFonts.FILES` (`C/FontsLogic.kt`). About 2.0 MB for the eight TTFs, well above the
1 MB where bundling would be cheap; and the row is off for most readers. Upstream URLs pinned to a
commit return the same bytes for as long as the commit exists; a changed or missing file fails the
hash and installs nothing. Setup already needs Wi-Fi for KOReader and the plugins, so first setup
is never offline only for this.

`FontsLogicTest` fails on an unpinned URL, a malformed hash, a duplicate name or a family without
its `OFL.txt`.

## 4. Android

- **Where.** `<shared storage>/koreader/fonts`. KOReader on Android searches
  `home/fonts;home/koreader/fonts` with home = external storage
  (`frontend/ui/elements/font_settings.lua:19-21` at the pinned koreader), next to
  `koreader/plugins`, where the companion installs the Orbit plugin (`PatchInstaller`). Same
  storage permission (target SDK 28, `WRITE_EXTERNAL_STORAGE`).
- **Install** (`C/FontInstaller.kt`, plan in `ReadingFonts.plan`). On: download every file
  missing or not matching its hash, each to `<name>.orbit-part` and renamed only after the check
  (KOReader never lists a half file). Off: delete only files whose hash is ours, so a user's own
  `Literata-Regular.ttf` stays. Leftover `.orbit-part` files go either way. A finished plan run
  again does nothing.
- **Restart.** KOReader builds its font list once per start (`frontend/fontlist.lua`
  `getFontList`). After an install that wrote files, the row says "Installed; KOReader shows
  them after it restarts, when the screen next goes off" and offers **Restart KOReader**
  (PIN-free follow-through). Otherwise the companion restarts KOReader at the next screen-off,
  from the same screen-off hook as the Orbit plugin's restart and never on top of it
  (`ReadingFonts.restart`); an open book reopens where it was. Nothing interrupts reading.
- **Row.** Label "Reading fonts: Bitter, Literata"; off: "Without it: KOReader offers only its own
  fonts and the reader's; Bitter and Literata aren't among them." and **Turn on**; on: "On:
  Bitter and Literata are in KOReader's font menu." and **Turn off**; failed: "Not installed: …"
  and **Retry**. In both modes it sits in Optional; "New in 0.12".

## 5. Xteink (CrossInk 2.x): nothing to build

- **Bitter** is one of CrossInk's two built-in reading fonts (`src/CrossPointSettings.h:202`;
  bitmaps at 10/12/14/16 pt in `lib/EpdFont/builtinFonts/bitter_*`, and a scalable TTF on S3
  builds).
- **Literata** is in CrossInk's font catalog (`lib/EpdFont/scripts/sd-fonts.yaml:110-119`), and
  the live catalog the firmware reads (`uxjulia/crossink-fonts`, release `sd-fonts-m1-b4`,
  `fonts.json`, checked 2026-11-23) lists it. Settings › Reader › Font Options › Download Fonts
  fetches it to `/.fonts/Literata/` as `.cpfont` files on every model, the X3 included.
- Also possible without Orbify: on X4 Pro and X4 (scalable builds), the static TTFs copied to
  `/fonts/<Family>/` on the SD card or uploaded on the web Fonts page
  (`src/network/CrossPointWebServer.cpp:517-520`); `.cpfont` only on the X3.

A sync-time fetch in the overlay would duplicate Download Fonts and compete for heap with
Tailscale and TLS on the X3, where font downloads already needed a different HTTP client
(`FontDownloadActivity.cpp:309`). Not built.

## 6. Tests

`FontsLogicTest` (manifest, hash check, plan on/off, restart rule, verbs) and `ReadingFontsTest`
(Robolectric: the row as Setup builds it, off by default; the install against a folder with a fake
download: all files land, a bad hash leaves nothing, off keeps the user's own files). No network.
