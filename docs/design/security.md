# Security: the plugin ↔ companion channel (Android)

How the BookSync KOReader plugin and BookSync Companion trust each other, what that protects, and what
it does not. The interface itself is `android/docs/INTERFACE.md`.

## What is trusted

- **Android** and its package manager: the UID of a binder caller, and the signing certificates
  it reports for an installed package.
- **Orbify's release key.** It signs every BookSync Companion release (SHA-256 `F5:07:8C:…:0A:15`,
  checked by `release.yml`). Test builds are signed with it too.
- **KOReader, as first seen.** KOReader is not signed by us, and people install it from GitHub,
  F-Droid or their own build. The companion trusts the KOReader it first sees (trust on first use)
  and keeps trusting only that copy.
- **The user**, who confirms once when KOReader changes.

Not trusted: any other app on the device, including one that takes the companion's package name
while the real companion is not installed.

## The caller check (KOReader → companion)

KOReader's commands go through one entry, the companion's `CommandProvider`
(`content://net.fledgewing.orbitcompanion.commands`). The plugin calls it with
`ContentResolver.call` through KOReader's JNI bridge. There is no other way in: the companion's
broadcast receiver is not exported and takes only the system's own broadcasts.

For each call the companion:

1. takes the calling UID from the binder (`Binder.getCallingUid()`) and the packages of that UID;
2. requires a KOReader package (`org.koreader.launcher`, or F-Droid's `org.koreader.launcher.fdroid`);
3. reads that package's signing certificates and compares them with the pinned ones
   (`CallerTrust.decide`):
   - nothing pinned yet: it pins this KOReader (package and certificates) and accepts;
   - the pinned package with the pinned certificates (a key rotation keeps the old certificate
     in its history, so the pinned set only has to be contained): accepts;
   - anything else: refuses;
4. accepts only the known command names, and runs the command as before.

**KOReader changed.** When KOReader comes back with another signer (reinstalled from another
source, or replaced by something else), the companion refuses it and Setup shows a row:
"KOReader changed: trust this copy?". **Trust** pins the new copy; until then nothing from it is
accepted, and the companion puts no command on KOReader's start. If the old copy comes back, the
row goes by itself.

No shared secret is involved, and there is no fallback path: the plugin and the companion always
ship together.

## The plugin checks the companion (plugin → companion)

Before it sends anything, the plugin reads the installed companion's signing certificates over
JNI (`PackageManager`, then SHA-256) and requires every one of them to be Orbify's release
certificate (`Companion.state()`). An app that has the companion's package name but another
signer is "untrusted": the plugin sends it nothing, the BookOrbit login least of all, and the
menus say "This BookSync Companion is not an Orbify release". The login goes only in the call, never
in a file or a log.

## The companion → KOReader direction

- **Commands on KOReader's start.** The companion starts KOReader with a command only when the
  installed KOReader is the pinned copy (`KoreaderTrust.koreaderTrusted`); another copy is
  started with no command. Any app can start KOReader with the same extra, so the plugin obeys a
  command only after the companion confirms, through the caller-checked call, that it sent it
  (`TAKE_COMMAND`, once, within 10 minutes; `SentCommands`).
- **The status** reaches the plugin as the answer to its own caller-checked call, not over a port
  another app could open.
- **The click channel** stays a loopback socket (KOReader's event loop watches its fd). The plugin
  gets a one-time key and proof through the caller-checked call (`CLICKS`, `ClickKeys`); the port
  opens the channel only for that key, and the plugin trusts the channel only once its first line
  carries the proof. Another app can neither read the clicks nor pose as the companion.
- **Over USB**, the shell UID may call one method, `RESTART_KOREADER`
  (`tools/sideload-android.sh`); adb already controls the device.

## Commands that touch files

Every path a command names is resolved (symlinks followed) and used only when it lies inside
the companion's own folders: `koreader/settings/orbit-cache`, KOReader's BookOrbit cover folder
`koreader/cache/bookorbit` and `koreader/settings/orbit-sleep` (`Places`). Parent segments and
relative paths are refused.

## Residual risk

**Any KOReader plugin can call the companion.** A KOReader plugin, BookSync or another, runs inside
KOReader's process with KOReader's UID, so the caller check cannot tell them apart. A malicious
KOReader plugin already has KOReader's own file and network access, so what it gains from the
companion is limited to the companion's command set. That set is kept narrow:

- every command acts on Orbify's own data only, and no command takes an arbitrary path;
- credentials are never returned to a caller: the companion keeps the login a command brings in
  memory for that job, and no call answers with a login;
- the destructive or system actions are in their narrowest form: locking the screen is the
  device-admin `force-lock` policy only, at most once per few seconds; Wi-Fi is switched on or
  off, never reconfigured; a wake lock is capped at 25 s.

Other limits, unchanged by this design:

- Files in shared storage (`koreader/settings/…`) can be read and written by any app that has
  storage access; that is KOReader's own boundary (it keeps its settings there).
- The companion's pages (activities) can be opened by any app; they show a screen and change
  nothing on their own.
- Trust on first use trusts whatever KOReader is installed when the companion first hears from
  it. A device that already had a look-alike KOReader at that moment would pin it; reinstalling
  KOReader from its source and confirming the Setup row fixes it.

## Tests

- `PlacesTest`: paths inside and outside the folders, `..`, symlinks out; storage, recheck and a
  plan's cover folder outside them touch nothing.
- `CallerTrustTest`: the rule; the pinned KOReader is accepted, another UID or signer refused;
  a changed KOReader is refused until trusted, with its Setup row; the receiver is not exported.
- `CallerTrustTest`: a command on KOReader's start is confirmed once and only when sent, and
  only to the pinned KOReader; the click key works once; only the shell may ask for a restart.
- `test_flows.lua` "companion: an app with its name and another signer gets nothing": no call,
  no login, the problem line; "a command on KOReader's start that BookSync Companion didn't send is
  ignored"; "a listener on the port that can't prove it is BookSync Companion is dropped".
