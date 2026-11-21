# BookOrbit-Android

Keeps Android e-readers (first target: Meebook M8C) in sync with a BookOrbit server over Tailscale, the way CrossInk does on Xteink readers.

The official BookOrbit KOReader plugin does all syncing and keeps the login. This repo adds:

- `koreader-patch/`: a KOReader user patch that brings the network up (Wi-Fi + Tailscale) before the plugin syncs, syncs on sleep and on a schedule, and sends Home to BookOrbit home.
- `companion/`: "Orbit Companion", an Android app that switches Wi-Fi, wakes Tailscale, holds a short wake lock, turns the screen off for "Sync and sleep", and acts as the Home launcher.

Design and approved mockups: `docs/DESIGN.md`, `docs/mockups.html`.

## Device findings (Meebook M8C, Android 14, firmware V2.2.1)

- KOReader is the GitHub build, so user patches work.
- After the power button, KOReader keeps running with network for about 1 min 50 s, then the firmware force-stops the foreground app. Battery "Unrestricted" does not prevent it. Services (Tailscale) survive.
- Every wake is therefore a fresh KOReader start.
